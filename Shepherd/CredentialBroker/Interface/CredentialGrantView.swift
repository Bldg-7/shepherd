#if os(macOS)
import SwiftUI
import Observation

/// Integration supplies one explicitly selected local agent owner and capability
/// readiness. Merely selecting an account/item is not permission to resolve it.
@MainActor @Observable final class CredentialGrantController {
    let owner: CredentialOwner
    private let broker: CredentialBroker
    private let service: CredentialCLIService
    private let connection: PasswordManagerConnectionCoordinator
    private let available: () -> Bool
    private(set) var handle: CredentialHandle?
    private(set) var state = "Unavailable"
    private var operation: UUID?
    @ObservationIgnored private var expiryNotification: DispatchWorkItem?
    var displayState: String {
        guard available(), connection.trustedCredentialLease() != nil else { return "Unavailable" }
        return state
    }
    init(owner: CredentialOwner, broker: CredentialBroker, service: CredentialCLIService,
         connection: PasswordManagerConnectionCoordinator, available: @escaping () -> Bool) {
        self.owner=owner; self.broker=broker; self.service=service
        self.connection=connection; self.available=available
    }
    var canApprove: Bool { operation == nil && available() && connection.trustedCredentialLease() != nil }
    func approve(vault: String, item: String, url: String, field: String) async {
        guard canApprove, let lease = connection.trustedCredentialLease() else { state="Unavailable"; return }
        let operationID = UUID(); operation=operationID
        defer { if operation == operationID { operation=nil } }
        do {
            if let handle { try? await broker.cancel(handle,owner:owner); self.handle=nil }
            let reference = try ApprovedPasswordReference(provider:lease.providerID,accountID:lease.accountID,
                vaultID:lease.providerID == .onePassword ? vault : nil,itemID:item)
            let destination = try CredentialDestination(url:url,field:field)
            let created = try await broker.createHumanGrant(HumanCredentialGrant(reference:reference,
                destination:destination,owner:owner,providerEpoch:lease.epoch,lifetimeNanoseconds:120_000_000_000))
            guard operation == operationID, available(), connection.trustedCredentialLease()?.epoch == lease.epoch else {
                try? await broker.cancel(created,owner:owner); return
            }
            do { try service.registerApproved(created,owner:owner) }
            catch { try? await broker.cancel(created,owner:owner); throw error }
            handle=created; state="Approved — one request, 2 minutes"
            expiryNotification?.cancel()
            let notification = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.handle == created else { return }
                    await self.refresh()
                }
            }
            expiryNotification=notification
            DispatchQueue.main.asyncAfter(deadline:.now()+120,execute:notification)
        } catch { state="Unavailable" }
    }
    func clear() async {
        operation=nil; expiryNotification?.cancel(); expiryNotification=nil
        let old=handle; handle=nil; state="Revoked"
        if let old { try? await broker.cancel(old,owner:owner) }
    }
    func refresh() async {
        guard let handle else { state="Unavailable"; return }
        state=(try? await broker.status(handle,owner:owner).rawValue) ?? "Unavailable"
    }
}

struct CredentialGrantView: View {
    let controller: CredentialGrantController
    let connection: PasswordManagerConnectionCoordinator
    @State private var vault = ""
    @State private var item = ""
    @State private var destination = ""
    @State private var field = "password"
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Credential approval").font(.headline)
            Text(verbatim:"\(controller.owner.session) / \(controller.owner.paneID) / \(controller.owner.terminalID)")
            Text(verbatim:connection.metadata(for:connection.providerID).accountID)
            if connection.providerID == .onePassword { TextField("Vault ID",text:$vault) }
            TextField("Item ID",text:$item)
            TextField("Exact HTTPS POST URL",text:$destination)
            TextField("Form field name",text:$field)
            Text("Approve this account/item password for this pane and exact URL only. One request within 2 minutes. No item listing is performed.")
                .font(.caption)
            Text(verbatim:controller.displayState)
            HStack {
                Button("Approve one request") {
                    Task { await controller.approve(vault:vault,item:item,url:destination,field:field); vault=""; item="" }
                }.disabled(!controller.canApprove)
                Button("Revoke approval") { Task { await controller.clear(); vault=""; item="" } }
                Button("Refresh status") { Task { await controller.refresh() } }
            }
        }
        .onDisappear { vault=""; item=""; Task { await controller.clear() } }
    }
}
#endif
