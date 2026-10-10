import Foundation
import Observation

/// Persists the (non-secret) machine list to UserDefaults as JSON, plus
/// which one is currently active. Fine for the handful of machines a single
/// user manages; revisit if this ever needs to sync across devices.
///
/// Invariant the rest of the app leans on: whenever `allMachines` is
/// non-empty, `activeMachineID` names one of them, so `activeMachine` is nil
/// only when there is genuinely nothing to show.
@Observable
final class MachineStore {
    private(set) var machines: [Machine] = []
    var activeMachineID: UUID? {
        didSet { persistActiveID() }
    }

    private let defaults: UserDefaults
    private let suppliedLocalMachine: Machine?
    let localSocketPath: String?

    private let defaultsKey = "herdr-client.machines"
    /// Where the list lived while a Machine was still called a Host. Only
    /// ever read (see `adoptLegacyHosts`), never written or removed.
    private let legacyDefaultsKey = "herdr-client.hosts"
    /// Holds a copy of a stored list that `load()` couldn't decode.
    private let unreadableDefaultsKey = "herdr-client.machines.unreadable"
    private let activeDefaultsKey = "herdr-client.active-machine-id"
    private let keychain: any MachineSecretStore

    enum EditError: LocalizedError {
        case notEditable, settingsChanged, invalidFields, credentialRequired, missingCredential

        var errorDescription: String? {
            switch self {
            case .notEditable: String(localized: "This machine cannot be edited or was removed.")
            case .settingsChanged: String(localized: "The machine settings changed. Reopen the machine and try again.")
            case .invalidFields: String(localized: "Check the name, hostname, username, port and session.")
            case .credentialRequired: String(localized: "Enter a new credential when changing authentication.")
            case .missingCredential: String(localized: "No saved SSH credential was found. Edit the machine to set up authentication.")
            }
        }
    }

    #if os(macOS)
    /// Synthetic, never persisted via `addMachine`/Keychain — a fixed
    /// built-in entry so there's always something usable with zero setup.
    ///
    /// Its `id` is a hard-coded constant rather than a fresh `UUID()`
    /// because, although the entry itself is rebuilt on every launch, its id
    /// is not: it's what gets saved as the active machine. A random id would
    /// stop matching the saved one the next time the app starts, and "This
    /// Mac" would silently stop being the active machine.
    static let localMachine = Machine(
        id: UUID(uuidString: "79763D9A-997B-4E75-A3FA-6EF5D0338479")!,
        displayName: String(localized: "This Mac"),
        hostname: "localhost",
        port: 0,
        username: NSUserName(),
        isLocal: true
    )
    #endif

    init(defaults: UserDefaults = .standard, localMachine: Machine? = nil, localSocketPath: String? = nil,
         keychain: any MachineSecretStore = KeychainStore()) {
        self.keychain = keychain
        self.defaults = defaults
        self.suppliedLocalMachine = localMachine
        self.localSocketPath = localSocketPath
        load()
        // The saved id is only a preference: it can be missing (first
        // launch) or name a machine that's no longer in the list, so it's
        // resolved against what actually loaded. `@Observable` routes this
        // assignment through the property's setter even inside `init`, so
        // `didSet` runs and the resolved id is written back — a stale saved
        // id doesn't linger in UserDefaults.
        let savedID = defaults.string(forKey: activeDefaultsKey).flatMap { UUID(uuidString: $0) }
        activeMachineID = existingMachineID(preferring: savedID)
    }

    /// The built-in local entry (macOS only) followed by every registered
    /// Machine, in the order they were added.
    var allMachines: [Machine] {
        [suppliedLocalMachine ?? Self.localMachine] + machines
    }

    var activeMachine: Machine? {
        allMachines.first { $0.id == activeMachineID }
    }

    func addMachine(_ machine: Machine, privateKey: Data) throws {
        try keychain.saveSecret(privateKey, tag: machine.keychainTag)
        register(machine)
    }

    func addMachine(_ machine: Machine, password: String) throws {
        try keychain.saveSecret(Data(password.utf8), tag: machine.keychainTag)
        register(machine)
    }

    /// Update metadata without reading the saved secret. When explicitly replacing
    /// a credential, write a fresh tag before committing metadata: a failed write
    /// must not delete or overwrite the only copy of the existing SSH key.
    func updateMachine(_ replacement: Machine, replacing original: Machine,
                       replacementSecret: Data? = nil) throws {
        guard !original.isLocal, !replacement.isLocal, replacement.id == original.id,
              let index = machines.firstIndex(where: { $0.id == original.id }),
              !machines[index].isLocal else { throw EditError.notEditable }
        let current = machines[index]
        guard current.connectionIdentity == original.connectionIdentity,
              current.displayName == original.displayName else { throw EditError.settingsChanged }
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = trimmed(replacement.displayName), host = trimmed(replacement.hostname), user = trimmed(replacement.username)
        guard !name.isEmpty, !host.isEmpty, !user.isEmpty, (1...65535).contains(replacement.port),
              let session = Machine.normalizedSessionName(replacement.sessionName) else { throw EditError.invalidFields }
        if let replacementSecret {
            guard !replacementSecret.isEmpty else { throw EditError.credentialRequired }
        } else if replacement.authMethod != current.authMethod {
            throw EditError.credentialRequired
        }
        var updated = current
        updated.displayName = name
        updated.hostname = host
        updated.port = replacement.port
        updated.username = user
        updated.sessionName = session
        updated.authMethod = replacement.authMethod
        // A pin identifies the SSH server, not its username, password or session.
        if host != current.hostname || replacement.port != current.port {
            updated.pinnedHostKeyFingerprint = nil
        }
        if replacementSecret != nil {
            updated.keychainTag = "herdr-client.private-key.\(current.id.uuidString).\(UUID().uuidString)"
        }
        var next = machines
        next[index] = updated
        let encoded = try JSONEncoder().encode(next)
        if let replacementSecret { try keychain.saveSecret(replacementSecret, tag: updated.keychainTag) }
        defaults.set(encoded, forKey: defaultsKey)
        machines = next
        // Cleanup is after the successful commit, never before the new secret is
        // saved. A cleanup failure must not roll back the now-current credential.
        if updated.keychainTag != current.keychainTag { try? keychain.deleteSecret(tag: current.keychainTag) }
    }

