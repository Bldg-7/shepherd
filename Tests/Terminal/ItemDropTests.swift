import AppKit
import SwiftUI
import SwiftTerm
import Darwin

/// A drag as AppKit hands it to a destination, over an owned, uniquely named
/// pasteboard: not the user's, and released at the end. `source` stands in
/// for the view a drag in this process starts from; nil is a drag from
/// another app.
final class OwnedDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let source: AnyObject?
    let mask: NSDragOperation
    init(_ pasteboard: NSPasteboard, source: AnyObject?, mask: NSDragOperation = .move) {
        draggingPasteboard = pasteboard
        self.source = source
        self.mask = mask
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
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

/// One sidebar row in the test's list: what it shows, and the item its drag is of.
struct Row: Identifiable {
    let id: String
    let title: String
    let item: HerdrItemDrag.Item
}

/// A List as the sidebar's: selectable rows in a section, each with a
/// context menu and the production drag modifier.
struct RowList: View {
    let rows: [Row]
    @State private var selection: String?
    var body: some View {
        List(selection: $selection) {
            Section("Owned") {
                ForEach(rows) { row in
                    HStack { Text(verbatim: row.title); Spacer() }
                        .contextMenu { Button("Close") {} }
                        .herdrItemDrag(row.item)
                }
            }
        }
    }
}

@MainActor @Observable final class Highlight {
    var shown = false
}

/// The production terminal wrapper with the production drop and highlight,
/// as PaneTerminalView puts them together.
struct HighlightedTerminal: View {
    let highlight: Highlight
    let drop: (@escaping (Bool) -> Void) -> TerminalTextDrop?
    let onCreate: (TerminalView) -> Void
    let onInput: (ArraySlice<UInt8>) -> Void
    var body: some View {
        TerminalHostView(onCreate: onCreate, onInput: onInput, onResize: { _, _ in },
                         textDrop: drop { highlight.shown = $0 })
            .itemDropHighlight(highlight.shown)
    }
}

/// A view that takes the keyboard, to show a drop leaves it where it is.
final class KeyboardHolder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

func findOutline(_ view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for sub in view.subviews { if let outline = findOutline(sub) { return outline } }
    return nil
}

@main @MainActor enum ItemDropTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: @autoclosure () -> String) {
        precondition(condition, why())
        checks += 1
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // The servers: two Shepherd Machines, the first again after its
        // credentials changed (another connection), and two herdr machines.
        let hostA = Machine(displayName: "Owned A", hostname: "a.invalid", username: "fixture")
        let hostB = Machine(displayName: "Owned B", hostname: "b.invalid", username: "fixture")
        var hostAAgain = hostA
        hostAAgain.keychainTag = "herdr-client.private-key.replaced"
        let local = Machine(id: UUID(), displayName: "This Mac", hostname: "localhost", username: "fixture", isLocal: true)
        let connA = hostA.connectionIdentity, connB = hostB.connectionIdentity, connAAgain = hostAAgain.connectionIdentity
        let connLocal = local.connectionIdentity
        check(connA != connB && connA != connAAgain && connA != connLocal, "four connections")
        let gpu = HerdrMachine(id: "gpu", label: "gpu", target: "never-connect", session: "default", enabled: true)
        let cpu = HerdrMachine(id: "cpu", label: "cpu", target: "never-connect", session: "default", enabled: true)

        func pane(_ id: String, on machine: HerdrMachine? = nil) -> AgentSummary {
            AgentSummary(json: .object(["pane_id": .string(id), "terminal_id": .string("term-" + id), "tab_id": .string("w1:t2")]), on: machine)!
        }
        func tab(_ id: String, on machine: HerdrMachine? = nil) -> TabSummary {
            TabSummary(tab: .object(["tab_id": .string(id), "label": .string("tab " + id)]), layout: nil, panes: [:], on: machine)!
        }

