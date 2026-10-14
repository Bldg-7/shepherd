import AppKit
import SwiftUI
import SwiftTerm
import Darwin

/// A drag as AppKit hands it to a destination, over an owned, uniquely named
/// pasteboard: not the user's, and released at the end.
final class OwnedDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
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

// The actual terminal view and its SwiftUI wrapper with pinned SwiftTerm, in
// an owned never-shown window, bytes checked through an owned kernel PTY.
@main @MainActor enum DropViewTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: String) { precondition(condition, why); checks += 1 }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
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

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FocusReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = view
        var sends: [[UInt8]] = []
        let coordinator = TerminalHostView.Coordinator(onInput: { bytes in
            sends.append(Array(bytes))
            Array(bytes).withUnsafeBytes { precondition(Darwin.write(master, $0.baseAddress, $0.count) == $0.count) }
        }, onResize: { _, _ in }, onOpenLink: nil)
        view.terminalDelegate = coordinator

        // Registration follows the handler.
        check(view.registeredDraggedTypes.isEmpty, "no handler, no drags taken")
        var dropped: [[URL]] = []
        view.onDropFiles = { dropped.append($0) }
        check(view.registeredDraggedTypes.contains(.fileURL), "a handler registers for file drags")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shepherd-file-drop-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/owned/a b.png"), URL(fileURLWithPath: "/owned/notes.pdf")]
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects(files.map { $0 as NSURL }))
        let drag = OwnedDrag(pasteboard)
        check(view.draggingEntered(drag) == .copy && view.draggingUpdated(drag) == .copy, "a file drag is taken as a copy")
        check(view.performDragOperation(drag) && dropped.count == 1 && dropped[0].map(\.path) == files.map(\.path), "the dropped files, all of them, in order")
        check(sends.isEmpty && received().isEmpty, "a drop by itself sends nothing to the program")

        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([NSURL(string: "https://example.invalid/a.png")!]))
        check(view.draggingEntered(OwnedDrag(pasteboard)) == [] && !view.performDragOperation(OwnedDrag(pasteboard)), "a web link isn't a file")
        pasteboard.clearContents()
        pasteboard.setString("/owned/a.png", forType: .string)
        check(view.draggingEntered(OwnedDrag(pasteboard)) == [] && !view.performDragOperation(OwnedDrag(pasteboard)), "text isn't a file")
        check(dropped.count == 1, "neither was handed on")

        view.onDropFiles = nil
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects(files.map { $0 as NSURL }))
        check(view.registeredDraggedTypes.isEmpty, "no handler again, registration gone")
        check(view.draggingEntered(drag) == [] && !view.performDragOperation(drag) && dropped.count == 1, "and nothing taken")

        // The paste: one send, between the markers once the program asks.
        let text = #"/owned/a\ b.png "#
        view.feed(text: "\u{1b}[?2004h")
        view.sendPaste(text)
        let bracketed = [27, 91, 50, 48, 48, 126] + Array(text.utf8) + [27, 91, 50, 48, 49, 126]
        check(sends == [bracketed], "one send, bracketed: \(sends)")
        check(received() == bracketed, "the bytes reach the PTY unchanged")
        sends = []
        view.feed(text: "\u{1b}[?2004l")
        view.sendPaste(text)
        check(sends == [Array(text.utf8)] && received() == Array(text.utf8), "plain text when the program hasn't asked for bracketed paste")

        // Through SwiftUI: TerminalHostView's handler reaches the view, and
        // taking it away unregisters it.
        sends = []
        var created: TerminalView?
        func host(_ handler: (([URL]) -> Void)?) -> TerminalHostView {
            TerminalHostView(onCreate: { created = $0 }, onInput: { sends.append(Array($0)) }, onResize: { _, _ in }, onDropFiles: handler)
        }
        let hosting = NSHostingView(rootView: host({ dropped.append($0) }))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        window.contentView = hosting
        func settle() { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        settle()
        guard let wrapped = created as? FocusReportingTerminalView else { preconditionFailure("the wrapper makes the reporting view") }
        check(wrapped.registeredDraggedTypes.contains(.fileURL), "TerminalHostView with a handler: registered")
        check(wrapped.performDragOperation(drag) && dropped.count == 2, "and its handler gets the drop")
        hosting.rootView = host(nil)
        settle()
        check(wrapped.registeredDraggedTypes.isEmpty && !wrapped.performDragOperation(drag) && dropped.count == 2, "updated without one: unregistered")
        hosting.rootView = host({ dropped.append($0) })
        settle()
        check(wrapped.registeredDraggedTypes.contains(.fileURL), "and registered again, the same view")
        wrapped.feed(text: "\u{1b}[?2004h")
        wrapped.sendPaste("x ")
        check(sends == [[27, 91, 50, 48, 48, 126, 120, 32, 27, 91, 50, 48, 49, 126]], "its paste goes out through the wrapper's input")
        print("drop view checks: \(checks)")
    }
}
