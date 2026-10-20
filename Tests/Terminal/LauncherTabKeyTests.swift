import SwiftUI
import AppKit

// The new tab launcher itself (NewTabLauncher.swift, compiled whole by the
// runner) in owned windows that are never shown, its keys pressed as AppKit
// delivers a key-down: offered to the window as a key equivalent first, then
// to the first responder, the launcher's field editor. Nothing here orders a
// window front or makes one key; the field takes the keyboard by
// makeFirstResponder, as it does in the app.

@MainActor final class LauncherProbe {
    var requests: [LaunchRequest] = []
    var closes = 0
    /// Holds a Return on the tab name in `create` until it is let go.
    var holdsReturn = false
    var pending: CheckedContinuation<Void, Never>?
}

@main @MainActor enum LauncherTabKeyTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func drain(_ turns: Int = 20) {
        for _ in 0..<turns { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func first<T: NSView>(_ type: T.Type, in view: NSView, where test: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, test(match) { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview, where: test) { return match }
        }
        return nil
    }

    struct Launcher {
        let window: NSWindow
        let field: NSTextField
        let editor: NSTextView
        let probe: LauncherProbe
        /// The Launch picker, when the launcher shows one now.
        var picker: NSSegmentedControl? { first(NSSegmentedControl.self, in: window.contentView!) }
        var keepsKeyboard: Bool { window.firstResponder === editor && field.currentEditor() === editor }
    }

    static func open(_ targets: [LaunchTarget], preset: LaunchPreset?, allowsBrowserAgents: Bool) -> Launcher {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let probe = LauncherProbe()
        let launcher = NewTabLauncher(targets: targets, preset: preset, allowsBrowserAgents: allowsBrowserAgents, create: { @MainActor request, _ in
            probe.requests.append(request)
            if probe.holdsReturn { await withCheckedContinuation { probe.pending = $0 } }
        }, onClose: { probe.closes += 1 })
        window.contentView = NSHostingView(rootView: launcher)
        drain()
        guard let field = first(NSTextField.self, in: window.contentView!, where: { $0.delegate is LauncherField.Coordinator }),
              let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else {
            preconditionFailure("the launcher's field takes the keyboard once it is in its window")
        }
        return Launcher(window: window, field: field, editor: editor, probe: probe)
    }

