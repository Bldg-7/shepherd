#if os(macOS)
import Foundation
import LocalAuthentication

/// `LAContext` with `.deviceOwnerAuthentication`: Touch ID where the Mac
/// has it, the password otherwise or when Touch ID fails.
@MainActor final class DeviceOwnerApproval: PairingApprovalAuthenticating {
    private var context: LAContext?

    func authenticate(reason: String) async -> String? {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.localizedDescription ?? String(localized: "This Mac can't ask for Touch ID or your password.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? nil : String(localized: "Authentication didn't succeed.")
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            return String(localized: "Authentication was cancelled.")
        } catch {
            return error.localizedDescription
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}
#endif
