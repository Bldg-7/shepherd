import Foundation
import Observation
import CryptoKit

/// Owns one product hc connection. Replacement first retires the previous
/// screen/streams/connect child, never the core or its programs. No legacy
/// fallback, automatic install, service restart or browser runtime startup.
@MainActor @Observable public final class HcMachineConnection {
    public enum Phase: Equatable { case idle, connecting, connected, failed, missingExecutable, approveHostKey(String) }
    public private(set) var phase: Phase = .idle
    public private(set) var model: HcWorkspaceModel?
    public private(set) var identity: Machine.ConnectionIdentity?
    public private(set) var message: String?
    private var token = UUID()
    private var approval: Machine?
    private var opening: Task<CoreRPCConnection, Error>?
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.bldg-7.shepherd/HcWorkspace", directoryHint: .isDirectory)
    }
    private nonisolated static func load(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1 << 20 else { throw HcWorkspaceModel.Failure.recoveryRequired }
        return try Data(contentsOf: file)
    }
    private nonisolated static func persist(_ data: Data, to file: URL) throws {
        guard data.count <= 1 << 20 else { throw HcWorkspaceModel.Failure.recoveryRequired }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func open(machine: Machine, store: MachineStore, localTransport: (any CoreByteTransport)? = nil) async {
        let generation = UUID(); token = generation; approval = nil; message = nil; phase = .connecting; identity = nil
        let previous = model, pending = opening; model = nil; opening = nil
        pending?.cancel()
        do {
            if let pending, case .success(let rpc) = await pending.result { try await rpc.close() }
            try await previous?.disconnect()
        }
        catch { guard token == generation else { return }; message = "Previous connection cleanup failed. Retry after checking the host."; phase = .failed; return }
        guard token == generation, !Task.isCancelled else { return }
        var connection: CoreRPCConnection?
        do {
            let job = Task { try await store.makeHcConnection(for: machine, localTransport: localTransport) }
            opening = job
            let rpc = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            connection = rpc
            if token == generation { opening = nil }
            guard token == generation, !Task.isCancelled, store.isCurrentConnection(machine), let hello = await rpc.hello else { throw CancellationError() }
            // A changed core or connection identity must not inherit another
            // origin's focus/recovery journal. No raw host/core string in paths.
            var scope = machine; scope.displayName = ""; scope.pinnedHostKeyFingerprint = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let identity = try encoder.encode(scope)
            let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let origin = SHA256.hash(data: Data(hello.core.id.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = directory.appending(path: key, directoryHint: .isDirectory).appending(path: origin, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let recovery = folder.appending(path: "recovery.json"), focus = folder.appending(path: "focus.json")
            let next = HcWorkspaceModel(connection: rpc, savedRecovery: try Self.load(recovery), savedFocus: try Self.load(focus),
                saveRecovery: { try Self.persist($0, to: recovery) }, saveFocus: { try Self.persist($0, to: focus) })
            try await next.start()
            guard token == generation, !Task.isCancelled, store.isCurrentConnection(machine) else { try await next.disconnect(); throw CancellationError() }
            model = next; self.identity = machine.connectionIdentity; phase = .connected
        } catch {
            try? await connection?.close()
            guard token == generation else { return }
            opening = nil
            if case CoreSSHFailure.hostKeyApprovalRequired(let fingerprint) = error {
                approval = machine; phase = .approveHostKey(fingerprint)
                message = "Verify this fingerprint with the host owner before approving. No SSH credential was read or offered."
            } else if case HcConnectionPolicy.Failure.noExecutable = error {
                phase = .missingExecutable; message = "Install hc (herdr-core) for this account, then retry. Existing cores and package-manager installations are never replaced automatically."
            } else {
                phase = .failed; message = hcConnectionFailureDescription(error)
            }
        }
    }
    public func approve(machine: Machine, store: MachineStore) async {
        guard case .approveHostKey(let pin) = phase, let original = approval,
              original.connectionIdentity == machine.connectionIdentity,
              let current = try? store.currentMachine(matching: original), current.pinnedHostKeyFingerprint == nil else { return }
        store.pinHostKeyFingerprint(pin, for: current)
        guard (try? store.currentMachine(matching: current).pinnedHostKeyFingerprint) == pin else { phase = .failed; message = "Host settings changed; reconnect and verify again."; return }
        await open(machine: current, store: store)
    }
    public func close() async {
        token = UUID(); approval = nil; identity = nil
        let previous = model, pending = opening; model = nil; opening = nil
        pending?.cancel()
        do {
            if let pending, case .success(let rpc) = await pending.result { try await rpc.close() }
            try await previous?.disconnect(); phase = .idle
        }
        catch { phase = .failed; message = "Connection cleanup could not be confirmed." }
    }
}
