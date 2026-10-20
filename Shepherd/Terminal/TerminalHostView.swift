import SwiftUI
import SwiftTerm

/// Thin SwiftUI wrapper around SwiftTerm's `TerminalView`. Feeding bytes in
/// is deliberately NOT done through SwiftUI's declarative update cycle —
/// terminal output is a stream, not diffable state — so this just hands the
/// live `TerminalView` instance out once via `onCreate` and lets the caller
/// (`AgentTerminalViewModel`) feed it directly as data arrives.
struct TerminalHostView {
    var onCreate: (TerminalView) -> Void
    var onInput: (ArraySlice<UInt8>) -> Void
    var onResize: (Int, Int) -> Void
    /// Told true when the terminal gets the keyboard, false when it loses it.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Whether the terminal takes the keyboard as soon as it is on screen.
    /// macOS only: on iOS that would also bring the on-screen keyboard up
    /// over it unasked.
    var focusesWhenShown = false
    /// Told a link clicked in the terminal, with how it was clicked.
    var onOpenLink: ((String, TerminalLinkClick) -> Void)? = nil
    /// Told the files dropped from Finder on the terminal. While this is
    /// nil the terminal takes no drops at all, and a drag over it goes back
    /// where it came from, as it always did.
    var onDropFiles: (([URL]) -> Void)? = nil
    /// Text pasted for a drag from inside the app that it marks: a row from
    /// the sidebar (see `HerdrItemDrag`). While this is nil the terminal
    /// takes no such drag.
    var textDrop: TerminalTextDrop? = nil

    final class Coordinator: NSObject, TerminalViewDelegate {
        let onInput: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void
        var onOpenLink: ((String, TerminalLinkClick) -> Void)?

        init(onInput: @escaping (ArraySlice<UInt8>) -> Void, onResize: @escaping (Int, Int) -> Void, onOpenLink: ((String, TerminalLinkClick) -> Void)?) {
            self.onInput = onInput
            self.onResize = onResize
            self.onOpenLink = onOpenLink
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { onOpenLink?(link, .unknown) }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize, onOpenLink: onOpenLink)
    }
}

/// Text pasted into the terminal for a drag from inside the app that is
/// marked with `type`. What the text is, and whether a drag is taken at
/// all, `text` decides; the terminal checks only that the drag is marked
/// and comes from this process, and pastes what `text` gives it with
/// `sendPaste`, without taking the keyboard.
struct TerminalTextDrop {
    /// The pasteboard type that marks the drags this drop may take.
    var type: NSPasteboard.PasteboardType
    /// What to paste for a marked drag whose plain text is the one given,
    /// or nil to refuse it.
    var text: (String) -> String?
    /// Told true when a drag over the terminal would be taken, and false
    /// once it no longer would: it moved on, left, ended or was dropped.
    var onTargetChange: (Bool) -> Void = { _ in }

    /// How a drag is taken: the first of copy, generic and move that its
    /// source allows, or not at all. A list's rows allow only move to a
    /// drag inside the app.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        [NSDragOperation.copy, .generic, .move].first { mask.contains($0) } ?? []
    }
}

