import SwiftUI
import AppKit

// Runtime launch/authentication is not exercised by typing a name.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

/// Stands in for `ContentView`: shows the production field for the session
/// it holds, and ends a session the way `endTitleRename` does — the first
/// ending counts. A board refresh is `refresh` going up: the field's parent
/// is evaluated again, as every snapshot does to `ContentView`.
@MainActor @Observable final class FieldProbe {
    var session: TitleRenameSession?
    var refresh = 0
    @ObservationIgnored var calls: [(id: UUID, ending: TitleRenameEnding)] = []
    @ObservationIgnored var endings: [(id: UUID, ending: TitleRenameEnding, text: String)] = []
    @ObservationIgnored var refusals = 0

    func end(_ session: TitleRenameSession, _ ending: TitleRenameEnding) {
        calls.append((session.id, ending))
        guard session.end() else { return }
        endings.append((session.id, ending, session.text))
        if self.session === session { self.session = nil }
    }
}

/// Another field, to have the keyboard before the rename and after it.
struct OtherField: NSViewRepresentable {
    let onMake: (NSTextField) -> Void
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "other")
        onMake(field)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {}
}

struct Host: View {
    let probe: FieldProbe
    let onOther: (NSTextField) -> Void
    var body: some View {
        VStack {
            Text(verbatim: "refresh \(probe.refresh)")
            if let session = probe.session {
                TitleRenameField(
                    session: session,
                    canSubmit: { TitleRename.canSubmit($0, for: session.item) },
                    onEnd: probe.end,
                    refuse: { probe.refusals += 1 }
                )
                .id(session.id)
                .frame(width: 280)
            }
            OtherField(onMake: onOther)
        }
        .frame(width: 400, height: 160)
    }
}

