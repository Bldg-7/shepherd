import SwiftUI
import AppKit

// Real panel and pane store, owned files and a never-shown window only.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}
final class OwnedSecrets: MachineSecretStore {
    func saveSecret(_ data: Data, tag: String) throws {}
    func loadSecret(tag: String) throws -> Data? { preconditionFailure("no credentials") }
    func deleteSecret(tag: String) throws {}
}
struct RestoreRoot: View {
    let entry: FilePreviewPaneStates.Entry?
    let store: MachineStore
    var body: some View {
        if let entry {
            FilePreviewPanel(request: entry.request, model: entry.model, machineStore: store,
                             onClose: {}, onFileLink: { _ in }).id(entry.model.id)
        } else { Color.clear }
    }
}

@main @MainActor enum ScrollRestoreTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    static func scrollView(_ view: NSView) -> NSScrollView? {
        scrollViews(view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    static func settle(_ view: NSView, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return false
    }
    static func drain(_ view: NSView, turns: Int = 30) {
        for _ in 0..<turns {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
    static func scroll(_ view: NSView, to y: CGFloat) {
        let scroll = scrollView(view)!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    static func text(_ model: FilePreviewModel) -> String? {
        if case .loaded(let document) = model.state, case .text(let text, _) = document.content { return text }
        return nil
    }
    static func mixed() -> String {
        var parts = ["# Guide", "```\n" + (1...60).map { "long code line \($0)" }.joined(separator: "\n") + "\n```"]
        for n in 1...60 {
            switch n % 5 {
            case 0: parts.append("## Section \(n)")
            case 1: parts.append(String(repeating: "Paragraph \(n) wraps differently in each width of the preview. ", count: n % 4 + 1))
            case 2: parts.append("```swift\n" + (0..<(n % 17 + 4)).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n```")
            case 3: parts.append("| Name | Value |\n| --- | --- |\n" + (0..<(n % 7 + 2)).map { "| row \($0) | value \(n) |" }.joined(separator: "\n"))
            default: parts.append("> Quote \(n): a long quoted line that wraps in a narrow side panel.")
            }
        }
        return parts.joined(separator: "\n\n")
    }
    static func geometryChecks() {
        let rows = PreviewVisibleRows()
        var saved: PreviewScrollAnchor?
        rows.onAnchor = { saved = $0 }
        _ = rows.place(4, at: CGRect(x: 0, y: 100, width: 100, height: 200))
        _ = rows.appear(4, true)
        _ = rows.show(CGRect(x: 0, y: 140, width: 100, height: 100))
        let anchor = rows.top()!
        check(anchor.row == 4 && anchor.offset == 40 && anchor.height == 200, "row and within-row distance")
        rows.isRestoring = true
        _ = rows.place(4, at: CGRect(x: 0, y: 80, width: 100, height: 400))
        check(saved == anchor && rows.target(for: anchor) == 160, "restore suppresses saves and scales offset")
        var gap = anchor; gap.offset = -10
        check(rows.target(for: gap) == 70, "inter-row gap does not scale")
        _ = rows.appear(4, false)
        check(rows.target(for: anchor) == nil, "off-screen row needs materialization")
        _ = rows.place(5, at: CGRect(x: 0, y: 220, width: 100, height: 50))
        _ = rows.appear(5, true)
        check(rows.top() == nil, "a far-ahead lazy row is not a valid saved anchor")
    }
    static func main() throws {
        geometryChecks()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = ProcessInfo.processInfo.arguments[1]
        let mixedText = mixed()
        let wrapped = (1...250).map { n in String(repeating: "Paragraph \(n) has a different wrapped height. ", count: n % 4 + 1) }.joined(separator: "\n\n")
        for (name, value) in [("mixed.md", mixedText), ("wrapped.txt", wrapped), ("other.md", "# Other\n\nShort.")] {
            try Data(value.utf8).write(to: URL(fileURLWithPath: directory + "/" + name))
        }
        let suite = "owned-scroll-restore-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = Machine(displayName: "Owned Local", hostname: "localhost", username: "owned", isLocal: true)
        let store = MachineStore(defaults: defaults, localMachine: machine, keychain: OwnedSecrets())
        let states = FilePreviewPaneStates()
        func pane(_ name: String) -> AgentSummary {
            AgentSummary(json: .object(["pane_id": .string(name), "terminal_id": .string(name), "cwd": .string(directory)]), on: nil)!
        }
        let q = pane("w1:q")
        let qi = TerminalIdentity(connection: machine.connectionIdentity, itemID: q.id)
        states.open(FilePreviewRequest(machine: machine, pane: q, link: "other.md"), for: qi)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingController(rootView: RestoreRoot(entry: nil, store: store))
        host.sizingOptions = []
        window.contentViewController = host
        var number = 0

        func run(_ file: String, source: Bool = false, y: CGFloat = 2000,
                 width: CGFloat = 560, retry: Bool = false, shorter: Bool = false,
                 block: Int? = nil, into: CGFloat = 0, navigate: Bool = false) throws {
            window.setContentSize(NSSize(width: 560, height: 520))
            number += 1
            let p = pane("w1:p\(number)")
            let pi = TerminalIdentity(connection: machine.connectionIdentity, itemID: p.id)
            let request = FilePreviewRequest(machine: machine, pane: p, link: file)
            states.open(request, for: pi)
            let entry = states.entry(for: pi, panes: [p])!
            let model = entry.model
            host.rootView = RestoreRoot(entry: entry, store: store)
            check(settle(host.view) { text(model) != nil }, "file loaded")
            if source { model.showsSource = true }
            check(settle(host.view) { (scrollView(host.view)?.documentView?.frame.height ?? 0) > 3000 }, "long document")
            drain(host.view)
            if let block {
                model.reveal(.block(block))
                drain(host.view)
                scroll(host.view, to: scrollView(host.view)!.contentView.bounds.origin.y + into)
            } else { scroll(host.view, to: y) }
            drain(host.view)
            guard let kept = model.scrollAnchor else { preconditionFailure("missing saved anchor") }
            if let block { check(kept.row == block, "long block or table at viewport top") }
            if retry {
                let url = URL(fileURLWithPath: directory + "/" + file)
                let original = try Data(contentsOf: url)
                try FileManager.default.removeItem(at: url)
                Task { await model.reload(request, store: store) }
                check(settle(host.view) { if case .failed = model.state { return true }; return false }, "failed read")
                drain(host.view)
                check(model.scrollAnchor == kept, "failure preserves anchor")
                try (shorter ? Data("# Short\n\nOnly this.".utf8) : original).write(to: url)
                Task { await model.reload(request, store: store) }
                check(settle(host.view) { text(model) != nil }, "retry loaded")
                if shorter { try original.write(to: url) }
            } else {
                host.rootView = RestoreRoot(entry: states.entry(for: qi, panes: [q]), store: store)
                drain(host.view)
                check(model.scrollAnchor == kept, "departing view preserves the anchor")
                window.setContentSize(NSSize(width: width, height: 520))
                host.rootView = RestoreRoot(entry: entry, store: store)
            }
            if navigate {
                drain(host.view, turns: 1)
                model.reveal(.block(0))
            }
            // Includes the bounded 40-frame restore timeout and settling.
            drain(host.view, turns: 90)
            if shorter {
                check((scrollView(host.view)?.contentView.bounds.origin.y ?? -1) < 1, "missing row clamps to short document")
            } else if navigate {
                check(model.visibleBlocks.first == 0, "explicit navigation beats pending restore")
            } else {
                guard let back = model.scrollAnchor else { preconditionFailure("missing restored anchor") }
                let wanted = kept.offset <= 0 || kept.height <= 0 ? kept.offset : kept.offset / kept.height * back.height
                check(back.inSource == kept.inSource && back.row == kept.row, "same top row after return: \(file) \(y) \(kept) -> \(back)")
                check(abs(back.offset - wanted) < 1, "same within-row place: \(kept) -> \(back)")
                check((back.inSource ? model.visibleLines.first : model.visibleBlocks.first) == kept.row, "visible rows match saved anchor")
                check(abs((model.scrollOffset?.y ?? -1) - scrollView(host.view)!.contentView.bounds.origin.y) < 1, "point fallback tracks the completed restoration")
                scroll(host.view, to: scrollView(host.view)!.contentView.bounds.origin.y + 300)
                drain(host.view)
                check(model.scrollAnchor != back, "normal scrolling saves new anchor after restore")
            }
            print("PASS case \(number): \(file), source=\(source), y=\(y), width=\(width), retry=\(retry), shorter=\(shorter), navigate=\(navigate)")
        }
        for y in [900.0, 1310, 3500, 5000] { try run("mixed.md", y: y) }
        for y in [900.0, 2000, 5000] { try run("mixed.md", source: true, y: y) }
        for y in [1200.0, 3000, 6000] { try run("wrapped.txt", y: y) }
        try run("mixed.md", width: 400)
        try run("wrapped.txt", y: 3000, width: 400)
        try run("mixed.md", retry: true)
        try run("wrapped.txt", y: 1200, retry: true)
        let blocks = PreviewMarkdownDocument(mixedText).blocks
        let table = blocks.first { if case .table = $0.kind { return $0.id > 20 }; return false }!.id
        try run("mixed.md", block: table, into: 40)
        try run("mixed.md", block: 1, into: 600)
        try run("mixed.md", retry: true, shorter: true)
        try run("mixed.md", navigate: true)
        check(!window.isVisible, "window was never shown")
        print("PASS \(checks) row-anchor geometry and real panel restoration checks")
    }
}
