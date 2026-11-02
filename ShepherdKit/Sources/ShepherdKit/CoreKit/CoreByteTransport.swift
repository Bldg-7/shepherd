import Foundation

/// One owned, single-use byte connection. No PTY and no implicit reconnect.
/// Exactly one reader; write calls must preserve whole-buffer ordering.
/// Implementations bound their own writer queues and keep stderr out of stdout.
/// Canceling a transport operation retires the connection (a partial frame
/// cannot be retried); canceling an RPC must NOT cancel a transport write.
public protocol CoreByteTransport: Sendable {
    func start() async throws
    func read() async throws -> Data?
    func write(_ bytes: Data) async throws
    /// Returns only after owned resources retire. A cleanup failure must be
    /// reported rather than being mistaken for a successful disconnect.
    func close() async throws
}

public nonisolated enum CoreConnectionFailure: Error, Equatable, Sendable {
    case alreadyStarted, notReady, closed, handshakeTimedOut, requestTimedOut
    case invalidTimeout, writeLimitExceeded, methodUnavailable, streamingNotSupported
    case reservedMethod, transportFailed
}

public nonisolated enum CoreProcessFailure: Error, Equatable, Sendable {
    case invalidConfiguration, alreadyStarted, notStarted, closed, concurrentRead
    case writeLimitExceeded, supervisionLost
    case system(Int32)
}
