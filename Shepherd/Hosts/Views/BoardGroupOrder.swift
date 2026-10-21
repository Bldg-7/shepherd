import SwiftUI
import AppKit

/// The order of the board's groups — the host's own herdr and each herdr
/// machine — that the person has put them in by dragging their headers (see
/// `BoardGroupDrag`). herdr has nothing to keep it in: its machines come in
/// the order `herdr machine list` gives them, which is the order the groups
/// take until they are moved, the host's own first.
///
/// Kept per Shepherd Machine as the folded groups are (see
/// `AgentBoardView`), by group ID, one per line: `host` for the host's own,
/// and each herdr machine's profile ID.
nonisolated enum BoardGroupOrder {
    /// The group IDs kept in `stored`, in order.
    static func ids(_ stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init)
    }

    /// How `ids` are kept.
    static func stored(_ ids: [String]) -> String {
        ids.joined(separator: "\n")
    }

    /// `groups` in the order kept: those in `saved` as they are there, then
    /// the others — a herdr machine added since — after them, in the order
    /// they come in. A group ID kept for a group that isn't there any more
    /// counts for nothing.
    static func ordered<Group>(_ groups: [Group], by id: (Group) -> String, saved: [String]) -> [Group] {
        let place = Dictionary(saved.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return groups.enumerated().sorted { a, b in
            switch (place[id(a.element)], place[id(b.element)]) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Which gap among the group headers `shown` — from 0, above the first,
    /// to `shown.count`, below the last — a header dropped at `y` goes into,
    /// by where each of them is on screen (`frames`, from the top down): the
    /// gap above the first header whose middle is below `y`. A header that
    /// hasn't been laid out yet isn't counted.
    static func gap(at y: CGFloat, among shown: [String], frames: [String: CGRect]) -> Int {
        shown.firstIndex { id in frames[id].map { y < $0.midY } ?? false } ?? shown.count
    }

    /// `order` with `id` moved into `gap` among the groups `shown`, or nil
    /// when that leaves it where it is. The groups `order` has besides those
    /// shown — ones the search leaves out — keep their places among the
    /// rest: moved up, the group goes right before the shown group below the
    /// gap; moved down, right after the one above it.
    static func moving(_ id: String, toGap gap: Int, among shown: [String], in order: [String]) -> [String]? {
        guard let from = shown.firstIndex(of: id), order.contains(id),
              (0...shown.count).contains(gap), gap != from, gap != from + 1 else { return nil }
        var others = shown
        others.remove(at: from)
        var moved = order
        moved.removeAll { $0 == id }
        if gap > from {
            // Counted without the group itself, the one above the gap is
            // one place further up.
            guard let index = moved.firstIndex(of: others[gap - 2]) else { return nil }
            moved.insert(id, at: index + 1)
        } else {
            guard let index = moved.firstIndex(of: others[gap]) else { return nil }
            moved.insert(id, at: index)
        }
        return moved
    }
}

/// Whether a group of the board shows its rows. The person folds a group
/// away by its header; a search or workspace filter shows what it leaves of
/// every group, folded or not; and while a group's header is being dragged
/// to another place (see `BoardGroupDrag`) every group shows its header
/// alone, folded or not — without any of that changing which groups the
/// person has folded, which they show again as they were once the drag ends.
nonisolated enum BoardGroupFolding {
    /// Whether `groupID` is among the folded groups `collapsed` keeps, one
    /// per line.
    static func isCollapsed(_ groupID: String, in collapsed: String) -> Bool {
        collapsed.split(separator: "\n").contains(Substring(groupID))
    }

    /// Whether the group's rows are listed. `isFoldedForDrag` while the
    /// group shows its header alone for a drag (see
    /// `BoardGroupDrag.foldsRows(of:)`).
    static func listsRows(isCollapsed: Bool, isFiltering: Bool, isFoldedForDrag: Bool) -> Bool {
        !isFoldedForDrag && (isFiltering || !isCollapsed)
    }

    /// Whether the group's header shows it unfolded — the search and the
    /// filter leave that as the person set it.
    static func looksExpanded(isCollapsed: Bool, isFoldedForDrag: Bool) -> Bool {
        !isFoldedForDrag && !isCollapsed
    }

    /// `collapsed` with `groupID` folded if it wasn't, unfolded if it was —
    /// what a click on its header does. Nil while groups are folded for a
    /// drag (see `BoardGroupDrag.isFolding`): they are folded for the drag
    /// only, and what is kept isn't written.
    static func toggling(_ groupID: String, in collapsed: String, isFoldingForDrag: Bool) -> String? {
        guard !isFoldingForDrag else { return nil }
        var groups = Set(collapsed.split(separator: "\n").map(String.init))
        if groups.contains(groupID) {
            groups.remove(groupID)
        } else {
            groups.insert(groupID)
        }
        return groups.sorted().joined(separator: "\n")
    }
}

/// A group header being dragged to another place on the board.
///
/// The drag is the header's own gesture (see `boardGroupDrag`), not a drag
/// and drop through the pasteboard: nothing of it leaves the sidebar, so a
/// terminal it is let go over takes nothing, and a row's drag onto a
/// terminal (see `HerdrItemDrag`) is left as it was. From the moment the
/// header starts to move until the drag ends — let go anywhere, Escape, or
/// the mouse coming up without the gesture saying so — every group shows its
/// header alone; a line shows where the header would go.
///
/// The rows come back in steps once it ends, each in an update of the list
/// of its own: the group's move while every group still shows its header
/// alone, then the rows of every group but the last one listed, then the
/// last one's. In fewer updates — the move with the rows, or the last
/// group's rows with any other's — the List has AppKit's table view insert
/// rows from inside its own update, which AppKit reports as a reentrant
/// table view operation, a warning it says will become an assert.
///
/// Where the headers and the pointer are is read from AppKit, in the list's
/// coordinates from its top left (see `boardGroupInsertionLine`): SwiftUI's
/// own geometry of a List's row isn't brought up to date when the list
/// moves the row's view to another place.
@MainActor @Observable
final class BoardGroupDrag {
    /// The group whose header is being dragged, while one is.
    private(set) var draggedID: String?
    /// Whether every group shows its header alone: from the drag's start
    /// until its end's first step, then — for one more step — only
    /// `heldID`.
    private(set) var foldsAll = false
    private(set) var heldID: String?
    /// The line where the header would go if it were let go now: across the
    /// headers, between the two it would go between, in the list's
    /// coordinates. Nil while it would stay where it is, or is outside the
    /// list.
    private(set) var line: CGRect?

    /// The view the list is laid out in, and the ones in the headers (see
    /// `BoardGroupAnchor`).
    @ObservationIgnored private(set) weak var listView: NSView?
    @ObservationIgnored private var headerViews: [Weak] = []
    /// The gesture the drag is — or the drag Escape ended was — part of. The
    /// rest of a gesture whose drag was ended before the mouse came up is
    /// ignored.
    @ObservationIgnored private var gesture: Gesture?
    @ObservationIgnored private var isCancelled = false
    /// Where the pointer was last, and the groups shown then.
    @ObservationIgnored private var location: CGPoint?
    @ObservationIgnored private var shown: [String] = []
    @ObservationIgnored private var monitor: Any?
    /// Counts the drags, so that a step of one's end left for later does
    /// nothing once another has started.
    @ObservationIgnored private var drags = 0
    /// How long after the mouse comes up a drag the gesture hasn't ended is
    /// ended anyway: long enough for the gesture's own end to have come.
    let lateEndDelay: Duration

    private struct Gesture: Equatable {
        let groupID: String
        let start: CGPoint
    }

    private struct Weak {
        weak var view: BoardGroupAnchorView?
    }

    init(lateEndDelay: Duration = .milliseconds(300)) {
        self.lateEndDelay = lateEndDelay
    }

    isolated deinit { stopWatching() }

    var isDragging: Bool { draggedID != nil }

    /// Whether the group shows its header alone for a drag.
    func foldsRows(of groupID: String) -> Bool {
        foldsAll || heldID == groupID
    }

    /// Whether any group shows its header alone for a drag.
    var isFolding: Bool { foldsAll || heldID != nil }

    /// `view` is where the list is laid out, or — with a group ID — in a
    /// group's header.
    func register(_ view: BoardGroupAnchorView) {
        guard view.groupID != nil else {
            listView = view
            return
        }
        headerViews.removeAll { $0.view == nil || $0.view === view }
        headerViews.append(Weak(view: view))
    }

    /// Where each header in the list's window is now, by group ID: by the
    /// header views there are in it, whichever group each is for now — the
    /// list makes and reuses them as it likes.
    var headerFrames: [String: CGRect] {
        guard let listView, let window = listView.window else { return [:] }
        var frames: [String: CGRect] = [:]
        for anchor in headerViews {
            guard let view = anchor.view, let groupID = view.groupID, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            frames[groupID] = listView.convert(view.bounds, from: view)
        }
        return frames
    }

    /// Where the pointer is now, in the list's coordinates.
    func pointer() -> CGPoint? {
        guard let listView, let window = listView.window else { return nil }
        return listView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// The gap among the headers shown the header would go into, as `line`
    /// shows it.
    private var gap: Int? {
        guard let draggedID, let location, let listView, listView.bounds.contains(location) else { return nil }
        let gap = BoardGroupOrder.gap(at: location.y, among: shown, frames: headerFrames)
        guard let from = shown.firstIndex(of: draggedID), gap != from, gap != from + 1 else { return nil }
        return gap
    }

    /// The header of `groupID`, pressed at `start`, has been dragged to
    /// `location` (nil: away from the list's window), with the groups
    /// `shown` in that order. The first move of a gesture starts the drag.
    func drag(_ groupID: String, from start: CGPoint, to location: CGPoint?, among shown: [String]) {
        let gesture = Gesture(groupID: groupID, start: start)
        if self.gesture == gesture && isCancelled { return }
        if self.gesture != gesture {
            finish()
            self.gesture = gesture
            drags += 1
            draggedID = groupID
            heldID = nil
            foldsAll = true
            startWatching()
        }
        self.location = location
        self.shown = shown
        updateLine()
    }

    /// The header of `groupID`, pressed at `start`, has been let go at
    /// `location`. Ends the drag, and gives the gap among the groups `shown`
    /// the group is to be moved into — nil to leave it where it is: let go
    /// outside the list, in its own place, or after Escape.
    ///
    /// The group is to be moved straight away, while every group still shows
    /// its header alone; their rows come back after.
    func drop(_ groupID: String, from start: CGPoint, at location: CGPoint?, among shown: [String]) -> Int? {
        guard gesture == Gesture(groupID: groupID, start: start) else { return nil }
        self.location = location
        self.shown = shown
        let gap = isCancelled ? nil : gap
        let listed = gap.flatMap { BoardGroupOrder.moving(groupID, toGap: $0, among: shown, in: shown) } ?? shown
        finish(lastListed: listed.last)
        return gap
    }

    /// Ends the drag where it is, moving nothing. The rest of its gesture,
    /// until the mouse comes up, is ignored.
    func cancel() {
        guard isDragging else { return }
        draggedID = nil
        line = nil
        isCancelled = true
        unfold(lastListed: shown.last)
    }

    /// Forgets the drag and its gesture altogether.
    func finish() {
        finish(lastListed: shown.last)
    }

    private func finish(lastListed: String?) {
        stopWatching()
        gesture = nil
        isCancelled = false
        location = nil
        draggedID = nil
        line = nil
        unfold(lastListed: lastListed)
    }

    /// Has every group show its rows again — as the person left it — in
    /// steps (see above): the group listed last, `lastListed`, after the
    /// others.
    private func unfold(lastListed: String?) {
        guard foldsAll else { return }
        let drag = drags
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.drags == drag, self.foldsAll, !self.isDragging else { return }
                self.heldID = lastListed
                self.foldsAll = false
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.drags == drag else { return }
                        self.heldID = nil
                    }
                }
            }
        }
    }

    /// The mouse came up. The gesture says so itself (`drop`); one it hasn't
    /// said it of by `lateEndDelay` later is over anyway — the view it was on
    /// went away, say — and the groups show their rows again.
    func mouseCameUp() {
        guard let ended = gesture else { return }
        Task { [weak self, lateEndDelay] in
            try? await Task.sleep(for: lateEndDelay)
            guard let self, self.gesture == ended else { return }
            self.finish()
        }
    }

    /// A mouse button went down: whatever drag is left over from before is
    /// over.
    func mouseWentDown() {
        if gesture != nil {
            finish()
        }
    }

    private func updateLine() {
        line = gap.flatMap { gap in Self.line(atGap: gap, among: shown, frames: headerFrames) }
    }

    /// The line drawn in `gap` among the headers `shown`: halfway between
    /// the header above it and the one below, or as far above the first or
    /// below the last as that is.
    static func line(atGap gap: Int, among shown: [String], frames: [String: CGRect]) -> CGRect? {
        let placed = shown.compactMap { frames[$0] }
        guard placed.count == shown.count, !placed.isEmpty, (0...placed.count).contains(gap) else { return nil }
        let half = placed.count > 1 ? max(0, placed[1].minY - placed[0].maxY) / 2 : 4
        let y = switch gap {
        case 0: placed[0].minY - half
        case placed.count: placed[placed.count - 1].maxY + half
        default: (placed[gap - 1].maxY + placed[gap].minY) / 2
        }
        let header = placed[min(gap, placed.count - 1)]
        return CGRect(x: header.minX, y: y - Self.lineWidth / 2, width: header.width, height: Self.lineWidth)
    }

    static let lineWidth: CGFloat = 2

    /// While a header is being dragged: Escape ends the drag, and goes no
    /// further — not to a terminal that has the keyboard. A mouse button
    /// going up or down is how a drag the gesture leaves unended ends.
    private func startWatching() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            // Local monitors run on the main thread; only what the decision
            // needs is handed over to it, not the event.
            let type = event.type
            let keyCode = type == .keyDown ? event.keyCode : nil
            let keeps = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                switch type {
                case .leftMouseUp:
                    self.mouseCameUp()
                case .leftMouseDown:
                    self.mouseWentDown()
                default:
                    if keyCode == Self.escapeKeyCode && self.isDragging {
                        self.cancel()
                        return false
                    }
                }
                return true
            }
            return keeps ? event : nil
        }
    }

    private func stopWatching() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static let escapeKeyCode: UInt16 = 53
}

