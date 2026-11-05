import SwiftUI

/// Read-only first-level directory. A snapshot is not an atomic routing lease;
/// do not expose attach/run/input/file actions on this release's gateway path.
struct HcGatewayDirectoryView: View {
    let model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: HcGatewaySnapshot?
    @State private var failed = false
    @State private var loading = false
    @State private var request = UUID()

    private var current: HcGatewaySnapshot? {
        guard model.state == .connected, let snapshot, snapshot.hub.id == model.coreID,
              snapshot.epoch == model.workspace?.epoch else { return nil }
        return snapshot
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Core origins · read only").font(.title2)
            Text("This directory is routing metadata, not native-session or browser authority. It shows first-level origins from one reply; deeper origins are not flattened into these rows.")
                .font(.caption).foregroundStyle(.secondary)
            if let current {
                List {
                    origin(current.hub.id, name: current.hub.name, state: "Gateway host", snapshot: current)
                    ForEach(current.machines) { machine in
                        origin(machine.id, name: machine.name, state: machine.state, snapshot: current)
                    }
                }.accessibilityIdentifier("hc.origins.list")
                Text("Origin actions are unavailable here: the selected hc release can resolve an alias before a permanent core ID. A fresh directory cannot prevent concurrent configuration changes. Use a separately configured, pinned SSH connection for direct terminal and file actions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if loading { ProgressView("Reading core directory…") }
            else {
                Text(failed ? "The directory could not be validated. Ambiguous IDs or aliases are not shown; nothing was routed or changed." : "The connection is no longer current. Nothing was routed or changed.")
                    .accessibilityIdentifier("hc.origins.unavailable")
            }
            Spacer(minLength: 0)
            HStack {
                Button("Refresh") { Task { await refresh() } }
                    .disabled(loading || model.state != .connected).accessibilityIdentifier("hc.origins.refresh")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("hc.origins.done")
            }
        }.padding(20).frame(width: 650, height: 560)
        .task { await refresh() }
        .onDisappear { request = UUID(); snapshot = nil }
    }
    private func origin(_ id: String, name: String, state: String, snapshot: HcGatewaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            Text(id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(state).font(.caption).foregroundStyle(.secondary)
            // Invalid addresses fail this row closed; never relabel another row.
            if let terminals = try? snapshot.terminals(on: id) {
                ForEach(terminals, id: \.reference) { terminal in
                    HStack {
                        Text(terminal.observed.name ?? terminal.reference.terminalID)
                        Text(terminal.reference.terminalID).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(terminal.observed.state).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if terminals.isEmpty { Text("No terminals in this reply").font(.caption).foregroundStyle(.secondary) }
            } else { Text("Invalid terminal addresses; this origin is unavailable").font(.caption) }
        }.padding(.vertical, 4)
    }
    private func refresh() async {
        guard !loading else { return }
        let token = UUID(); request = token; loading = true; snapshot = nil; failed = false
        do {
            let value = try await model.readGatewayDirectory()
            guard request == token, !Task.isCancelled else { return }
            snapshot = value; loading = false
        } catch {
            guard request == token else { return }
            failed = true; loading = false
        }
    }
}