        // 1. The rules, without views.
        let hostPane = HerdrItemDrag.Item(pane: pane("w1:p4"), on: connA)
        let hostTab = HerdrItemDrag.Item(tab: tab("w1:t2"), on: connA)
        let gpuPane = HerdrItemDrag.Item(pane: pane("w1:p1", on: gpu), on: connA)
        let gpuTab = HerdrItemDrag.Item(tab: tab("w1:t1", on: gpu), on: connA)
        let cpuPane = HerdrItemDrag.Item(pane: pane("w1:p1", on: cpu), on: connA)
        let localPane = HerdrItemDrag.Item(pane: pane("w1:p4"), on: connLocal)
        check(hostPane.kind == .pane && hostPane.herdrID == "w1:p4" && hostPane.herdrMachineID == nil && hostPane.connection == connA, "a pane: its paneID")
        check(hostTab.kind == .tab && hostTab.herdrID == "w1:t2" && hostTab.herdrMachineID == nil, "a tab: its tabID")
        check(gpuPane.herdrMachineID == "gpu" && gpuTab.herdrMachineID == "gpu" && gpuTab.herdrID == "w1:t1", "a herdr machine's, by its profile ID")
        check(HerdrItemDrag.Item(pane: pane("w1:p4"), on: connA) == hostPane && hostPane != localPane && gpuPane != cpuPane, "items are told apart by connection and herdr machine")

        struct Case { let text: String; let dragged: HerdrItemDrag.Item?; let connection: Machine.ConnectionIdentity; let machine: String?; let paste: String?; let why: String }
        let table = [
            Case(text: "w1:p4", dragged: hostPane, connection: connA, machine: nil, paste: "w1:p4 ", why: "host pane on the same host"),
            Case(text: "w1:t2", dragged: hostTab, connection: connA, machine: nil, paste: "w1:t2 ", why: "host tab on the same host"),
            Case(text: "w1:p1", dragged: gpuPane, connection: connA, machine: "gpu", paste: "w1:p1 ", why: "gpu pane on gpu"),
            Case(text: "w1:t1", dragged: gpuTab, connection: connA, machine: "gpu", paste: "w1:t1 ", why: "gpu tab on gpu"),
            Case(text: "w1:p4", dragged: localPane, connection: connLocal, machine: nil, paste: "w1:p4 ", why: "This Mac's pane on This Mac"),
            Case(text: "w1:p1", dragged: gpuPane, connection: connA, machine: nil, paste: nil, why: "gpu pane on the host"),
            Case(text: "w1:p4", dragged: hostPane, connection: connA, machine: "gpu", paste: nil, why: "host pane on gpu"),
            Case(text: "w1:p1", dragged: gpuPane, connection: connA, machine: "cpu", paste: nil, why: "gpu pane on cpu"),
            Case(text: "w1:p1", dragged: cpuPane, connection: connA, machine: "gpu", paste: nil, why: "cpu pane on gpu"),
            Case(text: "w1:p4", dragged: hostPane, connection: connB, machine: nil, paste: nil, why: "another Machine"),
            Case(text: "w1:p4", dragged: hostPane, connection: connAAgain, machine: nil, paste: nil, why: "the same Machine, another connection"),
            Case(text: "w1:p4", dragged: localPane, connection: connA, machine: nil, paste: nil, why: "This Mac's pane on an SSH host"),
            Case(text: "w1:p1", dragged: gpuPane, connection: connB, machine: "gpu", paste: nil, why: "a herdr machine of the same name on another Machine"),
            Case(text: "w1:p5", dragged: hostPane, connection: connA, machine: nil, paste: nil, why: "text other than the dragged ID"),
            Case(text: "w1:p4 ", dragged: hostPane, connection: connA, machine: nil, paste: nil, why: "text with more than the ID"),
            Case(text: "w1:p4", dragged: nil, connection: connA, machine: nil, paste: nil, why: "nothing dragged"),
        ]
        for row in table {
            check(HerdrItemDrag.pasteText(for: row.text, dragged: row.dragged, connection: row.connection, herdrMachineID: row.machine) == row.paste, row.why)
        }
        for id in ["w1:p4", "w1:t2", "w12:p345", "a", "A_b-C:9", String(repeating: "x", count: 64)] {
            check(HerdrItemDrag.isPastable(id), "pastable: \(id)")
        }
        for id in ["", " ", "w1:p4 ", "w1 p4", "w1:p4\n", "w1:p4\r", "\u{1b}[201~", "w1:p4\u{1b}[201~echo", "w1/p4", "w1;p4", "w1.p4", "'w1'", "$(id)", "ｗ1:p4", "w1:p4\u{2028}", "é", String(repeating: "x", count: 65)] {
            check(!HerdrItemDrag.isPastable(id), "not pastable: \(id.debugDescription)")
        }
        let unsafe = HerdrItemDrag.Item(pane: pane("w1:p4\u{1b}[201~x"), on: connA)
        check(HerdrItemDrag.pasteText(for: unsafe.herdrID, dragged: unsafe, connection: connA, herdrMachineID: nil) == nil, "an ID that could end the paste is refused even when it matches")
        let operations: [(NSDragOperation, NSDragOperation)] = [
            (.move, .move), ([.copy, .move], .copy), ([.generic, .move], .generic), ([.copy, .generic, .move], .copy),
            (.every, .copy), (.generic, .generic), (.copy, .copy), (.link, []), ([.link, .delete], []), ([], []), (.private, []),
        ]
        for (mask, expected) in operations {
            check(TerminalTextDrop.operation(for: mask) == expected, "operation for \(mask.rawValue)")
        }
        print("rules: \(checks)")

