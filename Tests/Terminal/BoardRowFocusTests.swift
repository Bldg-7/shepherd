import AppKit
import SwiftUI
import SwiftTerm
import Observation

func connectionFailureDescription(_ error: any Error) -> String { "\(error)" }

@MainActor @Observable private final class FocusProbe {
    var selection: String?
    var request: TerminalPaneFocus?
    var revision = 0
    var lastTabPane = "tab-b"
    @ObservationIgnored var terminals: [String: TerminalView] = [:]
    @ObservationIgnored var creations: [String: Int] = [:]
    @ObservationIgnored var activations = 0
    func activate(_ id: String) {
        selection = id
        request = TerminalPaneFocus(paneID: id == "tab" ? lastTabPane : id)
        activations += 1
    }
}

private struct FocusTerminal: View {
    let id: String
    let probe: FocusProbe
    @State private var model = AgentTerminalViewModel(makeSession: { fatalError("focus must never start an attach") })
    var body: some View {
        TerminalHostView(onCreate: { view in
            model.attach(terminalView: view)
            probe.terminals[id] = view
            probe.creations[id, default: 0] += 1
            if probe.request?.paneID == id { model.requestKeyboardFocus() }
        }, onInput: { _ in }, onResize: { _, _ in })
        .onChange(of: probe.request) { _, request in
            if request?.paneID == id { model.requestKeyboardFocus() }
        }
    }
}

private struct FocusFixture: View {
    let probe: FocusProbe
    var body: some View {
        @Bindable var probe = probe
        HStack(spacing: 0) {
            List(selection: $probe.selection) {
                ForEach(["pane-a", "pane-b", "tab"], id: \.self) { id in
                    HStack { Text("\(id) \(probe.revision)"); Spacer() }
                        .tag(id)
                        .onBoardRowActivation { probe.activate(id) }
                        .boardSelectionEmphasized(probe.selection == id)
                }
            }.listStyle(.sidebar).frame(width: 240)
            if let selected = probe.selection {
                HStack {
                    ForEach(selected == "tab" ? ["tab-a", "tab-b"] : [selected], id: \.self) { id in
                        FocusTerminal(id: id, probe: probe)
                    }
                }
            } else { Color.black }
        }
    }
}

@main @MainActor enum BoardRowFocusTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1
    }
    static func settle(_ host: NSView, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if condition() { return true }
        } while Date() < deadline
        return false
    }
    static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    /// Drive the same callback installed on the fixture's rows. AppKit does
    /// not deliver synthetic List mouse events while this test app is inactive;
    /// do not activate it or send input to a user's window to work around that.
    /// Native gesture delivery in the running app remains a manual check.
    private static func activateRow(_ probe: FocusProbe, table: NSTableView, row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        probe.activate(["pane-a", "pane-b", "tab"][row])
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let probe = FocusProbe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: FocusFixture(probe: probe))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 500))
        let host = controller.view
        defer { window.close() }
        check(settle(host) { table(in: host)?.numberOfRows == 3 }, "native sidebar rows mounted")
        let list = table(in: host)!
        activateRow(probe, table: list, row: 0)
        let firstFocused = settle(host) { probe.terminals["pane-a"].map { window.firstResponder === $0 } == true }
        if !firstFocused {
            print("focus diagnostic: selection=\(String(describing: probe.selection)) activations=\(probe.activations) terminals=\(probe.terminals.keys) responder=\(String(describing: window.firstResponder)) table=\(list.frame) row=\(list.rect(ofRow: 0))")
            let point = list.convert(NSPoint(x: list.rect(ofRow: 0).midX, y: list.rect(ofRow: 0).midY), to: nil)
            print("point=\(point) window=\(window.frame) hit=\(String(describing: host.hitTest(host.convert(point, from: nil)))) hidden=\(list.isHiddenOrHasHiddenAncestor)")
            fflush(stdout)
        }
        check(firstFocused, "first pane click gives the new terminal the keyboard")
        check(probe.selection == "pane-a" && probe.activations == 1, "native selection and explicit activation both work")
        let firstView = probe.terminals["pane-a"]!, firstRequest = probe.request
        check(window.makeFirstResponder(list), "sidebar can own the keyboard before reselecting")
        activateRow(probe, table: list, row: 0)
        check(settle(host) { window.firstResponder === firstView }, "already-selected row returns keyboard to terminal")
        check(probe.request != firstRequest && probe.creations["pane-a"] == 1, "fresh request, same terminal, no attach recreation")
        activateRow(probe, table: list, row: 1)
        check(settle(host) { probe.terminals["pane-b"].map { window.firstResponder === $0 } == true }, "another pane click hands off to that terminal")
        activateRow(probe, table: list, row: 2)
        check(settle(host) { probe.terminals["tab-b"].map { window.firstResponder === $0 } == true }, "tab click focuses its chosen pane, not every split")
        let tabA = probe.terminals["tab-a"]!, tabB = probe.terminals["tab-b"]!
        probe.lastTabPane = "tab-a"
        check(window.makeFirstResponder(list), "sidebar takes keyboard before tab reselection")
        activateRow(probe, table: list, row: 2)
        check(settle(host) { window.firstResponder === tabA }, "tab reselection restores the last active pane")
        check(probe.terminals["tab-b"] === tabB && probe.creations["tab-a"] == 1 && probe.creations["tab-b"] == 1, "split terminals remain mounted")
        let input = NSTextField(string: "filter or browser input")
        input.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        host.addSubview(input)
        check(window.makeFirstResponder(input), "another input can take keyboard")
        let editor = window.firstResponder, count = probe.activations
        probe.revision += 1
        _ = settle(host) { false }
        check(window.firstResponder === editor && probe.activations == count, "metadata refresh does not steal input focus")
        input.removeFromSuperview()
        // Keyboard/programmatic List selection is not a primary click.
        probe.selection = "pane-a"
        check(window.makeFirstResponder(list), "list owns keyboard for non-click navigation")
        _ = settle(host) { probe.creations["pane-a"] == 2 }
        check(probe.activations == count && window.firstResponder === list, "non-click selection creates no activation request")
        print("PASS \(checks) sidebar activation/focus checks; production terminal focus, callback-driven unshown fixture, native mouse delivery NOTRUN, no session or network")
    }
}
