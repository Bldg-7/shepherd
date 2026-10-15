import Foundation

// Runtime-only enum dependency; actual Machine/pane/session models are intact.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum WebLinkTests {
    static var checks = 0
    static func check(_ b: Bool) { precondition(b); checks += 1 }
    static func main() throws {
        for raw in ["https://example.invalid/", "http://localhost:8080/a?q=one%20two#f", "HTTPS://example.invalid/한글", "https://[::1]:8443/path"] {
            check(TerminalWebLink.isWebLink(raw))
            check(try TerminalWebLink.urlToOpen(raw, contextMatches: true, browserEnabled: true, engineAvailable: true) == raw)
            check(try TerminalWebLink.urlToOpen(raw, contextMatches: false, browserEnabled: true, engineAvailable: true) == nil)
            do { _ = try TerminalWebLink.urlToOpen(raw, contextMatches: true, browserEnabled: false, engineAvailable: true); preconditionFailure() }
            catch TerminalWebLinkError.browserDisabled { checks += 1 }
            do { _ = try TerminalWebLink.urlToOpen(raw, contextMatches: true, browserEnabled: true, engineAvailable: false); preconditionFailure() }
            catch TerminalWebLinkError.engineUnavailable { checks += 1 }
        }
        for raw in ["https:", "https:///missing", "https://user:synthetic@example.invalid/", "https://example.invalid:0/", "https://example.invalid:65536/", "https://example.invalid/a b", "https://example.invalid/\n", "javascript:alert(1)", "file:///owned/a", "data:text/html,hello", "https://example.invalid/" + String(repeating: "x", count: 8192)] {
            do { _ = try TerminalWebLink.urlToOpen(raw, contextMatches: true, browserEnabled: true, engineAvailable: true); preconditionFailure("invalid URL accepted") }
            catch TerminalWebLinkError.invalidURL { checks += 1 }
        }
        check(TerminalWebLink.isWebLink("http:malformed"))
        check(!TerminalWebLink.isWebLink("ssh://example.invalid"))
        check(TerminalWebLink.token(in: "Read https://example.invalid/a?q=b#c, now", characterOffset: 12) == "https://example.invalid/a?q=b#c")
        check(TerminalWebLink.token(in: "README.md", characterOffset: 2) == nil)
        check(TerminalWebLink.token(in: "file:///owned/a.md", characterOffset: 3) == nil)
        check(TerminalWebLink.token(in: "PR은 https://example.invalid/pull/16048에서 확인", characterOffset: 8) == "https://example.invalid/pull/16048")
        check(TerminalWebLink.token(in: "PR은 https://example.invalid/pull/16048에서 확인", characterOffset: 38) == nil)
        check(TerminalWebLink.token(in: "https://example.invalid/wiki/서울", characterOffset: 3) == "https://example.invalid/wiki/서울")
        var machine = Machine(displayName: "Owned", hostname: "owned.invalid", username: "fixture")
        func pane(_ terminal: String, nested: HerdrMachine? = nil) -> AgentSummary {
            AgentSummary(json: .object(["pane_id": .string("p1"), "terminal_id": .string(terminal)]), on: nested)!
        }
        let original = pane("terminal-1"), request = TerminalWebLinkRequest(machine: machine, pane: original, url: "https://example.invalid/")
        check(request.pane(in: [original], on: machine)?.terminalID == "terminal-1")
        check(request.pane(in: [pane("replacement-terminal")], on: machine) == nil)
        check(request.pane(in: [], on: machine) == nil)
        machine.hostname = "changed.invalid"
        check(request.pane(in: [original], on: machine) == nil)
        machine = request.machine; machine.keychainTag = "replaced-secret-tag"
        check(request.pane(in: [original], on: machine) == nil)
        machine = request.machine; machine.displayName = "Renamed"
        check(request.pane(in: [original], on: machine) != nil)
        let nested = HerdrMachine(id: "nested", label: "Owned", target: "owned.invalid", session: "default", enabled: true)
        check(request.pane(in: [pane("terminal-1", nested: nested)], on: machine) == nil)
        let nestedRequest = TerminalWebLinkRequest(machine: machine, pane: pane("terminal-1", nested: nested), url: request.rawURL)
        check(nestedRequest.pane(in: [original], on: machine) == nil)
        check(nestedRequest.pane(in: [pane("terminal-1", nested: nested)], on: machine) != nil)
        print("PASS \(checks) production URL validation/OFF/unavailable/stale connection/pane/terminal/nested scope checks; no network/browser/credential access")
    }
}
