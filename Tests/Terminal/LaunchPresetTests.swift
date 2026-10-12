import SwiftUI

// Runtime launch/authentication is not exercised by picking a launch preset.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum LaunchPresetTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func main() {
        func pane(workspace: String?, on machine: HerdrMachine? = nil) -> AgentSummary {
            var json: [String: JSONValue] = ["pane_id": .string("w1:p1"), "tab_id": .string("w1:t1"), "terminal_id": .string("terminal-1")]
            if let workspace { json["workspace_id"] = .string(workspace) }
            return AgentSummary(json: .object(json), on: machine)!
        }
        func workspace(_ id: String, _ label: String) -> LaunchWorkspace {
            LaunchWorkspace(workspace: WorkspaceSummary(json: .object(["workspace_id": .string(id), "label": .string(label)]))!, tabCount: 1)
        }
        let remote = HerdrMachine(id: "other", label: "Other", target: "never-connect", session: "default", enabled: true)
        let host = LaunchTarget(herdrMachine: nil, label: "This Mac", workspaces: [workspace("w1", "Host A"), workspace("w2", "Host B")], unavailableReason: nil)
        let nested = LaunchTarget(herdrMachine: remote, label: "Other", workspaces: [workspace("w1", "Nested A")], unavailableReason: nil)
        let targets = [host, nested]

        check(LaunchPreset.current(for: nil, in: targets) == nil, "nothing selected asks from the start")

        let hostPane = pane(workspace: "w2")
        check(BoardItem.pane(hostPane).workspaceID == "w2", "pane item reports its workspace")
        let onHost = LaunchPreset.current(for: .pane(hostPane), in: targets)
        check(onHost?.targetID == host.id && onHost?.workspace?.label == "Host B", "selected pane picks its own herdr and workspace")

        let nestedPane = pane(workspace: "w1", on: remote)
        let onNested = LaunchPreset.current(for: .pane(nestedPane), in: targets)
        check(onNested?.targetID == nested.id && onNested?.workspace?.label == "Nested A", "same raw workspace ID on another herdr is not the host's")

        let tab = TabSummary(tab: .object(["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "label": .string("Owned")]), layout: nil, panes: [hostPane.paneID: hostPane], on: nil)!
        check(BoardItem.tab(tab).workspaceID == "w1", "tab item reports its workspace, not a pane's")
        let onTab = LaunchPreset.current(for: .tab(tab), in: targets)
        check(onTab?.targetID == host.id && onTab?.workspace?.label == "Host A", "selected tab picks its own workspace")

        let closed = LaunchPreset.current(for: .pane(pane(workspace: "w9")), in: targets)
        check(closed?.targetID == host.id && closed?.workspace == nil, "workspace no longer listed leaves only the machine picked")
        let unsaid = LaunchPreset.current(for: .pane(pane(workspace: nil)), in: targets)
        check(unsaid?.targetID == host.id && unsaid?.workspace == nil, "herdr that names no workspace leaves only the machine picked")

        let loading = LaunchTarget(herdrMachine: remote, label: "Other", workspaces: nested.workspaces, unavailableReason: "Loading…")
        check(LaunchPreset.current(for: .pane(nestedPane), in: [host, loading]) == nil, "herdr no tab can be opened on asks from the start")
        check(LaunchPreset.current(for: .pane(nestedPane), in: [host]) == nil, "herdr machine no longer offered asks from the start")
        print("PASS \(checks) launch preset selection/nested herdr identity/tab workspace/closed workspace/unavailable target checks; snapshots only, no network")
    }
}
