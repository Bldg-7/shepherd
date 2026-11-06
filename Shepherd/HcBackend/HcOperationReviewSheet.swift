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
            Text(HcRecoveryPresentationText.title(review.record)).font(.headline)
            Text("Reviewed layout version: \(review.expectedVersion)").font(.caption)
            if let reference = review.record.terminal {
                Text(reference.coreID + "/" + reference.terminalID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else if review.record.kind == .launch { Text("Program identity unconfirmed").foregroundStyle(.secondary) }
            Text(HcRecoveryPresentationText.explanation(review.record,canApplyLayout:review.canApplyLayout))
            if !review.record.targets.isEmpty {
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(review.record.targets,id:\.terminal) { target in
                            VStack(alignment:.leading,spacing:3) {
                                Text(target.terminal.coreID + "/" + target.terminal.terminalID)
                                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Text(HcRecoveryPresentationText.stop(target.state)).font(.caption)
                            }
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:180)
            }
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
}
