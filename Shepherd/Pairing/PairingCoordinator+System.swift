#if os(macOS)
import AppKit
import SystemConfiguration

/// Explicit pairing setup uses the same normal hc connect policy as the
/// board. hc may start its service, but no install/restart/stop is performed.
nonisolated enum HcPairingCoreStatus {
    static func isAvailable() async -> Bool {
        var connection: CoreRPCConnection?
        do {
            let rpc = try CoreRPCConnection(transport: HcConnectionPolicy.localTransport(), requiredMethods: HcConnectionPolicy.requiredMethods)
            connection = rpc; _ = try await rpc.connect(); try await rpc.close(); return true
        } catch { try? await connection?.close(); return false }
    }
}

extension PairingCoordinator.Environment {
    /// The app's: this Mac's network, its SSH server, firewall and herdr,
    /// Touch ID or the password, `~/.ssh/authorized_keys`, the app's
    /// Application Support folder and its defaults.
    static func system() -> Self {
        Self(snapshot: { NetworkSnapshotSource.current() },
             tailscaleResolver: SystemTailscaleNameResolver(),
             hostKeyProbe: LocalSSHServerProbe(),
             firewall: { await FirewallStatusReader.current() },
             herdrIsRunning: { await HcPairingCoreStatus.isAvailable() },
             approval: DeviceOwnerApproval(),
             authorizedKeys: .forThisAccount(),
             store: .standard(),
             preferences: .standard,
             username: NSUserName(),
             macName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "Mac",
             requestAttention: { NSApp.requestUserAttention(.informationalRequest) })
    }
}
#endif
