import SwiftUI
import AppKit

// The new tab launcher's real field (extracted from NewTabLauncher.swift by
// the runner) in an owned window that is never shown, driven the way the
// Korean input method drives its field editor: what is committed through
// insertText, the syllable still being composed through setMarkedText.
// AppKit tells the field's delegate only about the first, so the launcher's
// text is the committed part while a syllable is being composed.

@MainActor @Observable final class FieldProbe {
    var highlighted = 0
    var clearRequests = 0
    @ObservationIgnored var writes: [String] = []
    @ObservationIgnored var submitted: [String] = []
    @ObservationIgnored var text: () -> String = { "" }
}

private struct ProbeLauncher: View {
    let probe: FieldProbe
    @State private var text = ""
    var body: some View {
        VStack {
            LauncherField(
                text: Binding(get: { text }, set: { probe.writes.append($0); text = $0 }),
                prompt: "Workspace",
                isEnabled: true,
                restoresFocusOnClose: true,
                onWindow: { _ in },
                onMove: { _ in },
                onSubmit: { probe.submitted.append(text) },
                onCancel: {},
                onDeleteBackwardInEmptyField: {}
            )
            // What re-renders the launcher while a word is being typed: the
            // pointer over the list, the board's refreshes.
            Text(verbatim: "row \(probe.highlighted)")
        }
        .frame(width: 400, height: 80)
        .onAppear { probe.text = { text } }
        // As choose() does after a click on a row: the field is emptied.
        .onChange(of: probe.clearRequests) { text = "" }
    }
}

@main @MainActor enum LauncherFieldTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func drain(_ turns: Int = 20) {
        for _ in 0..<turns { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.delegate is LauncherField.Coordinator { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let probe = FieldProbe()
        let host = NSHostingView(rootView: ProbeLauncher(probe: probe))
        window.contentView = host
        drain()
        guard let field = field(in: host), let editor = field.currentEditor() as? NSTextView else {
            preconditionFailure("the field takes the keyboard once it is in its window")
        }
        checks += 1
        let nowhere = NSRange(location: NSNotFound, length: 0)
        func compose(commit: String?, mark: String) {
            if let commit { editor.insertText(commit, replacementRange: nowhere) }
            editor.setMarkedText(mark, selectedRange: NSRange(location: (mark as NSString).length, length: 0), replacementRange: nowhere)
        }

        // 프 committed and 로 begun in one keystroke: the update the commit
        // asks for leaves 로 where it is.
        compose(commit: nil, mark: "프")
        compose(commit: "프", mark: "로")
        drain()
        check(field.stringValue == "프로" && editor.hasMarkedText(), "the syllable being composed stays in the field: \(field.stringValue)")
        check(probe.text() == "프", "the launcher has what is committed: \(probe.text())")

        // The launcher re-rendered in the middle of the word.
        probe.highlighted += 1
        drain()
        check(field.stringValue == "프로" && editor.hasMarkedText(), "a re-render leaves the composition alone: \(field.stringValue)")

        compose(commit: "로", mark: "ㅈ")
        drain()
        check(field.stringValue == "프로ㅈ" && probe.text() == "프로", "the next syllable: \(field.stringValue) / \(probe.text())")

        // Return: the input method commits, then insertNewline reaches the
        // delegate — the tab is asked for with the last syllable.
        editor.insertText("젝", replacementRange: nowhere)
        let handled = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        drain()
        check(handled == true && probe.submitted == ["프로젝"], "Return submits the whole word: \(probe.submitted)")

        // The launcher empties the field while a syllable is being composed.
        compose(commit: nil, mark: "ㅌ")
        drain()
        probe.clearRequests += 1
        drain()
        check(field.stringValue.isEmpty && !editor.hasMarkedText() && probe.text().isEmpty, "the field is emptied: \(field.stringValue) / \(probe.text())")

        // Only typing changed the launcher's text — nothing the field
        // reported while SwiftUI was updating it.
        check(probe.writes == ["프", "프로", "프로젝"], "writes: \(probe.writes)")
        print("PASS \(checks) launcher field composition checks: commit with next syllable, re-render, Return, emptying, writes only from typing; unshown owned window, no input method or app")
    }
}