/// A view with nothing to show that tells a `BoardGroupDrag` where it is: in
/// a group's header, or — with no group — behind the list, where it takes
/// the list's place and coordinates.
struct BoardGroupAnchor: NSViewRepresentable {
    let drag: BoardGroupDrag
    let groupID: String?

    func makeNSView(context: Context) -> BoardGroupAnchorView {
        BoardGroupAnchorView()
    }

    func updateNSView(_ view: BoardGroupAnchorView, context: Context) {
        view.groupID = groupID
        drag.register(view)
    }
}

/// Counted from the top left, as SwiftUI counts; takes no clicks.
final class BoardGroupAnchorView: NSView {
    /// The group whose header it is in, or nil behind the list.
    var groupID: String?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Lets a group's header be dragged to another place among the groups
    /// `shown` (see `BoardGroupDrag`); `onDrop` is given the gap it was let
    /// go in. A click still folds or unfolds the group: the drag starts only
    /// once the pointer has moved a few points with the button down.
    func boardGroupDrag(_ groupID: String, drag: BoardGroupDrag, among shown: [String], onDrop: @escaping (Int) -> Void) -> some View {
        self
            .opacity(drag.draggedID == groupID ? 0.5 : 1)
            .background(BoardGroupAnchor(drag: drag, groupID: groupID))
            // Over the header's own click, which a drag is not. The gesture
            // says when the header moves and when it is let go; where the
            // pointer is then is AppKit's to say (see `BoardGroupDrag`).
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        drag.drag(groupID, from: value.startLocation, to: drag.pointer(), among: shown)
                    }
                    .onEnded { value in
                        if let gap = drag.drop(groupID, from: value.startLocation, at: drag.pointer(), among: shown) {
                            onDrop(gap)
                        }
                    }
            )
    }

    /// The line where a group header being dragged would go, over the list
    /// the headers are in. It takes no clicks.
    func boardGroupInsertionLine(_ drag: BoardGroupDrag) -> some View {
        self
            .background(BoardGroupAnchor(drag: drag, groupID: nil))
            .overlay(alignment: .topLeading) {
                if let line = drag.line {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: line.width, height: line.height)
                        .offset(x: line.minX, y: line.minY)
                        .allowsHitTesting(false)
                }
            }
    }
}
