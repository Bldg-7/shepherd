import Foundation

/// A remote machine saved in herdr itself (`herdr machine add`) on the host
/// Shepherd talks to — not one of Shepherd's own Machines. A herdr session
/// can have several of these connected, each running a herdr server of its
/// own, and their agents belong on the board next to the host's.
///
/// herdr keeps these on the client side only: the socket API has no notion
/// of them, so they are read with the herdr CLI (`herdr machine list
/// --json`), and their agents are fetched through it too (`herdr --machine`),
/// which reaches them over the host's own OpenSSH setup.
nonisolated struct HerdrMachine: Identifiable, Hashable, Sendable, Decodable {
    /// herdr's profile ID: stable, and unambiguous where a label may not be.
    let id: String
    let label: String
    /// What herdr passes to `ssh`: a Host alias, `user@host`, or an
    /// `ssh://user@host:port` URI.
    let target: String
    /// The herdr session on that machine this profile is for.
    let session: String
    let enabled: Bool
}

/// The herdr CLI exited with a failure. Its message is herdr's own, from
/// stderr — e.g. "error: machine 'gpu' (session default): ssh: connect to
/// host … Connection refused" — which says more than any summary could.
nonisolated struct HerdrCommandError: Error, LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? {
        let trimmed = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "error: ", with: "", options: .anchored)
        guard !trimmed.isEmpty else {
            return String(localized: "herdr exited with status \(status).")
        }
        return trimmed
    }
}
