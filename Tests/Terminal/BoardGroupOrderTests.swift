import AppKit
import SwiftUI
import SwiftTerm
import Darwin

/// A drag as AppKit hands it to a destination, over an owned, uniquely named
/// pasteboard (as in ItemDropTests).
final class OwnedDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let source: AnyObject?
    init(_ pasteboard: NSPasteboard, source: AnyObject?) {
        draggingPasteboard = pasteboard
        self.source = source
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// What was seen at each step.
@MainActor final class Steps {
    var list: [String] = []
}

/// A row of a group: its ID in the list, and the pane its drag is of.
struct Row: Identifiable {
    let id: String
    let item: HerdrItemDrag.Item
}

/// What the board keeps and lists, as AgentBoardView has it: the groups as
/// herdr lists them, what it keeps in AppStorage for them — the folded
/// groups and the order — and the drag of a header.
@MainActor @Observable final class Board {
    var groups: [String]
    var rows: [String: [Row]]
    /// AgentBoardView's `collapsedGroupIDs`, and how often it was written.
    var collapsed = "" { didSet { collapsedWrites += 1 } }
    var collapsedWrites = 0
    /// AgentBoardView's `groupOrderIDs`.
    var order = ""
    var selection: String?
    /// The groups a search leaves rows in, or nil while nothing is searched.
    var searchLeaves: Set<String>?
    let drag = BoardGroupDrag(lateEndDelay: .milliseconds(150))

    init(groups: [String], rows: [String: [Row]]) {
        self.groups = groups
        self.rows = rows
    }

    var isFiltering: Bool { searchLeaves != nil }
    /// `boardGroups`.
    var ordered: [String] { BoardGroupOrder.ordered(groups, by: { $0 }, saved: BoardGroupOrder.ids(order)) }
    /// The groups listed: those a search leaves rows in.
    var shown: [String] { ordered.filter { searchLeaves?.contains($0) ?? true } }

    /// The header's click.
    func toggle(_ groupID: String) {
        guard let collapsed = BoardGroupFolding.toggling(groupID, in: collapsed, isFoldingForDrag: drag.isFolding) else { return }
        self.collapsed = collapsed
    }

    /// `moveGroup`.
    func move(_ groupID: String, toGap gap: Int, among shown: [String]) {
        guard let order = BoardGroupOrder.moving(groupID, toGap: gap, among: shown, in: ordered) else { return }
        self.order = BoardGroupOrder.stored(order)
    }
}

/// The board's grouped list, put together as AgentBoardView's: a sidebar
/// list with a section per group in the order kept, rows only while
/// `BoardGroupFolding` lists them, each row with the production drag onto a
/// terminal, each header a plain button that folds its group and the
/// production header drag, and the production insertion line over the list.
struct BoardList: View {
    let board: Board
    var body: some View {
        let shown = board.shown
        List(selection: Binding(get: { board.selection }, set: { board.selection = $0 })) {
            ForEach(shown, id: \.self) { groupID in
                Section {
                    if BoardGroupFolding.listsRows(isCollapsed: BoardGroupFolding.isCollapsed(groupID, in: board.collapsed),
                                                   isFiltering: board.isFiltering, isFoldedForDrag: board.drag.foldsRows(of: groupID)) {
                        ForEach(board.rows[groupID] ?? []) { row in
                            HStack { Text(verbatim: row.id); Spacer() }
                                .contextMenu { Button("Close") {} }
                                .herdrItemDrag(row.item)
                        }
                    }
                } header: {
                    let expanded = BoardGroupFolding.looksExpanded(isCollapsed: BoardGroupFolding.isCollapsed(groupID, in: board.collapsed),
                                                                   isFoldedForDrag: board.drag.foldsRows(of: groupID))
                    Button { board.toggle(groupID) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                            Text(verbatim: groupID)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .boardGroupDrag(groupID, drag: board.drag, among: shown) { gap in
                        board.move(groupID, toGap: gap, among: shown)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .boardGroupInsertionLine(board.drag)
    }
}


/// Has the window's keyboard, and does nothing with a key: no beep.
final class KeySink: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}

func findOutline(_ view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for sub in view.subviews { if let outline = findOutline(sub) { return outline } }
    return nil
}

@main @MainActor enum BoardGroupOrderTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: @autoclosure () -> String) {
        precondition(condition, why())
        checks += 1
    }
    static func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        pure()
        print("pure: \(checks)")
        model()
        print("model: \(checks)")
        board()
        print("board group order checks: \(checks)")
    }

    // MARK: - The rules, without views

    static func pure() {
        // What is kept.
        check(BoardGroupOrder.ids("").isEmpty, "nothing kept, no order")
        check(BoardGroupOrder.ids("host\ngpu") == ["host", "gpu"], "one per line")
        check(BoardGroupOrder.ids("\nhost\n\ngpu\n") == ["host", "gpu"], "empty lines count for nothing")
        check(BoardGroupOrder.stored(["cpu", "host", "gpu"]) == "cpu\nhost\ngpu", "kept one per line")
        check(BoardGroupOrder.ids(BoardGroupOrder.stored(["a b", "w-1", "host"])) == ["a b", "w-1", "host"], "round trip")
        check(BoardGroupOrder.stored([]).isEmpty, "an empty order is an empty string")

        // The order the groups are listed in.
        let herdr = ["host", "gpu", "cpu", "tpu"]
        func ordered(_ saved: [String], _ groups: [String] = herdr) -> [String] {
            BoardGroupOrder.ordered(groups, by: { $0 }, saved: saved)
        }
        check(ordered([]) == herdr, "nothing kept: the host's own, then herdr's order")
        check(ordered(["tpu", "cpu", "gpu", "host"]) == ["tpu", "cpu", "gpu", "host"], "all kept: as kept")
        check(ordered(["cpu", "host"]) == ["cpu", "host", "gpu", "tpu"], "new groups after the kept ones, in herdr's order")
        check(ordered(["gpu"]) == ["gpu", "host", "cpu", "tpu"], "the host's own is new as well if it isn't kept")
        check(ordered(["old", "cpu", "gone", "host"]) == ["cpu", "host", "gpu", "tpu"], "groups gone since count for nothing")
        check(ordered(["cpu", "cpu", "host"]) == ["cpu", "host", "gpu", "tpu"], "a group kept twice goes by its first place")
        check(ordered(["cpu"], ["host", "cpu", "x", "cpu"]) == ["cpu", "cpu", "host", "x"], "two groups of one ID both stay")
        check(ordered(["cpu"], []).isEmpty, "no groups")
        struct Group: Equatable { let id: String; let n: Int }
        check(BoardGroupOrder.ordered([Group(id: "host", n: 0), Group(id: "gpu", n: 1)], by: \.id, saved: ["gpu"]) == [Group(id: "gpu", n: 1), Group(id: "host", n: 0)],
              "the groups themselves, by their IDs")

        // Where a header let go at y goes.
        let frames = ["a": CGRect(x: 10, y: 0, width: 200, height: 20), "b": CGRect(x: 10, y: 40, width: 200, height: 20), "c": CGRect(x: 10, y: 80, width: 200, height: 20)]
        let abc = ["a", "b", "c"]
        for (y, gap) in [(-50.0, 0), (5, 0), (9.9, 0), (10, 1), (15, 1), (49, 1), (50, 2), (75, 2), (89, 2), (90, 3), (500, 3)] {
            check(BoardGroupOrder.gap(at: y, among: abc, frames: frames) == gap, "y \(y): gap \(gap)")
        }
        check(BoardGroupOrder.gap(at: 45, among: ["a", "x", "b", "c"], frames: frames) == 2, "a header not laid out isn't counted")
        check(BoardGroupOrder.gap(at: 45, among: [], frames: frames) == 0, "no headers")

        // The line drawn for each gap.
        check(BoardGroupDrag.line(atGap: 1, among: abc, frames: frames) == CGRect(x: 10, y: 29, width: 200, height: 2), "halfway between a and b")
        check(BoardGroupDrag.line(atGap: 2, among: abc, frames: frames) == CGRect(x: 10, y: 69, width: 200, height: 2), "halfway between b and c")
        check(BoardGroupDrag.line(atGap: 0, among: abc, frames: frames) == CGRect(x: 10, y: -11, width: 200, height: 2), "as far above the first")
        check(BoardGroupDrag.line(atGap: 3, among: abc, frames: frames) == CGRect(x: 10, y: 109, width: 200, height: 2), "as far below the last")
        check(BoardGroupDrag.line(atGap: 1, among: ["a", "x"], frames: frames) == nil, "not with a header not laid out")
        check(BoardGroupDrag.line(atGap: 4, among: abc, frames: frames) == nil && BoardGroupDrag.line(atGap: 0, among: [], frames: frames) == nil, "no such gap")

        // Moving a group into a gap.
        let shown = ["A", "B", "C", "D"]
        let moves: [(String, Int, [String]?)] = [
            ("A", 0, nil), ("A", 1, nil), ("A", 2, ["B", "A", "C", "D"]), ("A", 3, ["B", "C", "A", "D"]), ("A", 4, ["B", "C", "D", "A"]),
            ("D", 0, ["D", "A", "B", "C"]), ("D", 3, nil), ("D", 4, nil), ("C", 1, ["A", "C", "B", "D"]), ("B", 4, ["A", "C", "D", "B"]),
            ("B", 5, nil), ("B", -1, nil), ("X", 0, nil),
        ]
        for (id, gap, expected) in moves {
            check(BoardGroupOrder.moving(id, toGap: gap, among: shown, in: shown) == expected, "\(id) into gap \(gap)")
        }
        // Every group into every gap: the others keep their order, and the
        // group lands in the gap.
        for (from, id) in shown.enumerated() {
            for gap in 0...shown.count {
                let moved = BoardGroupOrder.moving(id, toGap: gap, among: shown, in: shown)
                guard let moved else { check(gap == from || gap == from + 1, "only staying put is no move: \(id) \(gap)"); continue }
                check(moved.sorted() == shown.sorted(), "each group once: \(moved)")
                check(moved.filter { $0 != id } == shown.filter { $0 != id }, "the others in order: \(moved)")
                check(moved.firstIndex(of: id) == (gap > from ? gap - 1 : gap), "\(id) in gap \(gap): \(moved)")
            }
        }
        // Groups the search leaves out keep their places among the rest.
        let order = ["A", "X", "B", "Y", "C"]
        let left = ["A", "B", "C"]
        check(BoardGroupOrder.moving("C", toGap: 1, among: left, in: order) == ["A", "X", "C", "B", "Y"], "moved up: right before the one below the gap")
        check(BoardGroupOrder.moving("A", toGap: 2, among: left, in: order) == ["X", "B", "A", "Y", "C"], "moved down: right after the one above it")
        check(BoardGroupOrder.moving("A", toGap: 3, among: left, in: order) == ["X", "B", "Y", "C", "A"], "to the end: after the last one shown")
        check(BoardGroupOrder.moving("C", toGap: 0, among: left, in: order) == ["C", "A", "X", "B", "Y"], "to the top: before the first one shown")
        check(BoardGroupOrder.moving("A", toGap: 2, among: left, in: ["X", "B", "C"]) == nil, "not a group of the order")

        // Folding.
        for isCollapsed in [false, true] {
            for isFiltering in [false, true] {
                check(BoardGroupFolding.listsRows(isCollapsed: isCollapsed, isFiltering: isFiltering, isFoldedForDrag: true) == false,
                      "while a header is dragged no group lists rows (folded \(isCollapsed), searched \(isFiltering))")
                check(BoardGroupFolding.listsRows(isCollapsed: isCollapsed, isFiltering: isFiltering, isFoldedForDrag: false) == (isFiltering || !isCollapsed),
                      "otherwise as before (folded \(isCollapsed), searched \(isFiltering))")
            }
            check(BoardGroupFolding.looksExpanded(isCollapsed: isCollapsed, isFoldedForDrag: true) == false, "every header shows its group folded while one is dragged")
            check(BoardGroupFolding.looksExpanded(isCollapsed: isCollapsed, isFoldedForDrag: false) == !isCollapsed, "as the person left it otherwise")
        }
        check(BoardGroupFolding.isCollapsed("gpu", in: "cpu\ngpu") && !BoardGroupFolding.isCollapsed("gpu", in: "cpu\ngpu2") && !BoardGroupFolding.isCollapsed("gpu", in: ""),
              "folded by the whole ID")
        check(BoardGroupFolding.toggling("host", in: "", isFoldingForDrag: false) == "host", "folded")
        check(BoardGroupFolding.toggling("cpu", in: "host", isFoldingForDrag: false) == "cpu\nhost", "kept sorted, as before")
        check(BoardGroupFolding.toggling("host", in: "cpu\nhost", isFoldingForDrag: false) == "cpu", "unfolded")
        check(BoardGroupFolding.toggling("gpu", in: "cpu\nhost", isFoldingForDrag: true) == nil
              && BoardGroupFolding.toggling("host", in: "cpu\nhost", isFoldingForDrag: true) == nil, "not while groups are folded for a drag: nothing to write")
    }

    // MARK: - The drag, without views

    static func model() {
        let frames = ["host": CGRect(x: 0, y: 40, width: 240, height: 16), "gpu": CGRect(x: 0, y: 70, width: 240, height: 16), "cpu": CGRect(x: 0, y: 100, width: 240, height: 16)]
        let shown = ["host", "gpu", "cpu"]
        // The list and its headers as AppKit views, in a never-shown window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = BoardGroupAnchorView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        window.contentView = list
        var headers: [String: BoardGroupAnchorView] = [:]
        for (id, frame) in frames {
            // A header's anchor sits in its row's view, as in a List.
            let row = NSView(frame: NSRect(x: 0, y: frame.minY - 6, width: 260, height: frame.height + 12))
            let anchor = BoardGroupAnchorView(frame: NSRect(x: frame.minX, y: 6, width: frame.width, height: frame.height))
            anchor.groupID = id
            row.addSubview(anchor)
            list.addSubview(row)
            headers[id] = anchor
        }
        check(list.isFlipped && list.hitTest(NSPoint(x: 10, y: 50)) == nil, "an anchor counts from the top left and takes no clicks")
        func made() -> BoardGroupDrag {
            let drag = BoardGroupDrag(lateEndDelay: .milliseconds(150))
            drag.register(list)
            for view in headers.values { drag.register(view) }
            return drag
        }
        let start = CGPoint(x: 50, y: 108)
        do {
            let drag = made()
            check(!drag.isDragging && drag.draggedID == nil && drag.line == nil, "nothing dragged at first")
            check(drag.headerFrames == frames, "the headers' places, in the list's coordinates: \(drag.headerFrames)")
            check(drag.listView === list && drag.pointer() != nil, "the pointer is read in the list's window")
            check(BoardGroupDrag().pointer() == nil && BoardGroupDrag().headerFrames.isEmpty, "with no list, no pointer and no headers")
            drag.drag("cpu", from: start, to: CGPoint(x: 50, y: 112), among: shown)
            check(drag.isDragging && drag.draggedID == "cpu", "the first move starts the drag")
            check(drag.line == nil, "over its own place, no line")
            drag.drag("cpu", from: start, to: CGPoint(x: 50, y: 60), among: shown)
            check(drag.line == CGRect(x: 0, y: 62, width: 240, height: 2), "between host and gpu: \(String(describing: drag.line))")
            drag.drag("cpu", from: start, to: CGPoint(x: 50, y: 10), among: shown)
            check(drag.line == CGRect(x: 0, y: 32, width: 240, height: 2), "above host: \(String(describing: drag.line))")
            drag.drag("cpu", from: start, to: CGPoint(x: 400, y: 60), among: shown)
            check(drag.line == nil && drag.isDragging, "outside the list: no line, still dragging")
            drag.drag("cpu", from: start, to: nil, among: shown)
            check(drag.line == nil && drag.isDragging, "away from its window: no line, still dragging")
            // The list moves a header's row: where it is now counts.
            headers["host"]!.superview!.setFrameOrigin(NSPoint(x: 0, y: 4))
            check(drag.headerFrames["host"] == CGRect(x: 0, y: 10, width: 240, height: 16), "a row the list moved: \(String(describing: drag.headerFrames["host"]))")
            drag.drag("cpu", from: start, to: CGPoint(x: 50, y: 60), among: shown)
            check(drag.line == CGRect(x: 0, y: 47, width: 240, height: 2), "and the line with it: \(String(describing: drag.line))")
            headers["host"]!.superview!.setFrameOrigin(NSPoint(x: 0, y: 34))
            check(drag.drop("cpu", from: CGPoint(x: 1, y: 1), at: CGPoint(x: 50, y: 60), among: shown) == nil && drag.isDragging,
                  "another gesture's end isn't this drag's")
            check(drag.foldsAll && drag.isFolding && ["host", "gpu", "cpu"].allSatisfy(drag.foldsRows(of:)), "every group folded while it is dragged")
            check(drag.drop("cpu", from: start, at: CGPoint(x: 50, y: 60), among: shown) == 1, "let go between host and gpu: gap 1")
            check(!drag.isDragging && drag.line == nil, "and the drag is over")
            check(drag.foldsAll && drag.heldID == nil, "the group is moved while every group still shows its header alone")
            // Then, each in a turn of the main queue of its own: every
            // group's rows but the last one listed — gpu, after cpu's move —
            // then the last one's.
            let steps = Steps()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    steps.list.append(drag.foldsAll ? "all" : drag.heldID ?? "none")
                    DispatchQueue.main.async { MainActor.assumeIsolated { steps.list.append(drag.foldsAll ? "all" : drag.heldID ?? "none") } }
                }
            }
            settle(0.1)
            check(steps.list == ["gpu", "none"], "the rows back in two steps, the last group's after: \(steps.list)")
            check(!drag.isFolding && !["host", "gpu", "cpu"].contains(where: drag.foldsRows(of:)), "every group as it was")
            check(drag.drop("cpu", from: start, at: CGPoint(x: 50, y: 60), among: shown) == nil, "once")
            // A header's view taken for another header, or out of the window.
            headers["gpu"]!.groupID = "tpu"
            drag.register(headers["gpu"]!)
            check(drag.headerFrames["gpu"] == nil && drag.headerFrames["tpu"] == frames["gpu"], "a view is the header's it is in now")
            let row = headers["cpu"]!.superview!
            row.removeFromSuperview()
            check(drag.headerFrames["cpu"] == nil, "a header out of the window has no place")
            list.addSubview(row)
            row.isHidden = true
            check(drag.headerFrames["cpu"] == nil, "nor a hidden one")
            row.isHidden = false
            headers["gpu"]!.groupID = "gpu"
            check(drag.headerFrames == frames, "back")
        }
        do {
            let drag = made()
            drag.drag("host", from: start, to: CGPoint(x: 50, y: 200), among: shown)
            check(drag.drop("host", from: start, at: CGPoint(x: 50, y: 200), among: shown) == 3, "below the last: the last gap")
            drag.drag("host", from: start, to: CGPoint(x: 50, y: 60), among: shown)
            check(drag.drop("host", from: start, at: CGPoint(x: 50, y: 60), among: shown) == nil, "in its own place: nothing moves")
            drag.drag("host", from: start, to: CGPoint(x: 50, y: 90), among: shown)
            check(drag.drop("host", from: start, at: CGPoint(x: 500, y: 90), among: shown) == nil && !drag.isDragging, "let go outside the list: nothing moves")
            drag.drag("host", from: start, to: CGPoint(x: 50, y: 90), among: shown)
            check(drag.drop("host", from: start, at: CGPoint(x: 50, y: -10), among: shown) == nil, "above the list: nothing moves")
            drag.drag("host", from: start, to: CGPoint(x: 50, y: 90), among: shown)
            check(drag.drop("host", from: start, at: nil, among: shown) == nil, "away from its window: nothing moves")
        }
        do {
            // Ended before the gesture ends: the rest of the gesture is ignored.
            let drag = made()
            drag.drag("gpu", from: start, to: CGPoint(x: 50, y: 200), among: shown)
            drag.cancel()
            check(!drag.isDragging && drag.line == nil, "cancelled")
            settle(0.05)
            check(!drag.isFolding, "the rows back")
            drag.drag("gpu", from: start, to: CGPoint(x: 50, y: 10), among: shown)
            check(!drag.isDragging && drag.line == nil, "the rest of its gesture is ignored")
            check(drag.drop("gpu", from: start, at: CGPoint(x: 50, y: 10), among: shown) == nil, "and its end moves nothing")
            drag.drag("gpu", from: start, to: CGPoint(x: 50, y: 10), among: shown)
            check(drag.isDragging, "the next gesture drags again")
            drag.cancel(); drag.cancel()
            drag.drag("gpu", from: CGPoint(x: 60, y: 78), to: CGPoint(x: 50, y: 10), among: shown)
            check(drag.isDragging && drag.draggedID == "gpu", "so does one from elsewhere before the last one's end")
            drag.finish(); drag.finish()
            check(!drag.isDragging, "finished, twice")
            settle(0.05)
            check(!drag.isFolding, "the rows back")
            // A drag started before the last one's rows are all back.
            drag.drag("gpu", from: start, to: CGPoint(x: 50, y: 10), among: shown)
            _ = drag.drop("gpu", from: start, at: CGPoint(x: 50, y: 10), among: shown)
            drag.drag("host", from: start, to: CGPoint(x: 50, y: 200), among: shown)
            settle(0.05)
            check(drag.isDragging && drag.foldsAll && drag.heldID == nil, "the new drag keeps every group folded")
            drag.finish()
            settle(0.05)
            drag.cancel()
            check(!drag.isDragging, "nothing to cancel")
        }
        do {
            // The mouse coming up ends a drag the gesture doesn't end.
            let drag = made()
            drag.drag("gpu", from: start, to: CGPoint(x: 50, y: 10), among: shown)
            drag.mouseCameUp()
            check(drag.isDragging, "not at once: the gesture may still end it")
            settle(0.4)
            check(!drag.isDragging && drag.line == nil, "but soon after")
            drag.drag("gpu", from: start, to: CGPoint(x: 50, y: 10), among: shown)
            drag.mouseCameUp()
            check(drag.drop("gpu", from: start, at: CGPoint(x: 50, y: 10), among: shown) == 0, "the gesture's own end, in time, moves the group")
            drag.drag("cpu", from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 10), among: shown)
            settle(0.4)
            check(drag.isDragging && drag.draggedID == "cpu", "a later drag is left alone")
            drag.mouseWentDown()
            check(!drag.isDragging, "a button going down ends a drag left over")
            drag.mouseCameUp(); drag.mouseWentDown()
            check(!drag.isDragging, "nothing to end")
        }
    }

    // MARK: - The board's list, in never-shown windows

    static func board() {
        let host = Machine(displayName: "Owned", hostname: "owned.invalid", username: "fixture")
        let connection = host.connectionIdentity
        let gpu = HerdrMachine(id: "gpu", label: "gpu", target: "never-connect", session: "default", enabled: true)
        let cpu = HerdrMachine(id: "cpu", label: "cpu", target: "never-connect", session: "default", enabled: true)
        func row(_ pane: String, on machine: HerdrMachine?) -> Row {
            let summary = AgentSummary(json: .object(["pane_id": .string(pane), "terminal_id": .string("term-" + pane), "tab_id": .string("w1:t1")]), on: machine)!
            return Row(id: (machine?.id ?? "host") + "/" + pane, item: HerdrItemDrag.Item(pane: summary, on: connection))
        }
        let rows = [
            "host": [row("w1:p1", on: nil), row("w1:p2", on: nil)],
            "gpu": [row("w1:p1", on: gpu), row("w1:p2", on: gpu)],
            "cpu": [row("w1:p1", on: cpu), row("w1:p2", on: cpu)],
        ]
        /// A row's ID in the list, from the item its drag is of.
        func rowID(_ item: HerdrItemDrag.Item) -> String {
            (item.herdrMachineID ?? "host") + "/" + item.herdrID
        }
        let board = Board(groups: ["host", "gpu", "cpu"], rows: rows)
        board.collapsed = "cpu"
        board.collapsedWrites = 0

        // The sidebar and, beside it, the production terminal view with the
        // production row drop, over an owned kernel PTY.
        let width: CGFloat = 700, height: CGFloat = 520, listWidth: CGFloat = 280
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let listHost = NSHostingView(rootView: BoardList(board: board))
        listHost.frame = NSRect(x: 0, y: 0, width: listWidth, height: height)
        let terminal = FocusReportingTerminalView(frame: NSRect(x: listWidth, y: 0, width: width - listWidth, height: height))
        let sink = KeySink(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        container.addSubview(listHost)
        container.addSubview(terminal)
        container.addSubview(sink)
        window.contentView = container
        check(window.makeFirstResponder(sink), "the keyboard with a view that takes no key")
        var master: Int32 = -1, slave: Int32 = -1
        precondition(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        var settings = termios(); precondition(tcgetattr(slave, &settings) == 0)
        cfmakeraw(&settings); precondition(tcsetattr(slave, TCSANOW, &settings) == 0)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC); _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFL, O_NONBLOCK)
        func received() -> [UInt8] {
            var result: [UInt8] = [], bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(slave, &bytes, bytes.count)
                if n <= 0 { break }; result += bytes.prefix(n)
            }
            return result
        }
        var sends: [[UInt8]] = []
        let coordinator = TerminalHostView.Coordinator(onInput: { bytes in
            sends.append(Array(bytes))
            Array(bytes).withUnsafeBytes { precondition(Darwin.write(master, $0.baseAddress, $0.count) == $0.count) }
        }, onResize: { _, _ in }, onOpenLink: nil)
        terminal.terminalDelegate = coordinator
        var targets: [Bool] = []
        terminal.textDrop = HerdrItemDrag.terminalDrop(connection: connection, herdrMachineID: nil) { targets.append($0) }
        // Elsewhere in the app: a window with nothing in it, for presses that
        // land outside the board.
        let elsewhere = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        elsewhere.isReleasedWhenClosed = false
        defer { elsewhere.close() }
        elsewhere.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        listHost.layoutSubtreeIfNeeded()
        settle(0.4)
        check(!window.isVisible && !elsewhere.isVisible, "the windows are never shown")
        guard let outline = findOutline(listHost), let dataSource = outline.dataSource else { preconditionFailure("the List is an outline view") }

        /// The list as it is now: each group's header, "#id", and its rows,
        /// by their IDs. A row is told by the item the list's writer for it
        /// keeps (`HerdrItemDrag.dragged`), a header by its place among the
        /// headers on screen; asking for the writers is what the list does
        /// when a drag starts from a row.
        func listed() -> [String] {
            let frames = board.drag.headerFrames
            guard let list = board.drag.listView else { preconditionFailure("the list's anchor") }
            var result: [String] = []
            for index in 0..<outline.numberOfRows {
                let writer = dataSource.outlineView?(outline, pasteboardWriterForItem: outline.item(atRow: index) as Any)
                if outline.rowView(atRow: index, makeIfNecessary: true)?.isGroupRowStyle == true {
                    check(writer == nil, "a header gives the list nothing to drag")
                    // The header whose anchor is in this row, where AppKit has it.
                    let row = list.convert(outline.rect(ofRow: index), from: outline)
                    let names = frames.filter { row.contains(CGPoint(x: $0.value.midX, y: $0.value.midY)) }.map(\.key)
                    check(names.count == 1, "one header's anchor in header row \(index): \(names) \(row) \(frames)")
                    result.append("#" + (names.first ?? "?"))
                } else {
                    guard writer != nil, let item = HerdrItemDrag.dragged else { preconditionFailure("a row gives its drag") }
                    result.append(rowID(item))
                }
            }
            return result
        }
        func selectedRow() -> String? {
            guard outline.selectedRow >= 0,
                  dataSource.outlineView?(outline, pasteboardWriterForItem: outline.item(atRow: outline.selectedRow) as Any) != nil,
                  let item = HerdrItemDrag.dragged else { return nil }
            return rowID(item)
        }
        /// The middle of a group's header, where it is pressed.
        func middle(_ groupID: String) -> CGPoint {
            let frame = board.drag.headerFrames[groupID]!
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        /// Halfway between two headers on screen, or past the first or the last.
        func between(_ above: String?, _ below: String?) -> CGPoint {
            let top = above.map { board.drag.headerFrames[$0]!.maxY } ?? (board.drag.headerFrames[below!]!.minY - 12)
            let bottom = below.map { board.drag.headerFrames[$0]!.minY } ?? (board.drag.headerFrames[above!]!.maxY + 12)
            return CGPoint(x: 60, y: (top + bottom) / 2)
        }
        /// The gesture's moves and its end, as `boardGroupDrag` hands them
        /// on.
        func drag(_ groupID: String, from start: CGPoint, to point: CGPoint) {
            board.drag.drag(groupID, from: start, to: point, among: board.shown)
            settle()
        }
        func letGo(_ groupID: String, from start: CGPoint, at point: CGPoint) {
            let shown = board.shown
            if let gap = board.drag.drop(groupID, from: start, at: point, among: shown) {
                board.move(groupID, toGap: gap, among: shown)
            }
            settle()
        }

        // 1. As herdr lists the groups, cpu folded.
        let initial = ["#host", "host/w1:p1", "host/w1:p2", "#gpu", "gpu/w1:p1", "gpu/w1:p2", "#cpu"]
        check(listed() == initial, "as herdr lists them, cpu folded: \(listed())")
        board.selection = "gpu/w1:p2"
        settle()
        check(selectedRow() == "gpu/w1:p2", "a row selected")
        check(board.drag.listView.map { $0.isFlipped && $0.bounds.size == CGSize(width: listWidth, height: height) && $0.convert($0.bounds, to: nil).minX == 0 } == true,
              "the list's anchor takes the list's place: \(String(describing: board.drag.listView?.frame))")
        check(board.drag.headerFrames.count == 3 && board.drag.headerFrames.values.allSatisfy { $0.maxX <= listWidth && $0.width > 100 }, "the headers' places: \(board.drag.headerFrames)")

        // 2. A drag of cpu's header: every group folds, as long as it lasts.
        let cpuStart = middle("cpu")
        drag("cpu", from: cpuStart, to: CGPoint(x: cpuStart.x, y: cpuStart.y - 6))
        check(listed() == ["#host", "#gpu", "#cpu"], "the headers alone while it is dragged: \(listed())")
        check(board.collapsed == "cpu" && board.collapsedWrites == 0, "the folded groups kept are left as they were")
        check(board.selection == "gpu/w1:p2", "the selection stays, its row folded away: \(board.selection ?? "nil")")
        let folded = ["host", "gpu", "cpu"].map { board.drag.headerFrames[$0]! }
        check(folded[0].maxY < folded[1].minY && folded[1].maxY < folded[2].minY && folded[2].minY < cpuStart.y, "the headers close up: \(folded)")
        board.toggle("host")
        check(board.collapsed == "cpu" && listed() == ["#host", "#gpu", "#cpu"], "a header's click doesn't fold or unfold while one is dragged")
        // Where it would go.
        drag("cpu", from: cpuStart, to: between("host", "gpu"))
        let line = board.drag.line
        check(line != nil && line!.minY > folded[0].maxY && line!.maxY < folded[1].minY && line!.minX == folded[0].minX && line!.width == folded[0].width,
              "a line between host and gpu: \(String(describing: line))")
        drag("cpu", from: cpuStart, to: between("gpu", nil))
        check(board.drag.line == nil, "none over its own place")
        drag("cpu", from: cpuStart, to: between(nil, "host"))
        check(board.drag.line.map { $0.maxY < folded[0].minY } == true, "one above host")
        // Let go between host and gpu.
        letGo("cpu", from: cpuStart, at: between("host", "gpu"))
        check(!board.drag.isDragging && board.drag.line == nil, "the drag is over")
        check(board.order == "host\ncpu\ngpu", "the order kept: \(board.order.debugDescription)")
        check(listed() == ["#host", "host/w1:p1", "host/w1:p2", "#cpu", "#gpu", "gpu/w1:p1", "gpu/w1:p2"], "cpu moved, each group folded as before: \(listed())")
        check(board.collapsed == "cpu" && board.collapsedWrites == 0, "the folded groups kept never changed")
        check(board.selection == "gpu/w1:p2" && selectedRow() == "gpu/w1:p2", "the same row selected again: \(selectedRow() ?? "nil")")

        // 3. The arrow keys follow the list as it is now.
        board.collapsed = "" // cpu unfolded
        board.selection = "host/w1:p2"
        settle()
        check(listed() == ["#host", "host/w1:p1", "host/w1:p2", "#cpu", "cpu/w1:p1", "cpu/w1:p2", "#gpu", "gpu/w1:p1", "gpu/w1:p2"], "all unfolded: \(listed())")
        func press(_ key: Int, _ code: UInt16) {
            let characters = String(UnicodeScalar(UInt16(key))!)
            outline.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code)!)
            settle()
        }
        press(NSDownArrowFunctionKey, 125)
        check(board.selection == "cpu/w1:p1", "↓ from host's last row goes to cpu's first, where cpu now is: \(board.selection ?? "nil")")
        press(NSDownArrowFunctionKey, 125); press(NSDownArrowFunctionKey, 125)
        check(board.selection == "gpu/w1:p1", "then past cpu to gpu: \(board.selection ?? "nil")")
        press(NSUpArrowFunctionKey, 126)
        check(board.selection == "cpu/w1:p2", "↑ back into cpu: \(board.selection ?? "nil")")
        board.collapsed = "cpu"
        board.collapsedWrites = 0
        board.selection = "gpu/w1:p2"
        settle()

        // 4. Escape ends the drag where it is. (That it goes no further,
        // the source checks say: AppKit hands a key press to every local
        // monitor whatever one of them returns, and only a key window gets
        // what is left of it, which a never-shown window isn't.)
        let hostStart = middle("host")
        drag("host", from: hostStart, to: between("gpu", nil))
        check(listed() == ["#host", "#cpu", "#gpu"] && board.drag.line != nil, "host dragged below gpu")
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        NSApp.sendEvent(key(0, "a"))
        settle()
        check(board.drag.isDragging && board.drag.line != nil, "another key doesn't end it")
        NSApp.sendEvent(key(53, "\u{1b}"))
        settle()
        check(!board.drag.isDragging && board.drag.line == nil, "Escape ends it")
        check(listed() == ["#host", "host/w1:p1", "host/w1:p2", "#cpu", "#gpu", "gpu/w1:p1", "gpu/w1:p2"], "each group as it was: \(listed())")
        drag("host", from: hostStart, to: between("gpu", nil))
        check(!board.drag.isDragging && listed().count == 7, "the rest of the gesture is ignored")
        letGo("host", from: hostStart, at: between("gpu", nil))
        check(board.order == "host\ncpu\ngpu" && listed().count == 7, "and its end moves nothing")
        NSApp.sendEvent(key(53, "\u{1b}"))
        settle()
        check(!board.drag.isDragging && board.order == "host\ncpu\ngpu" && listed().count == 7, "Escape with nothing dragged changes nothing")

        // 5. The mouse coming up without the gesture ending it: the groups
        // show their rows again soon after. And a button going down.
        drag("gpu", from: middle("gpu"), to: between(nil, "host"))
        check(listed().count == 3, "gpu dragged")
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: elsewhere.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.sendEvent(mouse(.leftMouseUp))
        settle(0.05)
        check(board.drag.isDragging, "not before the gesture could have ended it")
        settle(0.4)
        check(!board.drag.isDragging && listed().count == 7 && board.order == "host\ncpu\ngpu", "then each group is back, nothing moved")
        let gpuStart = middle("gpu")
        drag("gpu", from: gpuStart, to: between(nil, "host"))
        check(listed().count == 3, "gpu dragged again")
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown))
        settle()
        check(!board.drag.isDragging && listed().count == 7 && board.order == "host\ncpu\ngpu", "a press ends a drag left over at once")
        settle(0.3)
        check(!window.isVisible && !elsewhere.isVisible, "the presses showed no window")

        // 6. Let go over the terminal: nothing moves, nothing is pasted.
        _ = HerdrItemDrag.provider(for: rows["host"]![0].item)
        let lastRowDragged = HerdrItemDrag.dragged
        _ = received()
        targets = []; sends = []
        let overTerminal = CGPoint(x: listWidth + 200, y: height / 2)
        drag("gpu", from: gpuStart, to: overTerminal)
        check(board.drag.isDragging && board.drag.line == nil, "over the terminal: no line")
        letGo("gpu", from: gpuStart, at: overTerminal)
        check(HerdrItemDrag.dragged == lastRowDragged, "a header's drag leaves the row dragged last as it was")
        check(targets.isEmpty && sends.isEmpty && received().isEmpty, "the terminal never lit up and got zero bytes")
        check(!board.drag.isDragging && board.order == "host\ncpu\ngpu" && listed().count == 7, "let go there: nothing moves")
        check(terminal.registeredDraggedTypes == [HerdrItemDrag.pasteboardType], "the terminal takes rows' drags only")
        do {
            // What a header could put in a drag, if anything did: its name.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("shepherd-group-order-test-" + UUID().uuidString))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let item = NSPasteboardItem(); item.setData(Data(), forType: HerdrItemDrag.pasteboardType); item.setString("gpu", forType: .string)
            precondition(pasteboard.writeObjects([item]))
            let named = OwnedDrag(pasteboard, source: outline)
            check(terminal.draggingEntered(named) == [] && !terminal.performDragOperation(named), "a group's name isn't pasted")
            terminal.draggingEnded(named)
            check(targets.isEmpty && sends.isEmpty && received().isEmpty, "zero bytes")
        }
        // A row still pastes its ID.
        do {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("shepherd-group-order-test-" + UUID().uuidString))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let hostRow = listed().firstIndex(of: "host/w1:p1")!
            guard let writer = dataSource.outlineView?(outline, pasteboardWriterForItem: outline.item(atRow: hostRow) as Any) else { preconditionFailure("a row's writer") }
            precondition(pasteboard.writeObjects([writer]))
            let rowDrag = OwnedDrag(pasteboard, source: outline)
            check(terminal.draggingEntered(rowDrag) == .move && terminal.performDragOperation(rowDrag), "a host row dropped on the terminal")
            terminal.draggingEnded(rowDrag)
            check(sends == [Array("w1:p1 ".utf8)] && received() == Array("w1:p1 ".utf8), "pastes its ID, as before: \(sends)")
            sends = []
        }

        // 7. With a search: the groups it leaves are the ones moved among;
        // the others keep their places.
        board.searchLeaves = ["host", "gpu"]
        settle()
        check(listed() == ["#host", "host/w1:p1", "host/w1:p2", "#gpu", "gpu/w1:p1", "gpu/w1:p2"], "searched: cpu left out, folded or not the rows listed: \(listed())")
        let searchedGPU = middle("gpu")
        drag("gpu", from: searchedGPU, to: between(nil, "host"))
        check(listed() == ["#host", "#gpu"], "the headers alone while one is dragged, searched too: \(listed())")
        letGo("gpu", from: searchedGPU, at: between(nil, "host"))
        check(board.order == "gpu\nhost\ncpu", "gpu to the top, cpu after host where it was: \(board.order.debugDescription)")
        board.searchLeaves = nil
        settle()
        check(listed() == ["#gpu", "gpu/w1:p1", "gpu/w1:p2", "#host", "host/w1:p1", "host/w1:p2", "#cpu"], "and without the search: \(listed())")

        // 8. A herdr machine added goes last; one removed is left out of the
        // order the next time it is kept.
        board.groups = ["host", "gpu", "cpu", "tpu"]
        board.rows["tpu"] = []
        settle()
        check(board.shown == ["gpu", "host", "cpu", "tpu"] && listed() == ["#gpu", "gpu/w1:p1", "gpu/w1:p2", "#host", "host/w1:p1", "host/w1:p2", "#cpu", "#tpu"],
              "tpu after the kept ones: \(listed())")
        board.groups = ["host", "cpu", "tpu"]
        settle()
        check(board.shown == ["host", "cpu", "tpu"] && board.order == "gpu\nhost\ncpu", "gpu gone, still in the order kept")
        let tpuStart = middle("tpu")
        drag("tpu", from: tpuStart, to: between(nil, "host"))
        letGo("tpu", from: tpuStart, at: between(nil, "host"))
        check(board.order == "tpu\nhost\ncpu", "kept again: tpu first, gpu left out: \(board.order.debugDescription)")
        check(listed() == ["#tpu", "#host", "host/w1:p1", "host/w1:p2", "#cpu"], "\(listed())")
        check(board.collapsed == "cpu" && board.collapsedWrites == 0, "the folded groups kept never changed")
        check(!window.isVisible && !elsewhere.isVisible, "no window was shown")
    }
}
