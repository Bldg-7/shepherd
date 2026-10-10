import Foundation

// Needs our patched local Citadel + swift-nio-ssh packages (see Vendor/), which
// add the direct-streamlocal@openssh.com channel type that upstream swift-nio-ssh
// doesn't support. Guarded with `canImport` so the rest of the app keeps building
// before that's wired up; StubHerdrTransport stands in until then.
#if canImport(Citadel)
import Citadel
import Crypto
import NIOCore
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

enum SSHHerdrTransportError: Error, LocalizedError {
    case notConnected
    case noResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Not connected to herdr yet")
        case .noResponse: String(localized: "herdr.sock closed the connection without responding")
        }
    }
}

/// Talks to herdr by forwarding a direct-streamlocal SSH channel straight onto
/// herdr.sock (the OpenSSH `direct-streamlocal@openssh.com` extension), i.e.
/// the actual documented socket API — not the "hidden" `remote-api-bridge`
/// exec command.
///
/// CONFIRMED LIVE (2026-10-01), with a plain local Unix-socket connection to
/// herdr.sock — no SSH, no our code involved at all: **herdr.sock answers
/// exactly one request per connection and then closes it.** This isn't an
/// artifact of `remote-api-bridge` or of our transport; it's how the server
/// itself behaves, for every method including `events.subscribe` (the
/// subscription ack never even arrives before the connection drops). So:
/// - Every `send()` opens its own fresh direct-streamlocal channel — there's
///   nothing to multiplex, because the server never keeps a connection open
///   for a second request.
/// - A real push-event stream is not achievable client-side at all against
///   this herdr version; AgentBoardView polls `agent.list` instead, and
///   that's the correct approach here, not a stand-in for something better.
///
/// Upstream swift-nio-ssh doesn't support direct-streamlocal at all (its
/// ChannelOpenMessage codec hardcodes session/direct-tcpip/forwarded-tcpip),
/// so this required patching a local copy of swift-nio-ssh and Citadel (see
/// Vendor/) to add the channel type and a `createDirectStreamlocalChannel`
/// API mirroring Citadel's existing `createDirectTCPIPChannel`.
///
/// KNOWN LIMITATIONS (deliberately deferred, not oversights):
/// - Only unencrypted ed25519 and ECDSA (P-256/P-384/P-521) private keys are
///   supported (see OpenSSHPrivateKey.swift) — Citadel doesn't expose a
///   public PEM private key parser, so this is a from-scratch implementation.
///   RSA is explicitly unsupported (see OpenSSHPrivateKey.swift for why).
actor SSHHerdrTransport: HerdrTransport {
    private let host: String
    private let port: Int
    private let username: String
    private let credential: HostCredential
    /// Empty means herdr's own "default" session.
    private let sessionName: String
    private let pinnedFingerprint: String?

    private var client: SSHClient?
    private var socketPath: String?
    private var newlyPinnedFingerprint: String?
    private var nextRequestID = 0

    init(host: String, port: Int, username: String, credential: HostCredential, sessionName: String = "", pinnedFingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.sessionName = sessionName
        self.pinnedFingerprint = pinnedFingerprint
    }

    func connect() async throws {
        let authMethod = try credential.authenticationMethod(username: username)

        let observedFingerprint = NIOLockedValueBox<String?>(nil)
        let validator = TOFUHostKeyValidator(pinnedFingerprint: pinnedFingerprint, observedFingerprint: observedFingerprint)

        let settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .custom(validator)
        )
        let client = try await SSHClient.connect(to: settings)
        self.client = client

        if pinnedFingerprint == nil {
            newlyPinnedFingerprint = observedFingerprint.withLockedValue { $0 }
        }

        let home = try await resolveRemoteHome(client)
        socketPath = sessionName.isEmpty
            ? "\(home)/.config/herdr/herdr.sock"
            : "\(home)/.config/herdr/sessions/\(sessionName)/herdr.sock"
    }

    private func resolveRemoteHome(_ client: SSHClient) async throws -> String {
        let output = try await client.executeCommand("echo $HOME")
        return String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func disconnect() async {
        try? await client?.close()
        client = nil
        socketPath = nil
    }

    func newlyPinnedHostKeyFingerprint() async -> String? {
        newlyPinnedFingerprint
    }

    func send(method: String, params: JSONValue) async throws -> JSONValue {
        guard let client, let socketPath else { throw SSHHerdrTransportError.notConnected }
        let id = "req_\(nextRequestID)"
        nextRequestID += 1
        let request = HerdrRequest(id: id, method: method, params: params)
        let line = try request.encodedLine()

        var result: Result<JSONValue, Error>?
        var inboundContinuation: AsyncStream<ByteBuffer>.Continuation!
        let inboundStream = AsyncStream<ByteBuffer> { inboundContinuation = $0 }

        let channel = try await client.createDirectStreamlocalChannel(
            using: .init(socketPath: socketPath)
        ) { channel in
            channel.pipeline.addHandler(ByteStreamBridge(continuation: inboundContinuation))
        }

        try await channel.writeAndFlush(ByteBuffer(bytes: line)).get()

        var pending: [UInt8] = []
        for await buffer in inboundStream {
            pending.append(contentsOf: buffer.readableBytesView)
            guard let newlineIndex = pending.firstIndex(of: 0x0A) else { continue }
            let lineData = Data(pending[..<newlineIndex])
            if let response = try? JSONDecoder().decode(HerdrResponse.self, from: lineData) {
                result = response.error.map(Result.failure) ?? .success(response.result ?? .null)
            }
            break // herdr.sock answers exactly one request per connection
        }

        try? await channel.close()
        guard let result else { throw SSHHerdrTransportError.noResponse }
        return try result.get()
    }

    /// Runs the herdr CLI on the remote host over this connection, found
    /// the same way an attach finds it (`HerdrExecutable.remoteCommand`).
    func runHerdr(_ arguments: [String]) async throws -> Data {
        let command = HerdrExecutable.remoteCommand(arguments: arguments.map(shellQuoted).joined(separator: " "))
        return try await run(command) { status, stderr in
            HerdrCommandError(status: status, message: stderr)
        }
    }

    /// In `sh -c`, so that the script means the same whatever the account's
    /// login shell is (see `HerdrExecutable.remoteCommand`).
    func runScript(_ script: String) async throws -> Data {
        try await run("sh -c \(shellQuoted(script))") { status, stderr in
            HostScriptError(status: status, message: stderr)
        }
    }

    /// Runs `command` in the remote account's login shell and returns its
    /// stdout, or throws what `failure` makes of its exit status and stderr.
    /// The two are kept apart: the result is parsed from stdout, and stderr
    /// is where a command explains a failure.
    private func run(_ command: String, failure: (_ status: Int, _ stderr: String) -> any Error) async throws -> Data {
        guard let client else { throw SSHHerdrTransportError.notConnected }
        var stdout = Data()
        var stderr = Data()
        do {
            for try await chunk in try await client.executeCommandStream(command) {
                switch chunk {
                case .stdout(let buffer): stdout.append(contentsOf: buffer.readableBytesView)
                case .stderr(let buffer): stderr.append(contentsOf: buffer.readableBytesView)
                }
            }
        } catch let commandFailure as SSHClient.CommandFailed {
            throw failure(commandFailure.exitCode, String(decoding: stderr, as: UTF8.self))
        }
        return stdout
    }

    func events() -> AsyncStream<JSONValue> {
        // herdr.sock closes every connection after a single response — even
        // the events.subscribe ack never arrives before the connection drops
        // (confirmed live, no SSH or our code involved: a plain local socket
        // connection behaves identically). There is no server-side support
        // for a push stream to receive here; AgentBoardView polls agent.list
        // instead, which is the correct approach against this herdr version,
        // not a stand-in for something better.
        AsyncStream { $0.finish() }
    }
}

/// Forwards raw inbound bytes from a NIO channel into a Swift AsyncStream.
private final class ByteStreamBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<ByteBuffer>.Continuation

    nonisolated init(continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(self.unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }
}
#endif
