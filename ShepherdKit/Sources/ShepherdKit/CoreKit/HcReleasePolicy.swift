import Foundation

/// The reviewed distribution baseline, not a version-string authorization gate.
/// Compatible user-managed cores still negotiate generation and required methods.
/// This policy never downloads, installs, updates or restarts a core.
public nonisolated enum HcReleasePolicy {
    public static let version = "0.1.17"
    public static let manifestURL = URL(string: "https://releases.herdr.dev/core/0.1.17/manifest.json")!
    // HC_VERSION belongs to sh, not curl. Showing this command does not run it.
    public static let installCommand = "curl -fsSL https://releases.herdr.dev/core/install.sh | HC_VERSION=0.1.17 sh"
    public static let renderingNotice = "Official hc 0.1.17 is the release baseline. First attach or reconnect can lose previously printed hyperlink destinations and mispaint blank-cell backgrounds. Live output and input remain available; full renderer fidelity is not qualified."
    public static let installationNotice = "This screen does not run the installer. Running the command yourself can replace an existing core and perform an update handover. Review it first; package-manager installations and running programs require separate care."
    public static let privacyNotice = "On macOS, shell and agent file access can prompt under herdr-core's privacy identity. No blanket folder or Full Disk Access grant is required to connect. Only approve access you intend."
}