    /// One key-down in AppKit's order. Whether a key equivalent took it.
    @discardableResult
    static func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [], in launcher: Launcher) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: launcher.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        defer { drain() }
        if launcher.window.performKeyEquivalent(with: event) { return true }
        launcher.window.firstResponder?.keyDown(with: event)
        return false
    }
    static func tab(_ launcher: Launcher) { check(!press("\t", code: 48, in: launcher), "Tab is no key equivalent") }
    static func backtab(_ launcher: Launcher) { check(!press("\u{19}", code: 48, .shift, in: launcher), "⇧Tab is no key equivalent") }
    static func returnKey(_ launcher: Launcher) { press("\r", code: 36, in: launcher) }
    static func down(_ launcher: Launcher) { press("\u{f701}", code: 125, [.numericPad, .function], in: launcher) }
    static func backspace(_ launcher: Launcher) { press("\u{7f}", code: 51, in: launcher) }

    /// Whether the launcher's field delegate takes Tab and ⇧Tab rather than
    /// leaving them to AppKit.
    static func takesTabs(_ launcher: Launcher) -> (tab: Bool, backtab: Bool) {
        let delegate = launcher.field.delegate
        return (delegate?.control?(launcher.field, textView: launcher.editor, doCommandBy: #selector(NSResponder.insertTab(_:))) ?? false,
                delegate?.control?(launcher.field, textView: launcher.editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))) ?? false)
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // The rule: round the picker's programs, both ways.
        let all = LaunchProgram.launchableCases
        check(all == [.shell, .claude, .codex, .pi], "the Launch picker's programs, in order: \(all)")
        check(all.map { $0.cycled() } == [.claude, .codex, .pi, .shell], "Tab: the next one, from Pi round to Shell")
        check(all.map { $0.cycled(backward: true) } == [.pi, .shell, .claude, .codex], "⇧Tab: the previous one, from Shell round to Pi")
        let some: [LaunchProgram] = [.shell, .codex]
        check(LaunchProgram.shell.cycled(among: some) == .codex && LaunchProgram.codex.cycled(among: some) == .shell, "a program not offered is skipped")
        check(LaunchProgram.claude.cycled(among: some) == .shell && LaunchProgram.claude.cycled(backward: true, among: some) == .codex, "from one not offered: the first, or the last")
        check(LaunchProgram.pi.cycled(among: [.pi]) == .pi && LaunchProgram.pi.cycled(among: []) == .pi, "one choice or none: it stays")

        let nowhere = NSRange(location: NSNotFound, length: 0)
        func workspace(_ id: String, _ label: String) -> LaunchWorkspace {
            LaunchWorkspace(workspace: WorkspaceSummary(json: .object(["workspace_id": .string(id), "label": .string(label)]))!, tabCount: 1)
        }
        let host = LaunchTarget(herdrMachine: nil, label: "This Mac", workspaces: [workspace("w1", "Host A")], unavailableReason: nil)
        let machine = HerdrMachine(id: "other", label: "Other", target: "never-connect", session: "default", enabled: true)
        let remote = LaunchTarget(herdrMachine: machine, label: "Other", workspaces: [workspace("w1", "Nested A")], unavailableReason: nil)
        let onHost = LaunchPreset(targetID: host.id, workspace: host.workspaces[0].workspace)

        // The tab's name on the host's herdr, with browser agents allowed.
        let a = open([host], preset: onHost, allowsBrowserAgents: true)
        guard let picker = a.picker else { preconditionFailure("the Tab Name step shows the Launch picker") }
        let labels = (0..<picker.segmentCount).map { picker.label(forSegment: $0) ?? "" }
        check(labels == ["Shell", "Claude Code", "Codex", "Pi"] && picker.selectedSegment == 0 && picker.isEnabled, "Shell picked, the picker enabled: \(labels) \(picker.selectedSegment)")
        a.editor.insertText("ab", replacementRange: nowhere)
        drain()
        a.editor.setSelectedRange(NSRange(location: 1, length: 0))
        for expected in [1, 2, 3, 0] {
            tab(a)
            check(a.keepsKeyboard, "Tab leaves the keyboard in the field")
            check(a.field.stringValue == "ab" && a.editor.string == "ab", "Tab leaves the text: \(a.field.stringValue)")
            check(a.editor.selectedRange() == NSRange(location: 1, length: 0), "Tab leaves the insertion point: \(a.editor.selectedRange())")
            check(a.picker?.selectedSegment == expected, "Tab picks segment \(expected): \(a.picker?.selectedSegment ?? -1)")
        }
        for expected in [3, 2] {
            backtab(a)
            check(a.keepsKeyboard && a.field.stringValue == "ab" && a.editor.selectedRange() == NSRange(location: 1, length: 0), "⇧Tab leaves the keyboard, the text and the insertion point")
            check(a.picker?.selectedSegment == expected, "⇧Tab picks segment \(expected): \(a.picker?.selectedSegment ?? -1)")
        }
        a.editor.setSelectedRange(NSRange(location: 0, length: 2))
        tab(a)
        check(a.keepsKeyboard && a.editor.selectedRange() == NSRange(location: 0, length: 2) && a.picker?.selectedSegment == 3, "Tab leaves selected text selected")

        // A syllable being composed stays as it is, and so does the field.
        a.editor.setSelectedRange(NSRange(location: 2, length: 0))
        a.editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: nowhere)
        drain()
        tab(a)
        check(a.keepsKeyboard && a.editor.hasMarkedText() && a.field.stringValue == "ab하" && a.picker?.selectedSegment == 0, "Tab while composing: Pi round to Shell, the syllable still being composed: \(a.field.stringValue)")
        tab(a)
        check(a.keepsKeyboard && a.editor.hasMarkedText() && a.field.stringValue == "ab하" && a.picker?.selectedSegment == 1, "and on to Claude Code")
        a.editor.insertText("한", replacementRange: nowhere)
        drain()
        check(!a.editor.hasMarkedText() && a.field.stringValue == "ab한", "the syllable committed afterwards: \(a.field.stringValue)")

        // Return asks for the program Tab picked; while that is pending the
        // picker can't be changed, and Tab changes nothing.
        a.probe.holdsReturn = true
        returnKey(a)
        check(a.probe.requests.count == 1 && a.probe.requests[0].program == .claude && a.probe.requests[0].tabName == "ab한", "Return opens the tab with the program picked by Tab")
        check(a.picker?.isEnabled == false, "the picker is disabled while the tab is being made")
        tab(a)
        check(a.keepsKeyboard && a.picker?.selectedSegment == 1 && a.probe.requests.count == 1, "Tab while the tab is being made: nothing changes, the keyboard stays")
        a.probe.pending?.resume()
        drain()
        check(a.probe.closes == 1, "the launcher closes once the tab is made")
        a.window.close()

        // A herdr machine: the picker is shown disabled, and only a shell can
        // be opened. Tab changes nothing and keeps the keyboard.
        let b = open([host, remote], preset: LaunchPreset(targetID: remote.id, workspace: remote.workspaces[0].workspace), allowsBrowserAgents: true)
        check(b.picker?.isEnabled == false && b.picker?.selectedSegment == 0, "the picker is disabled on a herdr machine")
        b.editor.insertText("cd", replacementRange: nowhere)
        drain()
        tab(b)
        backtab(b)
        check(b.keepsKeyboard && b.field.stringValue == "cd" && b.picker?.selectedSegment == 0, "Tab and ⇧Tab on a herdr machine: nothing changes, the keyboard stays")
        returnKey(b)
        check(b.probe.requests.map(\.program) == [.shell], "a herdr machine's tab is a shell")
        b.window.close()

        // Browser agents not allowed: no picker. Tab changes nothing and
        // keeps the keyboard.
        let c = open([host], preset: onHost, allowsBrowserAgents: false)
        check(c.picker == nil, "no picker without browser agents")
        c.editor.insertText("ef", replacementRange: nowhere)
        drain()
        tab(c)
        backtab(c)
        check(c.keepsKeyboard && c.field.stringValue == "ef", "Tab and ⇧Tab without the picker: nothing changes, the keyboard stays")
        returnKey(c)
        check(c.probe.requests.map(\.program) == [.shell], "without browser agents the tab is a shell")
        c.window.close()

        // The other steps leave Tab and ⇧Tab to AppKit, as before; the Tab
        // Name step reached through them takes them.
        let d = open([host, remote], preset: nil, allowsBrowserAgents: true)
        check(d.picker == nil && takesTabs(d) == (false, false), "the Machine step leaves Tab and ⇧Tab to AppKit")
        returnKey(d)
        check(d.picker == nil && takesTabs(d) == (false, false), "the Workspace step leaves Tab and ⇧Tab to AppKit")
        down(d)
        returnKey(d)
        check(d.picker == nil && takesTabs(d) == (false, false), "the new workspace's name leaves Tab and ⇧Tab to AppKit")
        returnKey(d)
        check(d.picker?.selectedSegment == 0 && takesTabs(d) == (true, true), "the Tab Name step takes Tab and ⇧Tab")
        tab(d)
        tab(d)
        check(d.keepsKeyboard && d.picker?.selectedSegment == 2, "Tab on the tab's name of a new workspace: Codex")
        backspace(d)
        check(d.picker == nil && takesTabs(d) == (false, false), "Backspace back to the Workspace step: Tab and ⇧Tab are AppKit's again")
        returnKey(d)
        check(d.picker?.selectedSegment == 2, "back on the Tab Name step, the program picked is kept")
        d.window.close()

        print("PASS \(checks) launcher Tab checks: the rule round the picker both ways, Tab and ⇧Tab key-downs on the Tab Name step keeping the keyboard, the text, the insertion point and a composition, Return taking the program picked, a pending Return, a herdr machine, no picker, the other steps left to AppKit; the whole launcher in never-shown owned windows, no input method or app")
    }
}
