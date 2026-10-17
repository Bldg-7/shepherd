import SwiftUI

// Runtime launch/authentication is not exercised by deciding what a rename sends.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

/// What a name typed into the window's title starts out with, what it sends
/// to herdr, and how long the title shows it before herdr's reports it.
/// Snapshots only: no herdr, no window.
@main @MainActor enum TitleRenameTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func pane(_ id: String = "w1:p1", label: String? = nil, title: String = "zsh", on machine: HerdrMachine? = nil) -> AgentSummary {
        var json: [String: JSONValue] = ["pane_id": .string(id), "tab_id": .string("w1:t1"), "terminal_id": .string("terminal-\(id)"),
                                         "terminal_title_stripped": .string(title)]
        if let label { json["label"] = .string(label) }
        return AgentSummary(json: .object(json), on: machine)!
    }

    static func tab(_ label: String?, _ panes: [AgentSummary], on machine: HerdrMachine? = nil) -> TabSummary {
        var json: [String: JSONValue] = ["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "number": .number(2)]
        if let label { json["label"] = .string(label) }
        return TabSummary(tab: .object(json), layout: nil, panes: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) }), on: machine)!
    }

    static func main() {
        let unnamed = pane(), named = pane(label: "build")
        let owned = tab("Owned", [unnamed]), numbered = tab(nil, [unnamed])

        // Where the field starts: the name it has, and what it goes by without one.
        check(TitleRename.startText(for: .pane(unnamed)) == "" && TitleRename.prompt(for: .pane(unnamed)) == "zsh",
              "a pane without a name of its own starts empty, its title the prompt")
        check(TitleRename.startText(for: .pane(named)) == "build" && TitleRename.prompt(for: .pane(named)) == "zsh",
              "a named pane starts with its name, its automatic title the prompt")
        check(TitleRename.startText(for: .tab(owned)) == "Owned" && TitleRename.prompt(for: .tab(owned)) == "Owned",
              "a tab starts with its label")
        check(TitleRename.startText(for: .tab(numbered)) == "2", "a tab never named starts with its number, as herdr shows it")
        check(BoardItem.pane(named).title == "build" && BoardItem.pane(unnamed).title == "zsh" && BoardItem.tab(owned).title == "Owned",
              "the item's title is the row's")

        let session = TitleRenameSession(item: .pane(named))
        check(session.text == "build" && session.startText == "build" && session.prompt == "zsh" && !session.isEnded,
              "a session holds what the field starts with")
        check(session.end() && session.isEnded && !session.end(), "of the ways a rename ends, only the first counts")
        check(TitleRenameSession(item: .pane(named)).id != session.id, "every rename is a session of its own")

        // What Return may send.
        check(!TitleRename.canSubmit("  \n", for: .tab(owned)) && !TitleRename.canSubmit("", for: .tab(owned)),
              "a tab can't be given an empty name")
        check(TitleRename.canSubmit("x", for: .tab(owned)) && TitleRename.canSubmit("", for: .pane(named)),
              "a pane can: that takes its name away")

        // What goes to herdr.
        check(TitleRename.commit("   ", for: .tab(owned)) == nil, "an empty tab name is never sent")
        check(TitleRename.commit(" Owned ", for: .tab(owned)) == nil, "a tab's unchanged name isn't sent")
        let renamedTab = TitleRename.commit(" 새 이름 ", for: .tab(owned))
        check(renamedTab?.name == "새 이름" && renamedTab?.shownTitle == "새 이름" && renamedTab?.readsSinceSent == nil,
              "a tab's new name, trimmed, shown until herdr reports it")
        check(TitleRename.commit("", for: .pane(unnamed)) == nil, "a pane without a name left empty: nothing to send")
        check(TitleRename.commit(" build ", for: .pane(named)) == nil, "a pane's unchanged name isn't sent")
        let cleared = TitleRename.commit(" \t", for: .pane(named))
        check(cleared?.name == "" && cleared?.shownTitle == "zsh", "a pane's name emptied is taken away; its title shows meanwhile")
        let given = TitleRename.commit("server", for: .pane(unnamed))!
        check(given.name == "server" && given.shownTitle == "server", "a pane given a name")
        check(TitleRename.commit("server", for: .pane(unnamed))!.id != given.id, "every commit is one of its own")

        // Which title shows it.
        check(given.title(for: .pane(unnamed)) == "server" && given.title(for: .pane(named)) == "server",
              "the renamed pane's title shows the typed name, whatever snapshot of it is selected")
        let gpu = HerdrMachine(id: "gpu", label: "GPU", target: "never-connect", session: "default", enabled: true)
        check(given.title(for: .pane(pane(on: gpu))) == nil, "the same raw pane ID on a herdr machine is another pane")
        check(given.title(for: .pane(pane("w1:p2"))) == nil && given.title(for: .tab(owned)) == nil, "nothing else's title")

        // How long it shows.
        check(given.afterRead(of: .pane(unnamed)) == given, "reads while the request is still out count for nothing")
        var sent = given
        sent.readsSinceSent = 0
        check(sent.afterRead(of: .pane(pane(label: "server"))) == nil, "a read with the new name: the title is herdr's again")
        let once = sent.afterRead(of: .pane(unnamed))
        check(once?.readsSinceSent == 1 && once?.id == sent.id, "a read begun before herdr took the name: keep showing it")
        check(once?.afterRead(of: .pane(unnamed)) == nil, "the second read since: herdr's title, however herdr kept the name")
        check(sent.afterRead(of: nil) == nil, "an item no longer listed: nothing to show it for")
        var sentClear = cleared!
        sentClear.readsSinceSent = 0
        check(sentClear.afterRead(of: .pane(unnamed)) == nil, "a name taken away: settled once the pane reads by its title")
        var sentTab = renamedTab!
        sentTab.readsSinceSent = 0
        check(sentTab.afterRead(of: .tab(tab("새 이름", [unnamed]))) == nil, "a tab's new name read")

        print("PASS \(checks) title rename start/prompt/submit/commit/trim/qualified identity/shown title/settle checks; snapshots only, no network")
    }
}
