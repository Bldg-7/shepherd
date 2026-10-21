import Foundation

/// A machine running herdr that the user has configured a connection to —
/// herdr's own term; see `MachineStore` for why the client/transport split
/// (local vs. SSH) lives one level down from this.
/// The credential itself (private key or password, per `authMethod`) lives
/// in the Keychain under `keychainTag`, never here.
public struct Machine: Identifiable, Codable, Hashable, Sendable {
    public enum AuthMethod: String, Codable, Sendable {
        case key
        case password
        /// A P-256 key the iOS app made for a Mac it paired with by QR code
        /// (see `SecureEnclaveSSHKey`): in the device's Secure Enclave, or in
        /// software on the Simulator. The secret stored under `keychainTag`
        /// is `SecureEnclaveSSHKey.storedRepresentation`, never a private key
        /// that would work anywhere else.
        case secureEnclaveKey
    }

    /// Which kind of address `hostname` is, for a Mac added by scanning its
    /// pairing QR code (see `PairingAddress`). Every connection to such a
    /// machine looks the name up once and connects only to an IPv4 address
    /// within the kind's range. Nil — machines added by hand, and those saved
    /// before this existed — connects to `hostname` as it is, as before.
    ///
    /// Declared here rather than beside `PairingAddress` because the test
    /// runners compile this file without the pairing code.
    public nonisolated enum AddressKind: String, Codable, CaseIterable, Sendable {
        /// The Mac's Bonjour name, `<name>.local`.
        case localName
        /// An IPv4 address in 10/8, 172.16/12 or 192.168/16.
        case privateIPv4
        /// The Mac's Tailscale IPv4 address, in 100.64/10.
        case tailscaleIPv4
        /// The Mac's Tailscale MagicDNS name, `<name>.<tailnet>.ts.net`.
        case tailscaleMagicDNS
    }

    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var keychainTag: String
    public var authMethod: AuthMethod
    /// Empty means herdr's own "default" session. A non-empty name targets
    /// `~/.config/herdr/sessions/<name>/herdr.sock` instead of the default
    /// `~/.config/herdr/herdr.sock` — see `SSHHerdrTransport`/`TerminalSession`.
    public var sessionName: String
    /// True for the synthetic "this Mac" entry that talks to the local
    /// herdr.sock directly (see `LocalHerdrTransport`/`LocalTerminalSession`)
    /// instead of over SSH. That entry is never persisted via `MachineStore`
    /// — it's reconstructed every launch, always with the same `id` (see
    /// `MachineStore.localMachine`) — but the flag still needs to
    /// round-trip through `Codable` since `Machine` itself does.
    public var isLocal: Bool
    /// SHA256 SSH host key fingerprint pinned on first connect (trust-on-first-use).
    /// Nil until the first successful connection. A Mac paired by QR code
    /// has it from the code, before the first connection.
    public var pinnedHostKeyFingerprint: String?
    /// See `AddressKind`.
    public var addressKind: AddressKind?

    /// `id` is a parameter (rather than always a fresh `UUID()`) for the one
    /// Machine that isn't loaded from storage yet still has to be recognised
    /// across launches: the built-in local entry.
    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .key,
        sessionName: String = "",
        isLocal: Bool = false,
        addressKind: AddressKind? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.keychainTag = "herdr-client.private-key.\(id.uuidString)"
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.isLocal = isLocal
        self.pinnedHostKeyFingerprint = nil
        self.addressKind = addressKind
    }

    /// A connection's scope, not the row's display identity. A saved credential
    /// replacement gets a fresh Keychain tag, so even replacing a password with
    /// another password retires the old connection. TOFU pinning and renaming do
    /// not restart an otherwise unchanged connection. A new address kind does,
    /// as it changes which addresses the connection may go to.
    public nonisolated struct ConnectionIdentity: Hashable, Sendable {
        public let machineID: UUID
        public let hostname: String
        public let port: Int
        public let username: String
        public let sessionName: String
        public let authMethod: AuthMethod
        public let keychainTag: String
        public let isLocal: Bool
        public let addressKind: AddressKind?
    }

    public var connectionIdentity: ConnectionIdentity {
        ConnectionIdentity(machineID: id, hostname: hostname, port: port,
                           username: username, sessionName: sessionName,
                           authMethod: authMethod, keychainTag: keychainTag, isLocal: isLocal,
                           addressKind: addressKind)
    }

    /// `authMethod`/`sessionName`/`isLocal`/`addressKind` default when
    /// decoding Machines saved before they existed, so older stored data
    /// keeps working instead of failing to load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        keychainTag = try container.decode(String.self, forKey: .keychainTag)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .key
        // A name saved before input was normalized can be one the app no
        // longer stores — the literal "default", or padded with whitespace —
        // and would be taken for a named session as it stands. One that
        // can't be normalized at all is kept exactly as stored: such a
        // machine fails to connect, whereas quietly pointing it at the
        // default session would attach to, and take over, a pane in a
        // session nobody chose.
        let storedSessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        sessionName = Self.normalizedSessionName(storedSessionName) ?? storedSessionName
        isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        pinnedHostKeyFingerprint = try container.decodeIfPresent(String.self, forKey: .pinnedHostKeyFingerprint)
        addressKind = try container.decodeIfPresent(AddressKind.self, forKey: .addressKind)
    }

    /// Turns what a person typed into the value `sessionName` stores, or nil
    /// if it can't be a herdr session name.
    ///
    /// Blank and the literal "default" both come back as "" because the
    /// empty string is the one spelling this app uses for herdr's default
    /// session (see `sessionName`): its socket lives at a different path
    /// than a named session's, and everything downstream picks between the
    /// two with a plain `isEmpty`. Storing "default" would send those
    /// checks down the named-session path.
    ///
    /// Anything else must start with an ASCII letter or digit and continue
    /// with only ASCII letters, digits, `.`, `_` or `-`, 64 characters at
    /// most. The name is spliced into a socket path and into a command line
    /// run on the remote machine, so this is deliberately an allow-list:
    /// no `/` or `..` (it stays a single path component under `sessions/`),
    /// no quotes or spaces (nothing for a shell to reinterpret), and no
    /// leading `-` (it can't be mistaken for an option).
    ///
    /// `nonisolated` because the transports that consume a session name are
    /// their own actors, off the main actor.
    public nonisolated static func normalizedSessionName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "default" {
            return ""
        }

        func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }

        let scalars = name.unicodeScalars
        guard scalars.count <= 64, let first = scalars.first, isASCIILetterOrDigit(first) else {
            return nil
        }
        let restIsAllowed = scalars.dropFirst().allSatisfy { scalar in
            isASCIILetterOrDigit(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        }
        return restIsAllowed ? name : nil
    }
}