/// SwiftTerm's terminal, telling its owner when it gets and loses the
/// keyboard, and able to take it once it is in a window.
///
/// SwiftTerm sets `hasFocus` in its `becomeFirstResponder` and
/// `resignFirstResponder`, which on macOS it doesn't let a subclass
/// override; `hasFocus` it does.
///
/// The owner is told on the next turn of the run loop, not from inside the
/// change: the keyboard also leaves a terminal when SwiftUI takes the
/// terminal's view away in an update — another tab selected, the window
/// closed — and the owner's state must not change in the middle of one.
final class FocusReportingTerminalView: TerminalView {
    var onFocusChange: ((Bool) -> Void)?
    var focusesWhenShown = false
    var onOpenFileGesture: ((String, TerminalLinkClick) -> Void)?
    /// See `TerminalHostView.onDropFiles`. Setting it registers the view
    /// for file drags, or stops it taking them.
    var onDropFiles: (([URL]) -> Void)? {
        didSet { registerDraggedTypes() }
    }
    /// See `TerminalHostView.textDrop`. Setting it registers the view for
    /// the drags it marks, or stops it taking them.
    var textDrop: TerminalTextDrop? {
        didSet {
            registerDraggedTypes()
            // Taken away while a drag it would take is over the terminal —
            // the attach ended: the drag's highlight goes too, once the
            // update that took it away is over.
            if textDrop == nil, textDropTargeted, let oldValue {
                textDropTargeted = false
                DispatchQueue.main.async { oldValue.onTargetChange(false) }
            }
        }
    }
    /// What `textDrop` was last told of the drag over the terminal.
    private var textDropTargeted = false
    private var fileGesture = TerminalFileGesture()
    private var capturedFileHandler: ((String, TerminalLinkClick) -> Void)?
    private(set) var drawGate = TerminalDrawGate()
    /// The press of a plain click on a link in a pane whose program doesn't
    /// take the mouse, until it is released or dragged into a selection.
    private var linkPressForSelection: NSEvent?
    /// Whether a press that SwiftTerm handles is down: a selection being
    /// dragged out may cross cells the program is redrawing.
    private var pressInProgress = false
    /// `allowMouseReporting` as it was before a ⇧ press set it off, until
    /// that press is released.
    private var reportingBeforeShiftPress: Bool?
    /// The selection as `feedKeepingSelection` last left it, with its text.
    private var keptSelection: (start: Position, end: Position, text: String)?
    private var wheelMonitor: Any?
    /// Wheel motion not yet a whole line, as SwiftTerm keeps it.
    private var wheelRemainder: CGFloat = 0

