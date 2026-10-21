#if os(macOS)
import AppKit
import SystemConfiguration

extension PairingCoordinator.Environment {
    /// The app's: this Mac's network, its SSH server, firewall and herdr,
    /// Touch ID or the password, `~/.ssh/authorized_keys`, the app's
    /// Application Support folder and its defaults.
    static func system() -> Self {
        Self(snapshot: { NetworkSnapshotSource.current() },
             tailscaleResolver: SystemTailscaleNameResolver(),
             hostKeyProbe: LocalSSHServerProbe(),
             firewall: { await FirewallStatusReader.current() },
             herdrIsRunning: { await LocalHerdrStatus.isRunning(socketPath: LocalHerdrTransport.defaultSocketPath) },
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
