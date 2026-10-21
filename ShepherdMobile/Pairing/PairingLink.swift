import Foundation
import Network

/// A TCP connection to a Mac's pairing listener (SHPHRD-77, "기기→Mac
/// 경로"): bytes out, bytes in, and an end.
nonisolated protocol PairingLink: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next bytes that arrive, or nil once the Mac has closed the
    /// connection — whether it ended it or reset it.
    func receive() async throws -> Data?
    /// Ends the connection; a `send` or `receive` waiting on it ends too.
    func close()
}

/// Connects to an IPv4 address: the one the QR code's address resolved to,
/// never a name, so that what is connected to is what was checked.
nonisolated protocol PairingDialing: Sendable {
    func open(_ address: PairingIPv4, port: UInt16) async throws -> any PairingLink
}

/// Why a connection couldn't be made or ended early, without the Network
/// framework's types.
nonisolated enum PairingLinkError: Error, Equatable {
    /// Nothing listens on the port: the Mac isn't showing a code.
    case refused
    /// The connection was closed or reset.
    case closed
    case timedOut
    /// iOS's Local Network permission is off for the app, or still being
    /// asked for when the time ran out.
    case localNetworkDenied
    /// Another socket error, by its POSIX code; 0 when it had none.
    case failed(Int32)

    /// Worth another try a moment later: the Mac closes a connection that
    /// comes while another one is still to send its request, and the
    /// listener may be between codes.
    var isWorthRetrying: Bool {
        switch self {
        case .refused, .closed: true
        case .timedOut, .localNetworkDenied, .failed: false
        }
    }

    var reason: String {
        switch self {
        case .refused: systemErrorDescription(ECONNREFUSED)
        case .closed: systemErrorDescription(ECONNRESET)
        case .timedOut: systemErrorDescription(ETIMEDOUT)
        case .localNetworkDenied: String(localized: "Local Network access is off")
        case .failed(let code): code == 0 ? String(localized: "The connection failed") : systemErrorDescription(code)
        }
    }

    init(_ error: NWError) {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: self = .refused
            case .ECONNRESET, .ENOTCONN, .EPIPE, .ECONNABORTED, .ECANCELED: self = .closed
            case .ETIMEDOUT: self = .timedOut
            default: self = .failed(code.rawValue)
            }
        case .dns(let code) where code == -65570:
            // kDNSServiceErr_PolicyDenied: the Local Network permission.
            self = .localNetworkDenied
        default:
            self = .failed(0)
        }
    }
}

/// `PairingDialing` with Network framework connections.
nonisolated struct NetworkPairingDialer: PairingDialing {
    /// How long a connection may take, the Local Network permission prompt
    /// included: iOS asks the first time the app reaches the local network,
    /// and the connection waits while it is up.
    var connectTimeout: Duration = .seconds(30)

    init(connectTimeout: Duration = .seconds(30)) {
        self.connectTimeout = connectTimeout
    }

    func open(_ address: PairingIPv4, port: UInt16) async throws -> any PairingLink {
        let link = NetworkPairingLink(address: address, port: port)
        try await link.start(timeout: connectTimeout)
        return link
    }
}

/// One `NWConnection`, its state kept on its own queue.
nonisolated final class NetworkPairingLink: PairingLink, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PairingLink")
    private var starting: CheckedContinuation<Void, any Error>?
    private var waitsForLocalNetwork = false
    private var started = false

    init(address: PairingIPv4, port: UInt16) {
        let parameters = NWParameters.tcp
        // An address, not a name: nothing to look up, and no proxy between.
        parameters.preferNoProxies = true
        connection = NWConnection(host: .ipv4(IPv4Address(Data(address.bytes))!),
                                  port: NWEndpoint.Port(rawValue: port) ?? .any, using: parameters)
    }

    func start(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    guard !started else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    started = true
                    starting = continuation
                    connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                    connection.start(queue: queue)
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.timedOut() }
                }
            }
        } onCancel: {
            queue.async { [self] in
                started = true
                finishStarting(CancellationError())
                connection.cancel()
            }
        }
    }

    /// On `queue`.
    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishStarting(nil)
        case .waiting(let error):
            // While iOS asks for the Local Network permission, or once it
            // has been turned down, the connection waits; it goes on by
            // itself if the person allows it before the time runs out.
            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied || PairingLinkError(error) == .localNetworkDenied {
                waitsForLocalNetwork = true
                return
            }
            finishStarting(PairingLinkError(error))
            connection.cancel()
        case .failed(let error):
            finishStarting(PairingLinkError(error))
            connection.cancel()
        case .cancelled:
            finishStarting(PairingLinkError.closed)
        default:
            break
        }
    }

    /// On `queue`.
    private func timedOut() {
        guard starting != nil else { return }
        finishStarting(waitsForLocalNetwork ? PairingLinkError.localNetworkDenied : PairingLinkError.timedOut)
        connection.cancel()
    }

    /// On `queue`.
    private func finishStarting(_ error: (any Error)?) {
        guard let continuation = starting else { return }
        starting = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: PairingLinkError(error))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            close()
        }
        try Task.checkCancellation()
    }

    func receive() async throws -> Data? {
        let received = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        let reason = PairingLinkError(error)
                        if reason == .closed {
                            continuation.resume(returning: nil)
                        } else {
                            continuation.resume(throwing: reason)
                        }
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            close()
        }
        try Task.checkCancellation()
        return received
    }

    func close() {
        connection.cancel()
    }
}