    func isCurrentConnection(_ machine: Machine) -> Bool {
        allMachines.contains { $0.connectionIdentity == machine.connectionIdentity }
    }

    /// Keep the connection scope but refresh metadata, especially a TOFU pin
    /// learned after a view captured its Machine value.
    func currentMachine(matching machine: Machine) throws -> Machine {
        guard let current = allMachines.first(where: { $0.connectionIdentity == machine.connectionIdentity }) else {
            throw EditError.settingsChanged
        }
        return current
    }

    func removeMachine(_ machine: Machine) {
        guard !machine.isLocal,
              let current = machines.first(where: { $0.id == machine.id }), !current.isLocal else { return }
        // A removal confirmation may predate an edit in another window.
        try? keychain.deleteSecret(tag: current.keychainTag)
        machines.removeAll { $0.id == machine.id }
        if activeMachineID == machine.id {
            activeMachineID = allMachines.first?.id
        }
        save()
    }

    /// The raw secret bytes for a Machine — a private key PEM or a
    /// password, depending on `machine.authMethod`. Callers that need an
    /// authentication method (which requires Citadel) wrap this in
    /// `HostCredential`.
    func secret(for machine: Machine) throws -> Data? {
        guard isCurrentConnection(machine) else { throw EditError.settingsChanged }
        return try keychain.loadSecret(tag: machine.keychainTag)
    }

    func pinHostKeyFingerprint(_ fingerprint: String, for machine: Machine) {
        guard let index = machines.firstIndex(where: { $0.id == machine.id }),
              machines[index].connectionIdentity == machine.connectionIdentity,
              machines[index].pinnedHostKeyFingerprint == nil || machines[index].pinnedHostKeyFingerprint == fingerprint else { return }
        machines[index].pinnedHostKeyFingerprint = fingerprint
        save()
    }

    /// Appends a Machine whose credential is already in the Keychain.
    ///
    /// It also becomes the active machine when nothing valid is active —
    /// in practice the first machine added on iOS, where there's no
    /// built-in entry to fall back on and the app would otherwise keep
    /// showing "No Active Machine" until the person found the switch in
    /// Settings. An existing valid choice is left alone: adding a machine
    /// isn't a request to switch to it.
    private func register(_ machine: Machine) {
        machines.append(machine)
        if activeMachine == nil {
            activeMachineID = machine.id
        }
        save()
    }

    /// `preferred` when it names a machine that exists, otherwise the first
    /// machine there is, otherwise nil.
    private func existingMachineID(preferring preferred: UUID?) -> UUID? {
        let all = allMachines
        if let preferred, all.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return all.first?.id
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey) else {
            adoptLegacyHosts()
            return
        }
        do {
            machines = try JSONDecoder().decode([Machine].self, from: data)
        } catch {
            // The list stays empty, which the UI can't tell apart from "no
            // machines yet" — so the next add/remove would `save()` straight
            // over the only copy of data this build merely failed to read
            // (e.g. written by a newer build). Parking a copy under its own
            // key keeps the store fully usable while leaving that data
            // recoverable instead of gone.
            defaults.set(data, forKey: unreadableDefaultsKey)
        }
    }

    /// One-time carry-over of the list saved under the pre-rename key. The
    /// old JSON has the same shape (`Machine.init(from:)` defaults the
    /// fields added since) and the Keychain tags didn't change, so adopting
    /// it is just a decode.
    ///
    /// Only runs while nothing is stored under `defaultsKey`, and it writes
    /// that key itself — so it happens once, and a list the person later
    /// empties stays empty instead of being repopulated from the old key.
    /// The old key is left untouched so an older build still finds its data.
    /// If it doesn't decode, nothing is written and nothing is lost.
    private func adoptLegacyHosts() {
        guard let data = defaults.data(forKey: legacyDefaultsKey),
              let hosts = try? JSONDecoder().decode([Machine].self, from: data) else { return }
        // The local entry is built in, never stored. One arriving from disk
        // would sit in the list as a second "This Mac" that can't even be
        // removed, since `removeMachine` refuses local entries.
        machines = hosts.filter { !$0.isLocal }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(machines) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func persistActiveID() {
        if let activeMachineID {
            defaults.set(activeMachineID.uuidString, forKey: activeDefaultsKey)
        } else {
            defaults.removeObject(forKey: activeDefaultsKey)
        }
    }
}
