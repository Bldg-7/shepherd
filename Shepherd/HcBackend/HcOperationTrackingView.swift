import SwiftUI

/// Secondary recovery/diagnostic surface; never replaces the normal board.
struct HcOperationTrackingView: View {
    let model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var review: HcWorkspaceModel.OperationReview?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            Text("Operation tracking").font(.headline)
            List {
                Section("Operations needing review") {
                    ForEach(model.recoveryRecords.filter { !$0.complete }, id: \.id) { row($0) }
                }
                Section("Completed operation history") {
                    ForEach(model.recoveryRecords.filter(\.complete), id: \.id) { row($0) }
                }
                Section("Core terminals — diagnostic") {
                    ForEach(model.terminals, id: \.address) { terminal in
                        VStack(alignment: .leading) {
                            Text(terminal.name ?? terminal.address)
                            Text(terminal.state).font(.caption).foregroundStyle(.secondary)
                            if terminal.state == "live", let id = model.focus.workspaceID ?? model.document?.workspaces.first?.id {
                                Button("Show as new tab") { perform { try await model.showTerminal(terminal.address, workspaceID: id) } }
                                    .disabled(!model.canEdit)
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("hc.tracking.done") }
        }.padding(20).frame(width: 560, height: 500)
        .sheet(item: $review) { HcOperationReviewSheet(model: model, review: $0) }
        .alert("Operation unconfirmed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func row(_ operation: CoreWorkspaceRecovery.Record) -> some View {
        VStack(alignment: .leading) {
            Text(operation.kind.rawValue.capitalized).font(.headline)
            Text(operation.terminal?.terminalID ?? "Program identity unconfirmed").font(.caption)
            Text("No automatic retry or termination.").font(.caption).foregroundStyle(.secondary)
            Button("Review tracking") { perform { review = try await model.prepareOperationReview(operation.id) } }
                .accessibilityIdentifier("hc.review.open.\(operation.id)")
                .disabled(model.operationBusy || model.operationReview != nil || model.state != .connected)
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { self.error = "Operation unconfirmed. Nothing is automatically resent." } }
    }
}
