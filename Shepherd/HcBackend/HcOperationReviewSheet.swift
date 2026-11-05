import SwiftUI

/// Human review of metadata only. No rerun/adoption by labels, process kill,
/// native-session grant, or automatic replay is offered by this surface.
struct HcOperationReviewSheet: View {
    let model: HcWorkspaceModel
    let review: HcWorkspaceModel.OperationReview
    @Environment(\.dismiss) private var dismiss
    @State private var forget = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review saved operation").font(.title2)
            Text(review.record.kind.rawValue.capitalized).font(.headline)
            Text("Reviewed layout version: \(review.expectedVersion)").font(.caption)
            if let reference = review.record.terminal {
                Text(reference.coreID + "/" + reference.terminalID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else if review.record.kind == .launch { Text("Program identity unconfirmed").foregroundStyle(.secondary) }
            Text(explanation)
            Text("Only layout metadata can be applied here. Programs are never started, adopted or terminated. If the layout changes after this review, cancel and review it again.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if model.operationBusy { ProgressView("Applying once…") }
            HStack {
                Button("Forget tracking only…", role: .destructive) { forget = true }.accessibilityIdentifier("hc.review.forget")
                    .disabled(model.operationBusy || model.state != .connected)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.operationBusy).accessibilityIdentifier("hc.review.cancel")
                Button("Apply reviewed layout once") {
                    Task {
                        do { try await model.applyOperationReview(review); dismiss() }
                        catch { self.error = "Layout was not confirmed. Close this sheet and review a fresh read before another attempt. Nothing is automatically resent." }
                    }
                }.disabled(!model.canApply(review)).accessibilityIdentifier("hc.review.apply")
            }
        }
        .padding(24).frame(width: 620)
        .interactiveDismissDisabled(model.operationBusy)
        .onDisappear { model.cancelOperationReview(review) }
        .confirmationDialog("Forget this operation's tracking?", isPresented: $forget) {
            Button("Forget tracking only", role: .destructive) {
                Task {
                    do { try await model.forgetOperationReview(review); dismiss() }
                    catch { self.error = "Tracking could not be removed. No program was changed." }
                }
            }.accessibilityIdentifier("hc.review.forget.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A program whose launch was unconfirmed may still be running. This removes bookkeeping only; it does not stop, adopt or relaunch anything.")
        }
    }
    private var explanation: String {
        if review.record.layout == .confirmed { return "The layout action is already confirmed. Later user edits will not be undone. Any unconfirmed program outcomes remain separate." }
        if review.canApplyLayout {
            return review.record.kind == .launch
                ? "A successful run receipt is saved and its original pane is still unbound. You can explicitly bind that exact reference with one new CAS attempt."
                : "The original tab still has the reviewed members. You can explicitly close those views while keeping all programs running."
        }
        return "There is no safe layout reapplication for this record: the launch outcome is unknown or its target fields changed. Inspect core terminals separately; operation labels are not ownership proof."
    }
}
