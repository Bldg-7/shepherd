// TEST ONLY: a stand-in for the Citadel API the drop uploader uses. No
// sockets or network: a "connection" is a record, and an exec channel runs its
// command with /bin/sh on this Mac, under the test's host HOME and PATH (where
// the fake ssh is), as the host's login shell would.
import Foundation
import NIOCore

public struct OwnedAuth: Sendable { public init() {} }
public protocol OwnedValidator: Sendable { var pinnedFingerprint: String? { get } }
public enum SSHHostKeyValidator: Sendable { case custom(any OwnedValidator) }
public struct OwnedTime: Sendable { public static func seconds(_ n: Int) -> Self { .init() } }
public struct SSHClientSettings: Sendable {
    public let host: String
    public let port: Int
    public let authenticationMethod: @Sendable () -> OwnedAuth
    public let hostKeyValidator: SSHHostKeyValidator
    public var connectTimeout = OwnedTime.seconds(30)
    public init(host: String, port: Int, authenticationMethod: @escaping @Sendable () -> OwnedAuth, hostKeyValidator: SSHHostKeyValidator) {
        self.host = host; self.port = port; self.authenticationMethod = authenticationMethod; self.hostKeyValidator = hostKeyValidator
    }
}

public enum ExecCommandOutput: Sendable {
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
}

public struct TTYOutput: AsyncSequence, Sendable {
    public typealias Element = ExecCommandOutput
    let stream: AsyncThrowingStream<ExecCommandOutput, Error>
    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<ExecCommandOutput, Error>.AsyncIterator
        public mutating func next() async throws -> ExecCommandOutput? { try await iterator.next() }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(iterator: stream.makeAsyncIterator()) }
}

public enum FakeChannelError: Error { case alreadyClosed, connectionClosed, connectRefused }

public struct TTYStdinWriter: Sendable {
    let channel: FakeChannel
    public func write(_ buffer: ByteBuffer) async throws { try await channel.write(buffer.readableBytesView) }
    public func finish() async throws { try await channel.finish() }
}

/// One exec: the process, and its standard input.
public actor FakeChannel {
    let input: FileHandle
    var inputOpen = true
    var written = 0
    var held: CheckedContinuation<Void, Error>?
    var closed = false
    init(input: FileHandle) { self.input = input }

    func write(_ bytes: [UInt8]) async throws {
        guard !closed, inputOpen else { throw FakeChannelError.connectionClosed }
        await FakeSSH.shared.wrote(bytes.count)
        if let holdAfter = await FakeSSH.shared.holdAfter, written >= holdAfter {
            // A window that never opens: the write waits until the
            // connection is closed under it.
            await FakeSSH.shared.setWaitingWrite(true)
            try await withCheckedThrowingContinuation { held = $0 }
        }
        try input.write(contentsOf: bytes)
        written += bytes.count
    }

    func finish() throws {
        guard !closed else { throw FakeChannelError.connectionClosed }
        endInput()
    }

    /// The connection went: the far end reads EOF, as sshd's child does when
    /// its channel is closed, and a held write fails.
    func close() {
        closed = true
        endInput()
        held?.resume(throwing: FakeChannelError.connectionClosed); held = nil
    }

    private func endInput() {
        guard inputOpen else { return }
        inputOpen = false
        try? input.close()
    }
}

public actor FakeSSH {
    public static let shared = FakeSSH()
    public var hostHome = ""
    public var path = "/usr/bin:/bin"
    /// Run instead of what the uploader asked for, when set.
    public var override: String?
    /// Run before what the uploader asked for: a login shell's startup noise.
    public var prefix = ""
    public var holdAfter: Int?
    public var refuseConnect = false
    public private(set) var waitingWrite = false
    public private(set) var connects = 0
    public private(set) var closes = 0
    public private(set) var hosts: [String] = []
    public private(set) var pins: [String?] = []
    public private(set) var commands: [String] = []
    public private(set) var writes: [Int] = []
    var channels: [FakeChannel] = []

    public func configure(hostHome: String, path: String) { self.hostHome = hostHome; self.path = path }
    public func set(override: String?, prefix: String = "", holdAfter: Int? = nil, refuseConnect: Bool = false) {
        self.override = override; self.prefix = prefix; self.holdAfter = holdAfter; self.refuseConnect = refuseConnect
        waitingWrite = false; writes = []
    }
    func setWaitingWrite(_ value: Bool) { waitingWrite = value }
    func wrote(_ count: Int) { writes.append(count) }
    func connect(_ settings: SSHClientSettings) throws {
        connects += 1; hosts.append(settings.host)
        if case .custom(let validator) = settings.hostKeyValidator { pins.append(validator.pinnedFingerprint) }
        if refuseConnect { throw FakeChannelError.connectRefused }
    }
    func closeAll() async {
        closes += 1
        for channel in channels { await channel.close() }
        channels = []
    }
    func open(_ command: String) -> (line: String, home: String, path: String) {
        commands.append(command)
        return (prefix + (override ?? command), hostHome, path)
    }
    func add(_ channel: FakeChannel) { channels.append(channel) }
}

public final class SSHClient: @unchecked Sendable {
    public struct CommandFailed: Error { public let exitCode: Int }
    private let lock = NSLock()
    private var isClosed = false

    public static func connect(to settings: SSHClientSettings) async throws -> SSHClient {
        try await FakeSSH.shared.connect(settings)
        return SSHClient()
    }

    public func close() async throws {
        lock.withLock { isClosed = true }
        await FakeSSH.shared.closeAll()
    }

    public func withExec(_ command: String, perform: (_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void) async throws {
        guard !lock.withLock({ isClosed }) else { throw FakeChannelError.connectionClosed }
        let (line, home, path) = await FakeSSH.shared.open(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.environment = ["HOME": home, "PATH": path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let (stream, continuation) = AsyncThrowingStream<ExecCommandOutput, Error>.makeStream()
        try process.run()
        let channel = FakeChannel(input: input.fileHandleForWriting)
        await FakeSSH.shared.add(channel)
        // Both outputs read to their end, then the exit status: what the
        // channel delivers before it closes.
        let readers = DispatchGroup()
        for (handle, isError) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            readers.enter()
            DispatchQueue.global().async {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    let buffer = ByteBuffer(bytes: data)
                    continuation.yield(isError ? .stderr(buffer) : .stdout(buffer))
                }
                readers.leave()
            }
        }
        readers.notify(queue: .global()) {
            process.waitUntilExit()
            let status = Int(process.terminationStatus)
            if status == 0 { continuation.finish() } else { continuation.finish(throwing: CommandFailed(exitCode: status)) }
        }
        do {
            try await perform(TTYOutput(stream: stream), TTYStdinWriter(channel: channel))
        } catch {
            await channel.close()
            while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
            throw error
        }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        // As Citadel's `withExec` does: closing a channel the far end has
        // already closed fails.
        throw FakeChannelError.alreadyClosed
    }
}