        // 2. The drag source: the production modifier on a List's rows, in a
        // never-shown window. What the list's writer puts on an owned
        // pasteboard, and what the app keeps.
        let rows = [
            Row(id: "w1:p4", title: "host pane", item: hostPane),
            Row(id: "w1:t2", title: "host tab", item: hostTab),
            Row(id: "gpu/w1:p1", title: "gpu pane", item: gpuPane),
            Row(id: "gpu/w1:t1", title: "gpu tab", item: gpuTab),
        ]
        let listWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        listWindow.isReleasedWhenClosed = false
        defer { listWindow.close() }
        let listHost = NSHostingView(rootView: RowList(rows: rows))
        listHost.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        listWindow.contentView = listHost
        listHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        check(!listWindow.isVisible, "the list's window is never shown")
        guard let outline = findOutline(listHost), let dataSource = outline.dataSource else { preconditionFailure("the List is an outline view") }
        check(HerdrItemDrag.dragged == nil, "showing the rows starts no drag")
        let marker = NSPasteboard.PasteboardType("com.bldg-7.shepherd.herdr-item")
        check(HerdrItemDrag.pasteboardType == marker, "the marker type")
        var written: [String: NSPasteboard] = [:]
        var pasteboards: [NSPasteboard] = []
        defer { for pasteboard in pasteboards { pasteboard.releaseGlobally() } }
        func ownedPasteboard() -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("shepherd-item-drop-test-" + UUID().uuidString))
            pasteboards.append(pasteboard)
            pasteboard.clearContents()
            return pasteboard
        }
        var writers = 0
        for index in 0..<outline.numberOfRows {
            guard let writer = dataSource.outlineView?(outline, pasteboardWriterForItem: outline.item(atRow: index) as Any) else { continue }
            writers += 1
            let row = rows[writers - 1]
            check(HerdrItemDrag.dragged == row.item, "asking a row for its drag keeps its item: \(row.title)")
            let pasteboard = ownedPasteboard()
            check(pasteboard.writeObjects([writer]), "the writer writes")
            let types = pasteboard.types ?? []
            check(types.contains(marker) && types.contains(.string), "the marker and plain text: \(types.map(\.rawValue))")
            check(!types.contains(.URL) && !types.contains(.fileURL) && !types.contains(NSPasteboard.PasteboardType("public.url")), "no URL: \(types.map(\.rawValue))")
            check(pasteboard.string(forType: .string) == row.item.herdrID, "the text is herdr's ID alone: \(pasteboard.string(forType: .string) ?? "nil")")
            written[row.id] = pasteboard
        }
        check(writers == rows.count, "every row has a drag: \(writers)")
        check(HerdrItemDrag.dragged == gpuTab, "the last row asked is the one kept")
        print("drag source: \(checks)")

        // 3. The drop target: the production terminal view with pinned
        // SwiftTerm, in an owned never-shown window, bytes checked through
        // an owned kernel PTY.
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

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let view = FocusReportingTerminalView(frame: NSRect(x: 0, y: 40, width: 640, height: 320))
        let holder = KeyboardHolder(frame: NSRect(x: 0, y: 0, width: 640, height: 40))
        container.addSubview(view)
        container.addSubview(holder)
        window.contentView = container
        var sends: [[UInt8]] = []
        let coordinator = TerminalHostView.Coordinator(onInput: { bytes in
            sends.append(Array(bytes))
            Array(bytes).withUnsafeBytes { precondition(Darwin.write(master, $0.baseAddress, $0.count) == $0.count) }
        }, onResize: { _, _ in }, onOpenLink: nil)
        view.terminalDelegate = coordinator
        check(window.makeFirstResponder(holder) && window.firstResponder === holder, "another view has the keyboard")

        let source = NSView()
        var targets: [Bool] = []
        func drop(on connection: Machine.ConnectionIdentity, machine: String?) -> TerminalTextDrop {
            HerdrItemDrag.terminalDrop(connection: connection, herdrMachineID: machine) { targets.append($0) }
        }
        check(view.registeredDraggedTypes.isEmpty, "no handlers, no drags taken")
        view.textDrop = drop(on: connA, machine: nil)
        check(view.registeredDraggedTypes == [marker], "the text drop registers its marker only: \(view.registeredDraggedTypes.map(\.rawValue))")

        /// A marked drag of `text` from inside the app, after `item`'s row was asked for its drag.
        func rowDrag(_ item: HerdrItemDrag.Item?, text: String? = nil, mask: NSDragOperation = .move, source: AnyObject? = source, marked: Bool = true) -> OwnedDrag {
            if let item { _ = HerdrItemDrag.provider(for: item) }
            let pasteboard = ownedPasteboard()
            let pasteboardItem = NSPasteboardItem()
            if marked { pasteboardItem.setData(Data(), forType: marker) }
            if let string = text ?? item?.herdrID { pasteboardItem.setString(string, forType: .string) }
            precondition(pasteboard.writeObjects([pasteboardItem]))
            return OwnedDrag(pasteboard, source: source, mask: mask)
        }
        func expectPaste(_ drag: OwnedDrag, operation: NSDragOperation, bytes: [UInt8], _ why: String) {
            targets = []; sends = []
            check(view.draggingEntered(drag) == operation && view.draggingUpdated(drag) == operation, why + ": taken as \(operation.rawValue)")
            check(targets == [true], why + ": highlighted once: \(targets)")
            check(view.performDragOperation(drag), why + ": dropped")
            view.draggingEnded(drag)
            check(targets == [true, false], why + ": highlight gone after the drop: \(targets)")
            check(sends == [bytes] && received() == bytes, why + ": one paste, the bytes reach the PTY: \(sends)")
            check(window.firstResponder === holder, why + ": the keyboard stays where it was")
        }
        func expectRefused(_ drag: OwnedDrag, _ why: String) {
            targets = []; sends = []
            check(view.draggingEntered(drag) == [] && view.draggingUpdated(drag) == [], why + ": not taken")
            check(!view.performDragOperation(drag), why + ": not dropped")
            view.draggingEnded(drag)
            check(targets.isEmpty, why + ": never highlighted: \(targets)")
            check(sends.isEmpty && received().isEmpty, why + ": zero bytes")
            check(window.firstResponder === holder, why + ": the keyboard stays where it was")
        }

        // The rows' own pasteboards from the list above, end to end.
        _ = HerdrItemDrag.provider(for: hostPane)
        expectPaste(OwnedDrag(written["w1:p4"]!, source: outline), operation: .move, bytes: Array("w1:p4 ".utf8), "the list's own pane drag")
        _ = HerdrItemDrag.provider(for: hostTab)
        expectPaste(OwnedDrag(written["w1:t2"]!, source: outline), operation: .move, bytes: Array("w1:t2 ".utf8), "the list's own tab drag")
        expectPaste(rowDrag(hostPane), operation: .move, bytes: Array("w1:p4 ".utf8), "a pane")
        expectPaste(rowDrag(hostTab), operation: .move, bytes: Array("w1:t2 ".utf8), "a tab")
        expectPaste(rowDrag(hostPane, mask: [.copy, .move]), operation: .copy, bytes: Array("w1:p4 ".utf8), "copy first")
        expectPaste(rowDrag(hostPane, mask: [.generic, .move]), operation: .generic, bytes: Array("w1:p4 ".utf8), "then generic")
        expectPaste(rowDrag(hostPane, mask: .every), operation: .copy, bytes: Array("w1:p4 ".utf8), "any")
        let longest = HerdrItemDrag.Item(pane: pane(String(repeating: "p", count: 64)), on: connA)
        expectPaste(rowDrag(longest), operation: .move, bytes: Array((longest.herdrID + " ").utf8), "64 characters")
        // Between the bracketed-paste markers once the program asks for them.
        view.feed(text: "\u{1b}[?2004h")
        expectPaste(rowDrag(hostPane), operation: .move, bytes: Array("\u{1b}[200~w1:p4 \u{1b}[201~".utf8), "bracketed")
        expectPaste(rowDrag(hostTab), operation: .move, bytes: Array("\u{1b}[200~w1:t2 \u{1b}[201~".utf8), "bracketed tab")
        view.feed(text: "\u{1b}[?2004l")
        expectPaste(rowDrag(hostPane), operation: .move, bytes: Array("w1:p4 ".utf8), "plain again")

        expectRefused(rowDrag(hostPane, source: nil), "from another app")
        expectRefused(rowDrag(hostPane, marked: false), "unmarked text from inside the app")
        expectRefused(rowDrag(hostPane, text: "w1:p5"), "text other than the dragged ID")
        expectRefused(rowDrag(hostTab, text: "w1:p4"), "a pane's ID, a tab's row dragged since")
        expectRefused(rowDrag(hostPane, text: ""), "empty text")
        expectRefused(rowDrag(gpuPane), "a herdr machine's pane on the host")
        expectRefused(rowDrag(gpuTab), "a herdr machine's tab on the host")
        expectRefused(rowDrag(HerdrItemDrag.Item(pane: pane("w1:p4"), on: connB)), "another Machine's pane")
        expectRefused(rowDrag(HerdrItemDrag.Item(pane: pane("w1:p4"), on: connAAgain)), "the same Machine's pane from another connection")
        expectRefused(rowDrag(unsafe), "an ID that could end the paste")
        expectRefused(rowDrag(HerdrItemDrag.Item(pane: pane(String(repeating: "p", count: 65)), on: connA)), "65 characters")
        expectRefused(rowDrag(hostPane, mask: .link), "an operation it doesn't take")
        expectRefused(rowDrag(hostPane, mask: []), "no operation")
        do {
            // Marked, from this process, but no text at all.
            _ = HerdrItemDrag.provider(for: hostPane)
            let pasteboard = ownedPasteboard()
            let item = NSPasteboardItem(); item.setData(Data(), forType: marker)
            precondition(pasteboard.writeObjects([item]))
            expectRefused(OwnedDrag(pasteboard, source: source), "no text")
        }

        // The highlight follows the drag: it leaves, its operation changes,
        // it ends somewhere else.
        targets = []
        let hovering = rowDrag(hostPane)
        check(view.draggingEntered(hovering) == .move && targets == [true], "over the terminal")
        view.draggingExited(hovering)
        check(targets == [true, false], "left it: \(targets)")
        check(view.draggingEntered(hovering) == .move && view.draggingUpdated(rowDrag(hostPane, mask: .link)) == [] && targets == [true, false, true, false], "an operation it doesn't take: \(targets)")
        check(view.draggingUpdated(rowDrag(hostPane)) == .move && targets == [true, false, true, false, true], "and back")
        view.draggingEnded(hovering)
        check(targets == [true, false, true, false, true, false], "ended elsewhere: \(targets)")
        view.draggingExited(nil)
        check(targets.count == 6 && sends.isEmpty && received().isEmpty, "told once, nothing sent")

        // Each server's terminal takes its own rows only.
        view.textDrop = drop(on: connA, machine: "gpu")
        expectPaste(rowDrag(gpuPane), operation: .move, bytes: Array("w1:p1 ".utf8), "gpu pane on gpu")
        expectPaste(rowDrag(gpuTab), operation: .move, bytes: Array("w1:t1 ".utf8), "gpu tab on gpu")
        expectRefused(rowDrag(hostPane), "host pane on gpu")
        expectRefused(rowDrag(cpuPane), "cpu pane on gpu")
        view.textDrop = drop(on: connLocal, machine: nil)
        expectPaste(rowDrag(localPane), operation: .move, bytes: Array("w1:p4 ".utf8), "This Mac's pane on This Mac")
        expectRefused(rowDrag(hostPane), "an SSH host's pane on This Mac")

        // The drop taken away while a drag it takes is over the terminal:
        // the highlight goes, after the update.
        targets = []
        check(view.draggingEntered(rowDrag(localPane)) == .move && targets == [true], "over the terminal again")
        view.textDrop = nil
        check(targets == [true], "not in the middle of the update")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(targets == [true, false], "then the highlight goes: \(targets)")
        check(view.registeredDraggedTypes.isEmpty, "and the marker is no longer registered")
        expectRefused(rowDrag(localPane), "no text drop")

        // File drops as before, beside it.
        var dropped: [[URL]] = []
        let files = [URL(fileURLWithPath: "/owned/a b.png"), URL(fileURLWithPath: "/owned/notes.pdf")]
        func fileDrag(source: AnyObject? = nil) -> OwnedDrag {
            let pasteboard = ownedPasteboard()
            precondition(pasteboard.writeObjects(files.map { $0 as NSURL }))
            return OwnedDrag(pasteboard, source: source, mask: .copy)
        }
        view.onDropFiles = { dropped.append($0) }
        check(view.registeredDraggedTypes == [.fileURL], "file drags only: \(view.registeredDraggedTypes.map(\.rawValue))")
        expectRefused(rowDrag(localPane), "a row with File Drop alone")
        view.textDrop = drop(on: connLocal, machine: nil)
        check(Set(view.registeredDraggedTypes) == [.fileURL, marker], "both: \(view.registeredDraggedTypes.map(\.rawValue))")
        targets = []
        check(view.draggingEntered(fileDrag()) == .copy && view.draggingUpdated(fileDrag()) == .copy, "a file drag is a copy, as before")
        check(view.performDragOperation(fileDrag()) && dropped.count == 1 && dropped[0].map(\.path) == files.map(\.path), "the files, all of them, in order")
        check(targets.isEmpty && sends.isEmpty && received().isEmpty, "no highlight and no bytes for a file drop")
        expectPaste(rowDrag(localPane), operation: .move, bytes: Array("w1:p4 ".utf8), "a row beside File Drop")
        check(dropped.count == 1, "a row is no file drop")
        do {
            // Unmarked text is still no file.
            let pasteboard = ownedPasteboard(); pasteboard.setString("/owned/a.png", forType: .string)
            expectRefused(OwnedDrag(pasteboard, source: source, mask: .copy), "text with File Drop")
        }
        view.textDrop = nil
        check(view.registeredDraggedTypes == [.fileURL], "the text drop gone, file drags stay")
        check(view.performDragOperation(fileDrag()) && dropped.count == 2, "and still drop")
        view.onDropFiles = nil
        check(view.registeredDraggedTypes.isEmpty, "neither: nothing registered")
        check(view.draggingEntered(fileDrag()) == [] && !view.performDragOperation(fileDrag()) && dropped.count == 2, "and nothing taken")
        print("drop target: \(checks)")

        // 4. Through SwiftUI, as PaneTerminalView has it: TerminalHostView's
        // drop reaches the view, taking it away unregisters it, and the
        // highlight over it takes no hits.
        let highlight = Highlight()
        var created: TerminalView?
        var hostSends: [[UInt8]] = []
        var hostTargets: [Bool] = []
        func hosted(_ connection: Machine.ConnectionIdentity?) -> HighlightedTerminal {
            HighlightedTerminal(highlight: highlight, drop: { told in
                connection.map { connection in HerdrItemDrag.terminalDrop(connection: connection, herdrMachineID: nil) { hostTargets.append($0); told($0) } }
            }, onCreate: { created = $0 }, onInput: { hostSends.append(Array($0)) })
        }
        let hosting = NSHostingView(rootView: hosted(connA))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        window.contentView = hosting
        func settle() { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        settle()
        guard let wrapped = created as? FocusReportingTerminalView else { preconditionFailure("the wrapper makes the reporting view") }
        check(wrapped.registeredDraggedTypes == [marker], "TerminalHostView with a text drop: its marker registered")
        let hovered = rowDrag(hostPane)
        check(wrapped.draggingEntered(hovered) == .move && hostTargets == [true], "taken through the wrapper")
        settle()
        check(highlight.shown, "the highlight is up")
        for point in [NSPoint(x: 1, y: 160), NSPoint(x: 320, y: 1), NSPoint(x: 320, y: 160), NSPoint(x: 638, y: 318)] {
            let hit = hosting.hitTest(point)
            check(hit === wrapped || hit?.isDescendant(of: wrapped) == true, "the terminal under the highlight at \(point): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        check(wrapped.performDragOperation(hovered), "dropped through the wrapper")
        settle()
        check(!highlight.shown && hostTargets == [true, false], "the highlight is down: \(hostTargets)")
        check(hostSends == [Array("w1:p4 ".utf8)], "its paste goes out through the wrapper's input: \(hostSends)")
        hosting.rootView = hosted(nil)
        settle()
        check(created === wrapped && wrapped.registeredDraggedTypes.isEmpty, "updated without one: the same view, unregistered")
        check(wrapped.draggingEntered(rowDrag(hostPane)) == [] && !wrapped.performDragOperation(rowDrag(hostPane)) && hostSends.count == 1, "and nothing taken")
        hosting.rootView = hosted(connA)
        settle()
        check(created === wrapped && wrapped.registeredDraggedTypes == [marker], "registered again, the same view")
        check(wrapped.performDragOperation(rowDrag(hostTab)) && hostSends.last == Array("w1:t2 ".utf8), "and it pastes again")

        // What the highlight draws: an accent border, nothing inside it.
        func pixels(_ shown: Bool) -> (edge: NSColor, middle: NSColor) {
            let renderer = ImageRenderer(content: Color.black.frame(width: 120, height: 60).itemDropHighlight(shown))
            renderer.scale = 1
            guard let image = renderer.cgImage else { preconditionFailure("rendered") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            return (bitmap.colorAt(x: 0, y: 30)!.usingColorSpace(.sRGB)!, bitmap.colorAt(x: 60, y: 30)!.usingColorSpace(.sRGB)!)
        }
        func isBlack(_ color: NSColor) -> Bool { color.redComponent < 0.05 && color.greenComponent < 0.05 && color.blueComponent < 0.05 }
        let shown = pixels(true), hidden = pixels(false)
        check(!isBlack(shown.edge) && isBlack(shown.middle), "shown: a border at the edge only (\(shown.edge))")
        check(isBlack(hidden.edge) && isBlack(hidden.middle), "hidden: nothing")
        print("item drop checks: \(checks)")
    }
}
