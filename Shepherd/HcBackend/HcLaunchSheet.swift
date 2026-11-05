import SwiftUI

/// Human launch intent only. Commands are never synthesized from terminal
/// text/status/labels. No provider config, injected MCP, account prompt or login.
struct HcLaunchSheet: View {
    let model: HcWorkspaceModel
    let machineName: String
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: UUID?
    @State private var workspaceName = "Workspace"
    @State private var name = "Shell"
    @State private var program = "Shell"
    @State private var command = ""
    @State private var directory = ""
    @State private var launching = false
    @State private var failure: String?
    @State private var job: Task<Void,Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New terminal on \(machineName)").font(.title2)
            Form {
                Picker("Workspace", selection: $workspace) {
                    Text("New workspace").tag(Optional<UUID>.none)
                    ForEach(model.document?.workspaces ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                if workspace == nil { TextField("New workspace name", text: $workspaceName) }
                TextField("Tab name", text: $name)
                Picker("Program", selection: $program) {
                    ForEach(["Shell", "Claude Code", "Codex", "Pi", "Shell command"], id: \.self) { Text($0).tag($0) }
                }.accessibilityIdentifier("hc.launch.program")
                if program == "Shell command" { TextField("Command (/bin/sh -lc)", text: $command) }
                TextField("Working directory (absolute, optional)", text: $directory)
            }
            Text("Uses the host's installed CLI and normal user configuration. No browser integration or credentials are injected. Closing a view does not end its program.").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("hc.launch.cancel")
                Spacer()
                if launching { ProgressView().controlSize(.small) }
                Button("Launch") { launch() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("hc.launch.submit")
                    .disabled(!model.canEdit || launching || failure != nil || name.isEmpty || (program == "Shell command" && command.isEmpty))
            }
        }.padding(24).frame(width: 550)
        .onAppear { workspace = model.focus.workspaceID ?? model.document?.workspaces.first?.id }
        .onChange(of: program) { if program != "Shell command" { name = program } }
        .onDisappear { job?.cancel() }
    }
    private func launch() {
        guard !launching else { return }
        guard directory.isEmpty || directory.hasPrefix("/") else { failure = "Use an absolute working directory."; return }
        let argv: [String]
        switch program {
        case "Claude Code": argv = ["claude"]
        case "Codex": argv = ["codex", "--no-daemon"]
        case "Pi": argv = ["pi"]
        case "Shell command": argv = ["/bin/sh", "-lc", command]
        default: argv = []
        }
        launching = true
        job = Task {
            defer { launching = false }
            do {
                let id: UUID
                if let workspace { id = workspace }
                else { id = try await model.createWorkspace(name: workspaceName) }
                try Task.checkCancellation()
                try await model.launchTab(workspaceID: id, name: name, argv: argv, cwd: directory.isEmpty ? nil : directory)
                dismiss()
            } catch {
                failure = "Launch unconfirmed. Close this dialog and review saved operations/core terminals before starting another program. Nothing is automatically resent."
            }
        }
    }
}

struct HcPaneSwitcher: View {
    let model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading) {
            Text("Go to workspace or pane").font(.headline)
            TextField("Search", text: $search).accessibilityIdentifier("hc.switcher.search")
            List {
                ForEach(model.document?.workspaces ?? [], id: \.id) { workspace in
                    ForEach(workspace.tabs, id: \.id) { tab in
                        ForEach(tab.layout?.panes ?? [], id: \.id) { pane in
                            let label = [workspace.name, tab.name, pane.title, pane.terminal?.terminalID].compactMap { $0 }.joined(separator: " · ")
                            if search.isEmpty || label.localizedCaseInsensitiveContains(search) {
                                Button(label) { do { try model.select(pane: pane.id); dismiss() } catch {} }
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("hc.switcher.done") }
        }.padding(20).frame(width: 600, height: 440)
    }
}