/// The production field in an owned window that is never shown: what it
/// takes the keyboard from and gives it back to, Return and Escape with and
/// without a composition going on, the keyboard going elsewhere, the field
/// going away, and board refreshes in the middle of a composition.
@main @MainActor enum TitleRenameFieldTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func spin(until condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(condition(), message)
    }

    static func spin(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    static func fields(in view: NSView) -> [TitleRenameTextField] {
        ((view as? TitleRenameTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields(in:))
    }

    static func pane(_ label: String?) -> AgentSummary {
        var json: [String: JSONValue] = ["pane_id": .string("w1:p1"), "tab_id": .string("w1:t1"), "terminal_id": .string("terminal-1"),
                                         "terminal_title_stripped": .string("zsh")]
        if let label { json["label"] = .string(label) }
        return AgentSummary(json: .object(json), on: nil)!
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let probe = FieldProbe()
        var other: NSTextField?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(probe: probe, onOther: { other = $0 }))
        spin(until: { other?.window === window }, "the other field is in the never-shown window")
        let otherField = other!
        func editor() -> NSTextView? { window.firstResponder as? NSTextView }
        func editing(_ field: NSTextField) -> Bool { editor()?.isFieldEditor == true && editor()?.delegate === field }
        check(window.makeFirstResponder(otherField) && editing(otherField), "the other field has the keyboard first")

        func begin(_ item: BoardItem) -> (TitleRenameSession, TitleRenameTextField, NSTextView) {
            let session = TitleRenameSession(item: item)
            probe.session = session
            spin(until: { fields(in: window.contentView!).count == 1 && editing(fields(in: window.contentView!)[0]) },
                 "the field takes the keyboard once it is in the window")
            return (session, fields(in: window.contentView!)[0], editor()!)
        }
        let none = NSRange(location: NSNotFound, length: 0)

        // Return, after a composition the input method has committed.
        do {
            let (session, field, text) = begin(.pane(pane("build")))
            check(session.keyboardBefore === otherField, "what had the keyboard before is remembered — the field, not its editor")
            check(text.string == "build" && text.selectedRange() == NSRange(location: 0, length: 5), "starts with the name, all of it selected")
            check(field.placeholderString == "zsh" && field.toolTip != nil, "the pane's title as the prompt, and how to take its name away")
            text.insertText("server", replacementRange: none)
            check(session.text == "server" && probe.calls.isEmpty, "typing is kept in the session; nothing ends, nothing is changed on screen")
            text.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            check(text.hasMarkedText() && text.string == "serverㅎ", "a syllable is being composed")
            let identity = ObjectIdentifier(field)
            for _ in 0..<3 {
                probe.refresh += 1
                spin(0.1)
            }
            check(fields(in: window.contentView!).count == 1 && ObjectIdentifier(fields(in: window.contentView!)[0]) == identity,
                  "board refreshes keep the same field")
            check(editing(field) && text.hasMarkedText() && text.string == "serverㅎ" && field.placeholderString == "zsh",
                  "board refreshes leave the composition, the text and the prompt alone")
            check(probe.calls.isEmpty, "nor do they end anything")
            let coordinator = field.delegate as! TitleRenameField.Coordinator
            check(!coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                  "Return in the middle of a composition is the input method's")
            check(!coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                  "so is Escape")
            check(probe.calls.isEmpty, "and neither ends the rename")
            // What the Korean input method does on Return: commit the
            // syllable, then hand the Return on.
            text.insertText("한", replacementRange: text.markedRange())
            check(!text.hasMarkedText(), "the syllable is committed")
            text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check(probe.endings.count == 1 && probe.endings[0].ending == .submit && probe.endings[0].text == "server한",
                  "Return sends the name at once, its last syllable included")
            spin(until: { fields(in: window.contentView!).isEmpty }, "the field goes away")
            spin(0.2)
            check(probe.endings.count == 1, "its going away ends nothing more")
            check(session.giveKeyboardBack() && editing(otherField), "the keyboard goes back to what had it")
        }

        // Escape, once nothing is being composed.
        do {
            let (session, field, text) = begin(.tab(TabSummary(tab: .object(["tab_id": .string("w1:t1"), "label": .string("Owned")]), layout: nil, panes: [:], on: nil)!))
            check(text.string == "Owned" && field.placeholderString == "Owned" && field.toolTip == nil, "a tab starts with its label")
            text.insertText("Changed", replacementRange: none)
            text.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            let coordinator = field.delegate as! TitleRenameField.Coordinator
            check(!coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && probe.endings.count == 1,
                  "Escape while composing doesn't cancel")
            text.unmarkText()
            text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            check(probe.endings.count == 2 && probe.endings[1].id == session.id && probe.endings[1].ending == .cancel, "Escape cancels")
            spin(until: { fields(in: window.contentView!).isEmpty }, "the field goes away")
            check(window.makeFirstResponder(otherField), "the other field has the keyboard again")
        }

        // Return with a tab's name left empty.
        do {
            let (session, field, text) = begin(.tab(TabSummary(tab: .object(["tab_id": .string("w1:t1"), "label": .string("Owned")]), layout: nil, panes: [:], on: nil)!))
            text.insertText("  ", replacementRange: none)
            text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check(probe.refusals == 1 && probe.endings.count == 2 && editing(field), "an empty tab name isn't sent; the field stays, with the keyboard")
            text.selectAll(nil)
            text.insertText("새 탭", replacementRange: none)
            text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check(probe.endings.count == 3 && probe.endings[2].id == session.id && probe.endings[2].ending == .submit && probe.endings[2].text == "새 탭",
                  "a name typed after it is")
            spin(until: { fields(in: window.contentView!).isEmpty }, "the field goes away")
            check(window.makeFirstResponder(otherField), "the other field has the keyboard again")
        }

        // The keyboard going elsewhere, in the middle of a composition.
        do {
            let (session, _, text) = begin(.pane(pane(nil)))
            check(text.string == "", "a pane without a name of its own starts empty")
            text.insertText("abc", replacementRange: none)
            text.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            let before = probe.endings.count
            check(window.makeFirstResponder(otherField), "a click elsewhere takes the keyboard")
            check(session.text == "abcㄱ", "what was being composed is committed into the session as the keyboard goes")
            check(probe.endings.count == before, "ending is left for the next turn of the run loop")
            spin(until: { probe.endings.count == before + 1 }, "then it ends")
            check(probe.endings[before].id == session.id && probe.endings[before].ending == .left && probe.endings[before].text == "abcㄱ",
                  "as the keyboard going elsewhere, with all that was typed")
            spin(until: { fields(in: window.contentView!).isEmpty }, "the field goes away")
            spin(0.2)
            check(probe.endings.count == before + 1, "once")
            check(editing(otherField), "and the keyboard stays where it went")
        }

        // The field going away while it has the keyboard: the title no longer
        // the item's (another row selected, the item gone).
        do {
            let (session, _, text) = begin(.pane(pane(nil)))
            text.insertText("xyz", replacementRange: none)
            let before = probe.endings.count
            probe.session = nil
            spin(until: { fields(in: window.contentView!).isEmpty }, "the field goes away")
            spin(until: { probe.endings.count == before + 1 }, "the rename ends")
            check(probe.endings[before].id == session.id && probe.endings[before].ending == .left && probe.endings[before].text == "xyz",
                  "as the keyboard going elsewhere, with what was typed")
            spin(0.2)
            check(probe.endings.count == before + 1, "once")
            check(probe.calls.filter { $0.id == session.id }.allSatisfy { $0.ending == .left }, "only ever as that")
        }

        window.close()
        print("PASS \(checks) title rename field keyboard/Return/Escape/IME composition/board refresh/focus loss/removal checks; owned never-shown window, no app or herdr")
    }
}
