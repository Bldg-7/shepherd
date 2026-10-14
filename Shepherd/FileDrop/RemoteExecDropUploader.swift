import Foundation

// Needs the patched local Citadel for `TTYStdinWriter.finish()` (see
// Vendor/), which ends the standard input of a command run with `withExec`.
#if canImport(Citadel)
import Darwin
import Citadel
import NIOCore
import NIOConcurrencyHelpers

/// Uploads to a pane over SSH to the host: on a connection of its own,
/// never a terminal's, opened for one drop and closed with `close()`. Each
/// file is one exec channel running `TerminalDropPaste.receiveScript` — on
/// the host for a pane of the host's own herdr, or, for a pane on one of the
/// host's herdr machines, through the host's `ssh` to it, the way the
/// attach goes there. The file's bytes are written to the channel and ended
/// with an EOF; on the way to a machine the host only passes them through.
///
/// Only to a host whose key is pinned (it is checked by the terminal's
/// connect first): `init` takes the pin, not an optional one.
actor RemoteExecDropUploader: TerminalDropUploading {
    /// What is kept of the end of each of stdout and stderr: the receipt
    /// and ssh's error are both last lines.
    nonisolated static let outputLimit = 8 * 1024
    nonisolated static let chunkSize = 32 * 1024

    private let host: String
    private let port: Int
    private let username: String
    private let credential: HostCredential
    private let pinnedFingerprint: String
    /// The herdr machine the pane is on, or nil for the host's own herdr.
    private let herdrMachine: HerdrMachine?
    private var client: SSHClient?
    /// Set by `close()` and never cleared, so that a connect still under
    /// way then is closed as soon as it is made.
    private var closed = false

    init(host: String, port: Int, username: String, credential: HostCredential, pinnedFingerprint: String, on herdrMachine: HerdrMachine? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.pinnedFingerprint = pinnedFingerprint
        self.herdrMachine = herdrMachine
    }

    func upload(_ file: TerminalDropFile, batch: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let receive = TerminalDropPaste.receiveCommand(batch: batch, name: file.remoteName, size: file.size)
        let command: String
        if let herdrMachine {
            guard TerminalDropPaste.isUsableTarget(herdrMachine.target) else { throw TerminalDropError.unusableTarget }
            command = TerminalDropPaste.hostCommand(target: herdrMachine.target, receive: receive)
        } else {
            command = receive
        }
        let client = try await connection()
        // Closing the connection is what stops a write that is waiting on
        // the far end, and ends the command there with an EOF.
        return try await withTaskCancellationHandler {
            try await Self.send(file, running: command, over: client, batch: batch, progress: progress)
        } onCancel: {
            Task { await self.close() }
        }
    }

    func close() async {
        closed = true
        let client = client
        self.client = nil
        try? await client?.close()
    }

    private func connection() async throws -> SSHClient {
        if let client { return client }
        guard !closed else { throw CancellationError() }
        let authMethod = try credential.authenticationMethod(username: username)
        let validator = TOFUHostKeyValidator(pinnedFingerprint: pinnedFingerprint, observedFingerprint: NIOLockedValueBox<String?>(nil))
        var settings = SSHClientSettings(host: host, port: port, authenticationMethod: { authMethod },
                                         hostKeyValidator: .custom(validator))
        settings.connectTimeout = .seconds(10)
        let client = try await SSHClient.connect(to: settings)
        // `close()` had nothing to close while this was being made.
        guard !closed, !Task.isCancelled else {
            try? await client.close()
            throw CancellationError()
        }
        self.client = client
        return client
    }

    /// One file over one exec channel. Not isolated to the actor: the
    /// channel's closure only touches what is local to this call.
    private nonisolated static func send(
        _ file: TerminalDropFile, running command: String, over client: SSHClient,
        batch: String, progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> String {
        var stdout: [UInt8] = []
        var stderr: [UInt8] = []
        var exitStatus = 0
        var sendFailure: (any Error)?
        var ended = false
        do {
            try await client.withExec(command) { inbound, outbound in
                do {
                    var offset: Int64 = 0
                    var chunk = [UInt8](repeating: 0, count: chunkSize)
                    while offset < file.size {
                        try Task.checkCancellation()
                        let count = pread(file.descriptor, &chunk, min(chunk.count, Int(file.size - offset)), off_t(offset))
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw TerminalDropError.unreadable(errno)
                        }
                        // A file that shrank since it was opened: the far
                        // end finds it short and says so.
                        if count == 0 { break }
                        try await outbound.write(ByteBuffer(bytes: chunk[..<count]))
                        offset += Int64(count)
                        progress(offset)
                    }
                    try await outbound.finish()
                } catch let error as TerminalDropError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The far end may have ended early and closed its side;
                    // its exit status says why better than this does.
                    sendFailure = error
                }
                do {
                    for try await event in inbound {
                        switch event {
                        case .stdout(let buffer): append(buffer, to: &stdout)
                        case .stderr(let buffer): append(buffer, to: &stderr)
                        }
                    }
                } catch let failed as SSHClient.CommandFailed {
                    exitStatus = failed.exitCode
                }
                ended = true
            }
        } catch {
            // `withExec` closes the channel on its way out, which fails when
            // the far end has closed it first — the usual end of a command.
            guard ended else { throw error }
        }
        if exitStatus != 0 {
            throw TerminalDropError.failed(status: exitStatus, detail: TerminalDropPaste.lastLine(of: String(decoding: stderr, as: UTF8.self)))
        }
        if let path = TerminalDropPaste.receivedPath(in: String(decoding: stdout, as: UTF8.self), batch: batch, name: file.remoteName) {
            return path
        }
        throw sendFailure ?? TerminalDropError.unconfirmed
    }

    private nonisolated static func append(_ buffer: ByteBuffer, to output: inout [UInt8]) {
        output.append(contentsOf: buffer.readableBytesView)
        if output.count > outputLimit { output.removeFirst(output.count - outputLimit) }
    }
}
#endif