    // While the window can't be seen, SwiftTerm still takes every byte and
    // keeps its screen up to date, but what it asks to redraw is only noted
    // (TerminalDrawGate). The view is never hidden, so it keeps the keyboard.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard drawGate.request() else { return }
        super.setNeedsDisplay(invalidRect)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue, !drawGate.request() { return }
            super.needsDisplay = newValue
        }
    }

    /// Draws the whole terminal once when it becomes visible with redraws
    /// held back.
    func updateDrawing(visible: Bool) {
        if drawGate.update(visible: visible) { super.setNeedsDisplay(bounds) }
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        updateDrawing(visible: TerminalDrawGate.isVisible(inWindow: window != nil,
            occlusionVisible: window?.occlusionState.contains(.visible) == true,
            miniaturized: window?.isMiniaturized == true, applicationHidden: NSApp?.isHidden == true))
    }

    /// Follows the window the view is in now. The center drops these
    /// selector observers by itself when the view goes away.
    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        let windowNames = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        let applicationNames = [NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        for name in windowNames + applicationNames { center.removeObserver(self, name: name, object: nil) }
        if let window {
            for name in windowNames { center.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: window) }
            for name in applicationNames { center.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: nil) }
        }
        windowVisibilityChanged(Notification(name: NSWindow.didChangeOcclusionStateNotification))
    }

    /// Sends `text` to the program as a paste, the way other terminals send
    /// a drop: in one piece, and between the bracketed-paste markers when
    /// the program has asked for them (mode 2004), so that it knows the
    /// text for a paste rather than typing — Claude Code only looks for
    /// image paths in a paste.
    func sendPaste(_ text: String) {
        var bytes = Array(text.utf8)
        if getTerminal().bracketedPasteMode {
            bytes = Self.pasteStart + bytes + Self.pasteEnd
        }
        send(data: bytes[...])
    }

    /// SwiftTerm's `EscapeSequences.bracketedPasteStart`/`End`, which it
    /// declares as mutable statics.
    private static let pasteStart = Array("\u{1b}[200~".utf8)
    private static let pasteEnd = Array("\u{1b}[201~".utf8)

    /// ⌘⌫ goes to the program as Ctrl-U, which deletes back to the start of
    /// the line in a shell and in Claude Code's prompt: what Ghostty
    /// (`super+backspace=text:\x15`) and iTerm2's Natural Text Editing send.
    /// macOS makes the key, with or without Shift, `deleteToBeginningOfLine:`,
    /// which SwiftTerm 1.20.0's `doCommand(by:)` drops, and that method isn't
    /// open to a subclass. Its `keyDown` hands the key here first, with the
    /// kitty keyboard on or off.
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if eventArray.count == 1, let event = eventArray.first,
           event.charactersIgnoringModifiers == "\u{7f}",
           event.modifierFlags.intersection([.control, .option, .command]) == .command {
            send(data: [0x15])
            return
        }
        super.interpretKeyEvents(eventArray)
    }

    /// ⌘← and ⌘→ go to the program as the Home and End keys while it has the
    /// kitty keyboard protocol on, as Pi does. SwiftTerm 1.20.0 sends them
    /// then as super+← and super+→ (`CSI 1;9D`, `CSI 1;9C`), which Pi binds
    /// to nothing; Claude Code and Codex bind them to what they bind Home
    /// and End to. With the kitty keyboard off they stay SwiftTerm's: macOS
    /// makes them `moveToLeftEndOfLine:` and `moveToRightEndOfLine:`, which
    /// SwiftTerm sends as `ESC b` and `ESC f`. With it on SwiftTerm encodes
    /// an arrow before `interpretKeyEvents`, and its `keyDown` isn't open to
    /// a subclass, but AppKit offers a ⌘ key-down here before `keyDown`. The
    /// key goes on through SwiftTerm's own `keyDown` as Home or End, so it is
    /// encoded for the mode the program asked for, with auto-repeat and Caps
    /// Lock as a real Home or End key would have them. Only the terminal
    /// with the keyboard takes it, and ⇧, ⌃ or ⌥ with ⌘ leaves it alone.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              !getTerminal().keyboardEnhancementFlags.isEmpty,
              event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command,
              let key = Self.homeOrEnd(for: event)
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: key)
        return true
    }

    /// The Home or End key-down standing in for a ⌘← or ⌘→ one.
    private static func homeOrEnd(for event: NSEvent) -> NSEvent? {
        let keyCode: UInt16, character: String
        switch event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
        case NSLeftArrowFunctionKey: (keyCode, character) = (115, "\u{f729}") // kVK_Home, NSHomeFunctionKey
        case NSRightArrowFunctionKey: (keyCode, character) = (119, "\u{f72b}") // kVK_End, NSEndFunctionKey
        default: return nil
        }
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.intersection(.capsLock).union(.function),
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: event.isARepeat, keyCode: keyCode)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setTextDropTargeted(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setTextDropTargeted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isMarkedForTextDrop(sender) {
            setTextDropTargeted(false)
            guard let text = droppedText(in: sender) else { return false }
            sendPaste(text)
            return true
        }
        let urls = droppedFiles(in: sender)
        guard let onDropFiles, !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        if isMarkedForTextDrop(sender) {
            let operation = droppedText(in: sender) == nil ? [] : TerminalTextDrop.operation(for: sender.draggingSourceOperationMask)
            setTextDropTargeted(!operation.isEmpty)
            return operation
        }
        return onDropFiles != nil && !droppedFiles(in: sender).isEmpty ? .copy : []
    }

    private func droppedFiles(in sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Whether the drag carries `textDrop`'s mark. Such a drag is the text
    /// drop's to take or refuse, never a file drop.
    private func isMarkedForTextDrop(_ sender: any NSDraggingInfo) -> Bool {
        guard let textDrop else { return false }
        return sender.draggingPasteboard.types?.contains(textDrop.type) == true
    }

    /// What `textDrop` pastes for a marked drag, or nil: only for one from
    /// this process (another app's has no `draggingSource` here), with an
    /// operation its source allows, and plain text that `textDrop` takes.
    private func droppedText(in sender: any NSDraggingInfo) -> String? {
        guard let textDrop, sender.draggingSource != nil,
              !TerminalTextDrop.operation(for: sender.draggingSourceOperationMask).isEmpty,
              let text = sender.draggingPasteboard.string(forType: .string) else { return nil }
        return textDrop.text(text)
    }

    private func setTextDropTargeted(_ targeted: Bool) {
        guard targeted != textDropTargeted else { return }
        textDropTargeted = targeted
        textDrop?.onTargetChange(targeted)
    }

    /// Registers the view for the drags it takes, and only those: file
    /// drags while `onDropFiles` is set, and the drags `textDrop` marks
    /// while it is.
    private func registerDraggedTypes() {
        var types: [NSPasteboard.PasteboardType] = []
        if onDropFiles != nil { types.append(.fileURL) }
        if let textDrop { types.append(textDrop.type) }
        guard Set(registeredDraggedTypes) != Set(types) else { return }
        unregisterDraggedTypes()
        if !types.isEmpty { registerForDraggedTypes(types) }
    }

    /// Feeds the program's output to SwiftTerm, keeping the selection.
    ///
    /// SwiftTerm drops the selection at every byte of output while
    /// `allowMouseReporting` is on, which it stays so that a program that
    /// asks for the mouse gets it; and herdr sends the pane's screen many
    /// times a second while an agent works. So the selection is put back on
    /// the same cells after each piece of output, unless
    /// - the text in those cells changed: herdr draws the pane on the
    ///   alternate screen cell by cell, so output that scrolls lands in the
    ///   same cells, and the selection can't follow it. Not while the
    ///   selection is still being dragged out;
    /// - the program went over to the alternate screen or back.
    ///
    /// A key, a press that doesn't select (`mouseDown`) and a change of size
    /// still end it, as SwiftTerm has them.
    func feedKeepingSelection(_ bytes: ArraySlice<UInt8>) {
        guard let selection, selection.active else {
            keptSelection = nil
            feed(byteArray: bytes)
            return
        }
        let (start, end) = (selection.start, selection.end)
        // The text read after the last output, while the selection hasn't
        // moved since; only the output changes what is in its cells.
        let text = keptSelection.flatMap { $0.start == start && $0.end == end ? $0.text : nil } ?? selection.getSelectedText()
        let alternate = getTerminal().isCurrentBufferAlternate
        feed(byteArray: bytes)
        guard getTerminal().isCurrentBufferAlternate == alternate else {
            keptSelection = nil
            selectNone()
            return
        }
        if !selection.active { selection.setSelection(start: start, end: end) }
        let now = selection.getSelectedText()
        if now != text, !pressInProgress {
            keptSelection = nil
            selectNone()
            return
        }
        keptSelection = (selection.start, selection.end, now)
    }

    /// Sends the wheel over this terminal to herdr as a mouse report, the
    /// one SwiftTerm sends while mouse reporting is on, when it is off and
    /// the alternate screen is up: that is where herdr draws the pane, and
    /// where SwiftTerm would otherwise send ↑ and ↓ for the wheel, which a
    /// shell and Claude Code take as going through their history. The
    /// attach, which no longer turns mouse reporting on (see
    /// `HerdrExecutable.attachConfiguration`), still scrolls herdr's
    /// scrollback for the report, as it did. Lines are counted as SwiftTerm
    /// counts them. Returns whether the event was taken; SwiftTerm's own
    /// `scrollWheel` isn't open to a subclass, so this is called from a
    /// local event monitor, before the event reaches it.
    ///
    /// While a ⇧ press is down, which turns `allowMouseReporting` off only
    /// to keep its selection, the wheel goes where it went with it on: to
    /// herdr as above, or to a program with mouse reporting on as SwiftTerm
    /// reports it, rather than as ↑ and ↓.
    ///
    /// Left to SwiftTerm: the wheel elsewhere, or over something drawn over
    /// the terminal; the program having mouse reporting on, outside a ⇧
    /// press; the normal screen, with its own scrollback; and ⇧, which
    /// SwiftTerm keeps from the program unless it asked for it.
    func reportWheel(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        let terminal = getTerminal()
        let flags = event.modifierFlags
        let toHerdr = terminal.mouseMode == .off && terminal.isCurrentBufferAlternate
        let toProgram = terminal.mouseMode != .off && reportingBeforeShiftPress != nil
        guard toHerdr || toProgram, reportingBeforeShiftPress ?? allowMouseReporting,
              !(flags.contains(.shift) && !terminal.mouseShiftCapture), event.scrollingDeltaY != 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let root = window.contentView?.superview ?? window.contentView
        guard bounds.contains(point), let root,
              let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
              hit === self || hit.isDescendant(of: self) else { return false }
        let scale = window.backingScaleFactor
        guard let pixels = cellSizeInPixels(source: terminal), pixels.width > 0, scale > 0 else { return false }
        let cell = CGSize(width: CGFloat(pixels.width) / scale, height: caretFrame.height)
        guard cell.height > 0 else { return false }
        // SwiftTerm's `scrollWheel`: a trackpad's points add up to lines, a
        // wheel's notch is at least one.
        let delta = event.scrollingDeltaY * scrollSensitivity
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            wheelRemainder += delta
            lines = Int(wheelRemainder / cell.height)
            wheelRemainder -= CGFloat(lines) * cell.height
        } else {
            wheelRemainder = 0
            let rounded = Int(delta.rounded())
            lines = rounded != 0 ? rounded : (event.scrollingDeltaY > 0 ? 1 : -1)
        }
        guard lines != 0 else { return true }
        let column = min(max(0, Int(point.x / cell.width)), terminal.cols - 1)
        let row = min(max(0, Int((bounds.height - point.y) / cell.height)), terminal.rows - 1)
        if toProgram {
            let button = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false, shift: flags.contains(.shift),
                                               meta: flags.contains(.option), control: flags.contains(.control))
            let pixelX = Int(min(max(point.x, 0), bounds.width)), pixelY = Int(bounds.height - min(max(point.y, 0), bounds.height))
            for _ in 0..<abs(lines) { terminal.sendEvent(buttonFlags: button, x: column, y: row, pixelX: pixelX, pixelY: pixelY) }
            return true
        }
        var button = lines > 0 ? 64 : 65
        if flags.contains(.shift) { button |= 4 }
        if flags.contains(.option) { button |= 8 }
        if flags.contains(.control) { button |= 16 }
        let report = Array("\u{1b}[<\(button);\(column + 1);\(row + 1)M".utf8)
        for _ in 0..<abs(lines) { send(data: report[...]) }
        return true
    }

    /// Listens for the wheel while the view is in a window (`reportWheel`).
    private func followWheel() {
        if window == nil {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        } else if wheelMonitor == nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.reportWheel(event) == true } ? nil : event
            }
        }
    }

    /// Whether a local event monitor is listening for the wheel.
    var followsWheel: Bool { wheelMonitor != nil }

    /// Ends a ⇧ press that set mouse reporting off, putting it back.
    private func endShiftPress() {
        guard let reporting = reportingBeforeShiftPress else { return }
        reportingBeforeShiftPress = nil
        allowMouseReporting = reporting
    }

    override func mouseDown(with event: NSEvent) {
        // A release that never came (the view left its window mid-press).
        endShiftPress()
        fileGesture.cancel()
        capturedFileHandler = nil
        linkPressForSelection = nil
        pressInProgress = false
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        // ⇧ selects, as in other terminals: SwiftTerm's own selection, on a
        // link too, decided at the press for the whole drag, and with mouse
        // reporting off until the release, so that output arriving
        // meanwhile doesn't drop it. Unless the program has asked for ⇧
        // presses (XTSHIFTESCAPE), which then go to it as before.
        if modifiers == .shift, !getTerminal().mouseShiftCapture {
            reportingBeforeShiftPress = allowMouseReporting
            allowMouseReporting = false
            pressInProgress = true
            super.mouseDown(with: event)
            return
        }
        // Any other press ends the selection, as a click does in any
        // terminal, and goes where it went before.
        if selection?.active == true { selectNone() }
        // The second and third press of a double or triple click on a link
        // are claimed too, and open nothing (see `TerminalFileGesture`).
        let link = TerminalFileHit.link(in: self, point: point)
        if fileGesture.begin(link: link, at: point, clickCount: event.clickCount) {
            capturedFileHandler = onOpenFileGesture // owner at press, not release
            // A plain drag from a link selects, where the program doesn't
            // take the mouse (see `mouseDragged`).
            if link != nil, modifiers.isEmpty, event.clickCount <= 1, getTerminal().mouseMode == .off {
                linkPressForSelection = event
            }
            return // no remote press, including explicit OSC8/file URI targets
        }
        pressInProgress = true
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if fileGesture.ownsPointer {
            fileGesture.move(to: convert(event.locationInWindow, from: nil))
            // A plain drag from a link that has gone far enough not to open
            // it (`TerminalFileGesture`) selects from where it was pressed,
            // while the program still doesn't take the mouse. The link
            // opens nothing.
            if let press = linkPressForSelection, fileGesture.dragged, getTerminal().mouseMode == .off {
                linkPressForSelection = nil
                fileGesture.cancel()
                capturedFileHandler = nil
                pressInProgress = true
                super.mouseDown(with: press)
                if let first = NSEvent.mouseEvent(with: .leftMouseDragged, location: press.locationInWindow,
                    modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                    context: nil, eventNumber: event.eventNumber, clickCount: press.clickCount, pressure: event.pressure) {
                    super.mouseDragged(with: first)
                }
                super.mouseDragged(with: event)
            }
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        linkPressForSelection = nil
        pressInProgress = false
        defer { endShiftPress() }
        if fileGesture.ownsPointer {
            let handler = capturedFileHandler
            capturedFileHandler = nil
            if let link = fileGesture.end(at: convert(event.locationInWindow, from: nil)) {
                // ⌘ is read at release, like the link: it is the one
                // modifier the xterm mouse protocol doesn't carry to the
                // program, so the claimed click is the only thing it means
                // anything to (see `LinkDestinationPolicy`).
                handler?(link, TerminalLinkClick(commandHeld: event.modifierFlags.contains(.command)))
            }
            return // failure/drag never replays this gesture to the remote TUI
        }
        // An unclaimed NON-file click belongs to the TUI, not BOTH the TUI
        // on press and Shepherd on release. Keep reporting/selection enabled.
        // linkReporting controls hover discovery, NOT OSC8 activation in
        // SwiftTerm. Gate activation explicitly for this one release. The
        // Command is not an SGR mouse modifier; recognized file links above
        // are already claimed regardless of the modifier.
        let release: NSEvent
        if event.modifierFlags.contains(.command) {
            guard let copy = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: event.modifierFlags.subtracting(.command), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                clickCount: event.clickCount, pressure: event.pressure) else { return }
            release = copy
        } else { release = event }
        let highlighting = linkHighlightMode
        linkHighlightMode = .alwaysWithModifier
        defer { linkHighlightMode = highlighting }
        super.mouseUp(with: release)
    }

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            guard let onFocusChange else { return }
            DispatchQueue.main.async { onFocusChange(newValue) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowVisibility()
        followWheel()
        endShiftPress()
        pressInProgress = false
        linkPressForSelection = nil
        guard focusesWhenShown, window != nil else { return }
        focusesWhenShown = false
        // On the next turn of the run loop: the view lands in its window in
        // the middle of SwiftUI's update, and the window's own handling of
        // that update could still move the keyboard on after this.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Whether a terminal draws what it is asked to redraw. A window that can't
/// be seen — covered, on another Space, minimized, or its app hidden — gets
/// no drawing; its redraw requests are remembered, and the first time it can
/// be seen again the whole terminal is drawn once.
nonisolated struct TerminalDrawGate: Equatable {
    private(set) var visible = true
    private(set) var pending = false

    /// Outside a window AppKit draws nothing anyway; it then draws what the
    /// view marked when the view lands in one.
    static func isVisible(inWindow: Bool, occlusionVisible: Bool, miniaturized: Bool, applicationHidden: Bool) -> Bool {
        !inWindow || (occlusionVisible && !miniaturized && !applicationHidden)
    }

    /// Whether a redraw request goes through now.
    mutating func request() -> Bool {
        if visible { return true }
        pending = true
        return false
    }

    /// Whether to redraw the whole terminal now.
    mutating func update(visible: Bool) -> Bool {
        self.visible = visible
        guard visible, pending else { return false }
        pending = false
        return true
    }
}

extension TerminalHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        let view = FocusReportingTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.onFocusChange = onFocusChange
        view.focusesWhenShown = focusesWhenShown
        view.onOpenFileGesture = onOpenLink
        view.onDropFiles = onDropFiles
        view.textDrop = textDrop
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        (nsView as? FocusReportingTerminalView)?.onOpenFileGesture = onOpenLink
        (nsView as? FocusReportingTerminalView)?.onDropFiles = onDropFiles
        (nsView as? FocusReportingTerminalView)?.textDrop = textDrop
    }
}

#Preview {
    TerminalHostView(
        onCreate: { view in
            view.feed(text: "hrdrhrdrhrdr\r\n$ echo hello\r\nhello\r\n$ ")
        },
        onInput: { _ in },
        onResize: { _, _ in }
    )
    .frame(minWidth: 320, minHeight: 240)
}
