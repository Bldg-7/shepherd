import Foundation

// Runtime-only enum dependency; actual Machine/pane/session models are intact.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum WebLinkTests {
    static var checks = 0
    static func check(_ b: Bool, line: UInt = #line) { precondition(b, "line \(line)"); checks += 1 }
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
        for raw in ["https://example.invalid/", "http://localhost:8080/a?q=one%20two#f"] {
            check(try TerminalWebLink.validatedURL(raw) == raw)
        }
        do { _ = try TerminalWebLink.validatedURL("https://user:synthetic@example.invalid/"); preconditionFailure("invalid URL accepted") }
        catch TerminalWebLinkError.invalidURL { checks += 1 }
        // Where a click goes: In-app Browser, ⌘ for the default browser, and
        // the default browser for whatever In-app Browser can't show — said
        // in a notice only when it is on but can't run on this Mac.
        typealias Policy = LinkDestinationPolicy
        struct Row { let command, enabled, engine: Bool; let destination: Policy.Destination; let notice: Bool }
        let table = [
            Row(command: false, enabled: true, engine: true, destination: .shepherd, notice: false),
            Row(command: true, enabled: true, engine: true, destination: .system, notice: false),
            Row(command: false, enabled: false, engine: true, destination: .system, notice: false),
            Row(command: true, enabled: false, engine: true, destination: .system, notice: false),
            Row(command: false, enabled: true, engine: false, destination: .system, notice: true),
            Row(command: true, enabled: true, engine: false, destination: .system, notice: false),
            Row(command: false, enabled: false, engine: false, destination: .system, notice: false),
            Row(command: true, enabled: false, engine: false, destination: .system, notice: false),
        ]
        check(Set(table.map { "\($0.command)\($0.enabled)\($0.engine)" }).count == 8)
        for row in table {
            check(Policy.destination(commandHeld: row.command, browserEnabled: row.enabled, engineAvailable: row.engine) == row.destination)
            check(Policy.saysBrowserUnavailable(commandHeld: row.command, browserEnabled: row.enabled, engineAvailable: row.engine) == row.notice)
        }
        // The same for a file: a click goes to In-app Browser unless an
        // agent is connected to it, when it goes to the default browser with
        // a notice of its own; for a web link that connection changes
        // nothing. At most one notice, never for ⌘ or a browser that is off.
        struct FileRow { let target: Policy.Target; let command, enabled, engine, agent: Bool; let destination: Policy.Destination; let unavailable, agentNotice: Bool }
        let fileTable = [
            // This Mac, In-app Browser on, Apple silicon.
            FileRow(target: .localFile, command: false, enabled: true, engine: true, agent: false, destination: .shepherd, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: true, engine: true, agent: false, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: false, enabled: true, engine: true, agent: true, destination: .system, unavailable: false, agentNotice: true),
            FileRow(target: .localFile, command: true, enabled: true, engine: true, agent: true, destination: .system, unavailable: false, agentNotice: false),
            // In-app Browser off (the default).
            FileRow(target: .localFile, command: false, enabled: false, engine: true, agent: false, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: false, engine: true, agent: false, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: false, enabled: false, engine: true, agent: true, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: false, engine: true, agent: true, destination: .system, unavailable: false, agentNotice: false),
            // On, on an Intel Mac.
            FileRow(target: .localFile, command: false, enabled: true, engine: false, agent: false, destination: .system, unavailable: true, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: true, engine: false, agent: false, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: false, enabled: true, engine: false, agent: true, destination: .system, unavailable: true, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: true, engine: false, agent: true, destination: .system, unavailable: false, agentNotice: false),
            // Off, on an Intel Mac.
            FileRow(target: .localFile, command: false, enabled: false, engine: false, agent: false, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: false, engine: false, agent: false, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: false, enabled: false, engine: false, agent: true, destination: .system, unavailable: false, agentNotice: false),
            FileRow(target: .localFile, command: true, enabled: false, engine: false, agent: true, destination: .system, unavailable: false, agentNotice: false),
        ] + table.flatMap { row in
            [false, true].map { agent in
                FileRow(target: .web, command: row.command, enabled: row.enabled, engine: row.engine, agent: agent, destination: row.destination, unavailable: row.notice, agentNotice: false)
            }
        }
        check(Set(fileTable.map { "\($0.target)\($0.command)\($0.enabled)\($0.engine)\($0.agent)" }).count == 32)
        for row in fileTable {
            check(Policy.destination(row.target, commandHeld: row.command, browserEnabled: row.enabled, engineAvailable: row.engine, agentConnected: row.agent) == row.destination)
            check(Policy.saysBrowserUnavailable(commandHeld: row.command, browserEnabled: row.enabled, engineAvailable: row.engine) == row.unavailable)
            check(Policy.saysAgentUsesBrowser(row.target, commandHeld: row.command, browserEnabled: row.enabled, engineAvailable: row.engine, agentConnected: row.agent) == row.agentNotice)
            check(!(row.unavailable && row.agentNotice))
            check(row.destination == .system || !(row.unavailable || row.agentNotice))
        }
        // Left out, the target is a web link and no agent is connected.
        check(Policy.destination(commandHeld: false, browserEnabled: true, engineAvailable: true) == Policy.destination(.web, commandHeld: false, browserEnabled: true, engineAvailable: true, agentConnected: true))
        let click = TerminalLinkClick(commandHeld: true)
        // A click SwiftTerm reports itself is taken for a plain click.
        check(!TerminalLinkClick.unknown.commandHeld && Policy.destination(commandHeld: TerminalLinkClick.unknown.commandHeld, browserEnabled: true, engineAvailable: true) == .shepherd)
        check(TerminalWebLinkRequest(machine: Machine(displayName: "Owned", hostname: "owned.invalid", username: "fixture"), pane: AgentSummary(json: .object(["pane_id": .string("p1"), "terminal_id": .string("t1")]))!, url: "https://example.invalid/", click: click).click == click)
        check(TerminalWebLinkRequest(machine: Machine(displayName: "Owned", hostname: "owned.invalid", username: "fixture"), pane: AgentSummary(json: .object(["pane_id": .string("p1"), "terminal_id": .string("t1")]))!, url: "https://example.invalid/").click == .unknown)
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
        try pageLinks()
        print("PASS \(checks) production URL validation/click destination and notice table/stale connection/pane/terminal/nested scope checks, HTML page links, pane locations, routes, the file and agent table and the default-browser opener; no network/browser/credential access")
    }

    /// HTML files on this Mac as pages: the links, the panes they open
    /// from, where a click on one goes, and how the default browser gets it.
    static func pageLinks() throws {
        typealias Page = TerminalPageLink
        let directory = "/Users/me/proj", host = "mac.local"
        func page(_ raw: String, directory: String? = directory) -> String? {
            Page.pageURL(raw, directory: directory, hostname: host)
        }
        // Resolved as the preview resolves a link; the line of `path:line`
        // dropped, a `file:` link's fragment kept, a query refused.
        let pages: [(String, String)] = [
            ("/Users/me/report.html", "file:///Users/me/report.html"),
            ("report.html", "file:///Users/me/proj/report.html"),
            ("docs/../report.htm", "file:///Users/me/proj/report.htm"),
            ("./Report.HTML", "file:///Users/me/proj/Report.HTML"),
            ("report.HtM", "file:///Users/me/proj/report.HtM"),
            ("report.html:12", "file:///Users/me/proj/report.html"),
            ("report.html:12:3", "file:///Users/me/proj/report.html"),
            ("/abs/report.htm:7", "file:///abs/report.htm"),
            ("file:///Users/me/report.html", "file:///Users/me/report.html"),
            ("FILE:///Users/me/report.html", "file:///Users/me/report.html"),
            ("file://localhost/Users/me/report.html", "file:///Users/me/report.html"),
            ("file://MAC.local/Users/me/report.html", "file:///Users/me/report.html"),
            ("file:///Users/me/report.html#summary", "file:///Users/me/report.html#summary"),
            ("file:///Users/me/report.html#L12", "file:///Users/me/report.html#L12"),
            ("file:///Users/me/report.html#L12:3", "file:///Users/me/report.html#L12:3"),
            ("file:///Users/me/report.html#sum%20mary", "file:///Users/me/report.html#sum%20mary"),
            ("file:///Users/me/report.html#", "file:///Users/me/report.html"),
            ("file:///Users/me/a%20b/%ED%95%9C.html", "file:///Users/me/a%20b/%ED%95%9C.html"),
            ("file:///Users/me/100%25.html", "file:///Users/me/100%25.html"),
            ("/Users/me/a b.html", "file:///Users/me/a%20b.html"),
            ("/Users/me/a#b.html", "file:///Users/me/a%23b.html"),
            // What the URL parser takes, it encodes: so does the page.
            ("file:///Users/me/a b.html", "file:///Users/me/a%20b.html"),
            ("file:///Users/me/report.html#an anchor", "file:///Users/me/report.html#an%20anchor"),
            ("file:///Users/me/report.html#a#b", "file:///Users/me/report.html#a%23b"),
        ]
        for (raw, url) in pages {
            check(page(raw) == url, raw)
            check(Page.validatedURL(url) == url && Page.isPageURL(url), url)
        }
        // Korean names stay as they were written, composed or not: the URL
        // is built from the path's own characters.
        let composed = "/Users/me/보고서/결과.html", decomposed = composed.decomposedStringWithCanonicalMapping
        // (Swift's == takes the two for the same string; their bytes differ.)
        check(Array(composed.utf8) != Array(decomposed.utf8) && Array(composed.utf8) == Array(composed.precomposedStringWithCanonicalMapping.utf8))
        for path in [composed, decomposed] {
            let url = try require(page(path))
            check(Array((URLComponents(string: url)?.path ?? "").utf8) == Array(path.utf8))
            check(URL(string: url)?.isFileURL == true && Page.validatedURL(url) == url)
        }
        check(page(composed) == "file:///Users/me/%EB%B3%B4%EA%B3%A0%EC%84%9C/%EA%B2%B0%EA%B3%BC.html")
        check(page(composed) != URL(fileURLWithPath: composed).absoluteString)
        // Not a page: other files, other machines, other schemes, and links
        // the preview can't take either, which it goes on saying why.
        for raw in ["report.xhtml", "image.svg", "README.md", "report.html.txt", "/dir.html/readme.md", "report", ".html",
                    "file:///Users/me/report.html?x=1", "file://otherhost/Users/me/report.html", "file://user@/Users/me/report.html",
                    "file://localhost:80/Users/me/report.html", "~/report.html", "https://example.invalid/report.html", "ssh://example.invalid/a.html",
                    "report.htm:12", "/Users/me/report\u{7}.html", "file:///Users/me/report.html#\u{7}", "",
                    "/Users/me/" + String(repeating: "x", count: 8192) + ".html"] {
            check(page(raw) == nil, String(raw.prefix(80)))
        }
        check(page("report.html", directory: nil) == nil && page("/Users/me/report.html", directory: nil) == "file:///Users/me/report.html")
        // What `openWeb` takes as a page link: what `pageURL` makes.
        for url in ["file://host/a.html", "file:///a.md", "file:///a.html?x", "file://user:p@/a.html", "file://:80/a.html", "https://x.invalid/a.html",
                    "file:a.html", "file:///a%0A.html", "file:///a b.html", "file:///a.html\n", "file:///a.svg", "file:///a.xhtml", "file:///"] {
            check(Page.validatedURL(url) == nil, url)
        }
        check(Page.isPageURL("FILE:///a.html") && !Page.isPageURL("https://x.invalid/a.html") && !Page.isPageURL("about:blank"))
        // The tabs emptied before an agent is given the browser.
        for address in ["file:///Users/me/report.html", "FILE:///x", "file://localhost/x", "view-source:file:///Users/me/report.html", "View-Source:FILE:///x"] {
            check(Page.isLocalFileAddress(address))
        }
        for address in ["", "about:blank", "https://example.invalid/", "http://localhost/file:///x", "data:text/html,file:", "blob:https://x.invalid/1", "view-source:https://example.invalid/", "chrome://version"] {
            check(!Page.isLocalFileAddress(address))
        }

        // Where a pane is: only one of this Mac's own herdr opens pages.
        let thisMac = Machine(displayName: "This Mac", hostname: host, username: "me", isLocal: true)
        let sshMachine = Machine(displayName: "Server", hostname: "server.invalid", username: "me")
        let herdrMachine = HerdrMachine(id: "box", label: "Box", target: "box.invalid", session: "default", enabled: true)
        func pane(cwd: String? = directory, on nested: HerdrMachine? = nil) -> AgentSummary {
            var json: [String: JSONValue] = ["pane_id": .string("p1"), "terminal_id": .string("t1")]
            if let cwd { json["cwd"] = .string(cwd) }
            return AgentSummary(json: .object(json), on: nested)!
        }
        check(Page.opensPages(in: pane(), on: thisMac))
        check(!Page.opensPages(in: pane(on: herdrMachine), on: thisMac))
        check(!Page.opensPages(in: pane(), on: sshMachine))
        check(!Page.opensPages(in: pane(on: herdrMachine), on: sshMachine))
        check(Page.opensPages(machineIsLocal: true, onHerdrMachine: false) && !Page.opensPages(machineIsLocal: true, onHerdrMachine: true)
              && !Page.opensPages(machineIsLocal: false, onHerdrMachine: false) && !Page.opensPages(machineIsLocal: false, onHerdrMachine: true))

        // Where a click goes, from each.
        typealias Route = TerminalLinkRoute
        check(Route("report.html", in: pane(), on: thisMac) == .page("file:///Users/me/proj/report.html"))
        check(Route("file:///Users/me/proj/Report.HTM#sec", in: pane(), on: thisMac) == .page("file:///Users/me/proj/Report.HTM#sec"))
        check(Route("report.html:3", in: pane(), on: thisMac) == .page("file:///Users/me/proj/report.html"))
        for (location, machine, nested) in [("SSH machine", sshMachine, nil), ("herdr machine on this Mac", thisMac, herdrMachine), ("herdr machine on an SSH machine", sshMachine, herdrMachine)] as [(String, Machine, HerdrMachine?)] {
            check(Route("report.html", in: pane(on: nested), on: machine) == .file("report.html"), location)
            check(Route("file:///Users/me/report.html#sec", in: pane(on: nested), on: machine) != nil, location)
            check(Route("https://example.invalid/", in: pane(on: nested), on: machine) == .web("https://example.invalid/"), location)
        }
        check(Route("file:///Users/me/report.html#sec", in: pane(), on: sshMachine) == .file("file:///Users/me/report.html#sec"))
        check(Route("README.md", in: pane(), on: thisMac) == .file("README.md"))
        check(Route("docs/index.xhtml", in: pane(), on: thisMac) == .file("docs/index.xhtml"))
        check(Route("image.svg", in: pane(), on: thisMac) == .file("image.svg"))
        check(Route(" https://example.invalid/a ", in: pane(), on: thisMac) == .web("https://example.invalid/a"))
        check(Route(" report.html ", in: pane(), on: thisMac) == .page("file:///Users/me/proj/report.html"))
        check(Page.pageURL(" report.html ", directory: directory, hostname: host) == nil)
        check(Route("http:malformed", in: pane(), on: thisMac) == .web("http:malformed"))
        check(Route("ssh://example.invalid/a.html", in: pane(), on: thisMac) == nil)
        // The preview still says why for what it couldn't take before.
        check(Route("file:///Users/me/report.html?x=1", in: pane(), on: thisMac) == .file("file:///Users/me/report.html?x=1"))
        check(Route("file://otherhost/Users/me/report.html", in: pane(), on: thisMac) == .file("file://otherhost/Users/me/report.html"))
        check(Route("report.html", in: pane(cwd: nil), on: thisMac) == .file("report.html"))
        check(Route("~/report.html", in: pane(), on: thisMac) == .file("~/report.html"))
        // A relative `name.htm:line` reads as a scheme, as it did: not a link.
        check(Route("report.htm:12", in: pane(), on: thisMac) == nil && !FilePreviewLink.isFileGestureLink("report.htm:12"))
        check(Route("/abs/report.htm:12", in: pane(), on: thisMac) == .page("file:///abs/report.htm"))
        // A page link goes with the click it came with, to `openWeb`.
        let request = TerminalWebLinkRequest(machine: thisMac, pane: pane(), url: "file:///Users/me/proj/report.html", click: TerminalLinkClick(commandHeld: true))
        check(request.click.commandHeld && Page.isPageURL(request.rawURL) && request.pane(in: [pane()], on: thisMac) != nil)

        // The default browser: a file goes to the app that opens https
        // links, not to what opens .html; with none, to what opens it.
        var opened: [String] = [], asked = 0
        let browser = URL(fileURLWithPath: "/Applications/Owned Browser.app")
        func opener(_ app: URL?) -> DefaultBrowserOpener {
            DefaultBrowserOpener(webBrowser: { asked += 1; return app },
                                 openWithDefaultApp: { opened.append("default " + $0.absoluteString) },
                                 openWithApp: { opened.append("\($1.lastPathComponent) " + $0.absoluteString) })
        }
        let file = try require(URL(string: "file:///Users/me/proj/report.html#sec"))
        opener(browser).open(file)
        check(opened == ["Owned Browser.app file:///Users/me/proj/report.html#sec"] && asked == 1)
        opened = []; asked = 0
        opener(nil).open(file)
        check(opened == ["default file:///Users/me/proj/report.html#sec"] && asked == 1)
        opened = []; asked = 0
        opener(browser).open(try require(URL(string: "https://example.invalid/a")))
        check(opened == ["default https://example.invalid/a"] && asked == 0)
    }

    static func check(_ b: Bool, _ why: String, line: UInt = #line) { precondition(b, "\(why), line \(line)"); checks += 1 }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { preconditionFailure("missing value") }
        checks += 1
        return value
    }
}
