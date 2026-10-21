import Foundation

/// What the device says about itself in its request, besides the name the
/// person gives it there.
nonisolated struct PairingDeviceInfo: Equatable, Sendable {
    /// This installation of the app: the same for every Mac it pairs with,
    /// so that a Mac can tell the device again in its list.
    var id: UUID
    /// "iPhone" or "iPad"; the Mac shows an iPad's icon for the latter.
    var model: String
    /// "0.1.0 (2)".
    var appVersion: String
}

/// How a connection to a paired Mac went: whether SSH logged in with the
/// device's key, and whether herdr answered over it.
nonisolated struct PairingConnectionCheck: Equatable, Sendable {
    /// What the Mac is told of a failure at most, in characters: it shows
    /// the text as it is.
    static let maximumReportedFailure = 200

    var sshConnected: Bool
    var herdrReached: Bool
    /// What went wrong, in the words the person reads.
    var failure: String?
    /// SSH failed because the Mac turned the device's key down.
    var keyRefused = false

    init(sshConnected: Bool, herdrReached: Bool, failure: String? = nil, keyRefused: Bool = false) {
        self.sshConnected = sshConnected
        self.herdrReached = herdrReached
        self.failure = failure
        self.keyRefused = keyRefused
    }

    var succeeded: Bool { sshConnected && herdrReached }

    /// The report the Mac shows when the pairing ends (M3).
    var report: PairingReport {
        PairingReport(sshConnected: sshConnected, herdrReached: herdrReached,
                      failure: failure.map { String($0.prefix(Self.maximumReportedFailure)) })
    }
}

/// Logs in to a paired Mac at the IPv4 address its QR code's address
/// resolved to, and asks its herdr something: right after a pairing, and
/// before a Mac is moved to a new address. `SSHPairedMacChecker` in the app;
/// a stand-in in the tests, which never connect over SSH.
protocol PairedMacChecking {
    func check(_ machine: Machine, credential: Data, at address: PairingIPv4) async -> PairingConnectionCheck
}

/// What an earlier pairing makes of a scanned code (SHPHRD-77, "같은 Mac의
/// QR을 다시 스캔할 때"). The Mac's installation ID in the code is the
/// machine's ID, but it is no secret — anyone who saw a code has it — so it
/// alone never changes a machine: the host key must be the one pinned.
enum PairingScanMatch: Equatable {
    /// No machine has the code's Mac ID: a new pairing.
    case new
    /// A machine has the Mac ID, but not the code's host key — or it isn't a
    /// Mac paired by QR code at all. Nothing is changed: a reinstalled Mac
    /// is removed and paired again.
    case differentHostKey(Machine)
    /// The same Mac at the same address.
    case sameAddress(Machine)
    /// The same Mac at another address, which the device may move it to.
    case newAddress(Machine)

    static func match(_ payload: PairingPayload, in machines: [Machine]) -> PairingScanMatch {
        guard let existing = machines.first(where: { $0.id == payload.macID }) else { return .new }
        guard existing.authMethod == .secureEnclaveKey, existing.addressKind != nil,
              existing.pinnedHostKeyFingerprint == payload.hostKey.fingerprint else {
            return .differentHostKey(existing)
        }
        if existing.addressKind == payload.address.kind && existing.hostname == payload.address.hostname {
            return .sameAddress(existing)
        }
        return .newAddress(existing)
    }
}

enum PairingProgress: Equatable {
    /// Looking the address up, making the key, connecting.
    case connecting
    /// The request is sent; the Mac shows the same code and asks its owner.
    case waitingForApproval(PairingConfirmationCode)
    /// Approved and saved: logging in to the Mac for the first time.
    case checkingConnection(Machine)
}

struct PairedMac: Equatable {
    let machine: Machine
    let check: PairingConnectionCheck
}

/// The device's side of pairing with a Mac by its QR code (SHPHRD-77,
/// "단계 C"): the code's address looked up once and held to its kind's
/// range, the request over a TCP connection to that IPv4 address and the
/// listener's port, the Mac's answer, the machine and its key saved once
/// approved, the first SSH connection to the same address with the host key
/// the code pinned, and the report of it to the Mac. Also moves a paired Mac
/// to the address a later code of it gives.
///
/// The device key is made for the request and kept in memory until the Mac
/// approves it. A Secure Enclave key is nothing but the blob the app keeps
/// of it, so a key that is never saved — the Mac turned it down, the code
/// had expired or was used, nothing answered — is gone with the attempt.
/// Once approved, the machine and its key stay even if the first
/// connection fails: the Mac has let the key in.
struct PairingClient {
    /// How long the Mac's answer is waited for once the request is sent.
    /// The Mac turns a request down after a minute without an answer, and
    /// after two while its Touch ID or password prompt is up, then says so:
    /// the device waits longer than either.
    nonisolated static let responseTimeout: Duration = .seconds(150)
    /// A connection the Mac closes within this long of the request, with no
    /// answer, is tried again: the Mac closes one that comes while another
    /// is still to send its request. One closed later is not — the request
    /// may have reached the Mac, and sending it again would only be told
    /// the code was used.
    nonisolated static let quickClose: Duration = .seconds(5)

    var resolver: PairingAddressResolver
    var dialer: any PairingDialing
    var makeDeviceKey: () throws -> SecureEnclaveSSHKey
    var checker: any PairedMacChecking
    var responseTimeout: Duration = PairingClient.responseTimeout
    /// Connections tried for one request, in all.
    var attempts = 5
    var retryDelay: Duration = .seconds(1)
    /// How long sending the report to the Mac may take.
    var reportTimeout: Duration = .seconds(5)

    init(resolver: PairingAddressResolver, dialer: any PairingDialing, makeDeviceKey: @escaping () throws -> SecureEnclaveSSHKey,
         checker: any PairedMacChecking) {
        self.resolver = resolver
        self.dialer = dialer
        self.makeDeviceKey = makeDeviceKey
        self.checker = checker
    }

    // MARK: - A new pairing

    func pair(_ payload: PairingPayload, device: PairingDeviceInfo, deviceName: String, store: MachineStore,
              progress: (PairingProgress) -> Void) async throws -> PairedMac {
        progress(.connecting)
        let address = try await resolver.resolve(payload.address)
        try Task.checkCancellation()
        let key = try makeDeviceKey()
        var channel = try PairingDeviceChannel(payload: payload)
        let request = try channel.request(PairingRequest(deviceID: device.id, deviceName: deviceName, deviceModel: device.model,
                                                         appVersion: device.appVersion, publicKey: key.publicKeyBlob))
        let (link, response) = try await exchange(request, channel: channel, at: address, port: payload.pairingPort,
                                                  host: payload.address.hostname, progress: progress)
        defer { link.close() }
        guard response.decision == .approved else { throw PairingClientError.rejected }
        guard response.macID == payload.macID else {
            await report(PairingConnectionCheck(sshConnected: false, herdrReached: false,
                                                failure: String(localized: "The Mac's answer didn't match its QR code.")),
                         channel: &channel, on: link)
            throw PairingClientError.unreadableAnswer
        }

        let machine = payload.machine()
        if store.machines.contains(where: { $0.id == machine.id }) {
            await report(PairingConnectionCheck(sshConnected: false, herdrReached: false,
                                                failure: String(localized: "This Mac is already on the device.")),
                         channel: &channel, on: link)
            throw PairingClientError.alreadyAdded(machine.displayName)
        }
        do {
            try store.addMachine(machine, privateKey: key.storedRepresentation)
        } catch {
            await report(PairingConnectionCheck(sshConnected: false, herdrReached: false,
                                                failure: String(localized: "The device couldn't save its key.")),
                         channel: &channel, on: link)
            throw PairingClientError.couldNotSave(error.localizedDescription)
        }

        progress(.checkingConnection(machine))
        let check = await checker.check(machine, credential: key.storedRepresentation, at: address)
        await report(check, channel: &channel, on: link)
        return PairedMac(machine: machine, check: check)
    }

    /// Sends the request and returns the Mac's answer with the connection it
    /// came on, still open for the report.
    private func exchange(_ request: Data, channel: PairingDeviceChannel, at address: PairingIPv4, port: UInt16, host: String,
                          progress: (PairingProgress) -> Void) async throws -> (any PairingLink, PairingResponse) {
        var showsCode = false
        var problem = PairingClientError.closedWithoutAnswer
        for attempt in 1...max(1, attempts) {
            if attempt > 1 { try await Task.sleep(for: retryDelay) }
            let link: any PairingLink
            do {
                link = try await dialer.open(address, port: port)
            } catch let error as PairingLinkError {
                problem = Self.problem(connecting: error, host: host)
                if error.isWorthRetrying { continue }
                throw problem
            }
            do {
                try await link.send(request)
            } catch let error as PairingLinkError {
                link.close()
                problem = error.isWorthRetrying ? .closedWithoutAnswer : Self.problem(connecting: error, host: host)
                if error.isWorthRetrying { continue }
                throw problem
            } catch {
                link.close()
                throw error
            }
            if !showsCode {
                showsCode = true
                progress(.waitingForApproval(channel.confirmationCode))
            }
            let sent = ContinuousClock.now
            let frame: Data?
            do {
                frame = try await nextFrame(on: link)
            } catch {
                link.close()
                throw error
            }
            guard let frame else {
                link.close()
                problem = .closedWithoutAnswer
                if ContinuousClock.now - sent < Self.quickClose { continue }
                throw problem
            }
            do {
                return (link, try channel.openResponse(PairingEnvelope(body: frame)))
            } catch PairingProtocolError.failed(let failure) {
                link.close()
                throw PairingClientError.failed(failure)
            } catch {
                link.close()
                throw PairingClientError.unreadableAnswer
            }
        }
        throw problem
    }

    /// The first frame the Mac sends; nil when the connection ends first.
    private func nextFrame(on link: any PairingLink) async throws -> Data? {
        let deadline = Deadline()
        let timeout = responseTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            deadline.passed = true
            link.close()
        }
        defer { timer.cancel() }
        var reader = PairingFrameReader()
        while true {
            let bytes: Data?
            do {
                bytes = try await link.receive()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                bytes = nil
            }
            guard let bytes else {
                if deadline.passed { throw PairingClientError.noAnswer }
                return nil
            }
            let frames: [Data]
            do {
                frames = try reader.append(bytes)
            } catch {
                throw PairingClientError.unreadableAnswer
            }
            if let first = frames.first { return first }
        }
    }

    /// Tells the Mac how the first connection went (M3), if it can within
    /// `reportTimeout`.
    private func report(_ check: PairingConnectionCheck, channel: inout PairingDeviceChannel, on link: any PairingLink) async {
        guard let message = try? channel.report(check.report) else { return }
        let timeout = reportTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { link.close() }
        }
        _ = try? await link.send(message)
        timer.cancel()
    }

    private static func problem(connecting error: PairingLinkError, host: String) -> PairingClientError {
        error == .localNetworkDenied ? .localNetworkDenied : .couldNotConnect(host: host, reason: error.reason)
    }

    private final class Deadline {
        var passed = false
    }

    // MARK: - A known Mac at a new address

    /// Moves `machine` to the code's address, once a connection there has
    /// logged in with the key the device already has and the host key it
    /// already pinned, and herdr has answered. The Mac isn't asked: nothing
    /// new is let in. Nothing changes when the connection fails.
    func moveAddress(of machine: Machine, to payload: PairingPayload, store: MachineStore) async throws -> Machine {
        let address = try await resolver.resolve(payload.address)
        try Task.checkCancellation()
        guard let credential = try store.secret(for: machine) else { throw MachineStore.EditError.missingCredential }
        var moved = machine
        moved.hostname = payload.address.hostname
        moved.addressKind = payload.address.kind
        let check = await checker.check(moved, credential: credential, at: address)
        guard check.succeeded else {
            throw PairingClientError.newAddressFailed(check.failure ?? String(localized: "The connection failed"))
        }
        try Task.checkCancellation()
        try store.updatePairedAddress(of: machine, hostname: payload.address.hostname, addressKind: payload.address.kind)
        return store.machines.first(where: { $0.id == machine.id }) ?? moved
    }
}

enum PairingClientError: Error, Equatable, LocalizedError {
    /// The Mac's owner turned the request down, or didn't answer in time.
    case rejected
    /// The Mac ended the attempt without an encrypted answer.
    case failed(PairingFailure)
    /// No answer within `PairingClient.responseTimeout`.
    case noAnswer
    /// The Mac closed the connection without answering.
    case closedWithoutAnswer
    case couldNotConnect(host: String, reason: String)
    case localNetworkDenied
    case unreadableAnswer
    /// A machine with the Mac's ID was added meanwhile.
    case alreadyAdded(String)
    /// Approved, but the key couldn't be saved on the device.
    case couldNotSave(String)
    /// The connection to the Mac's new address failed; nothing was changed.
    case newAddressFailed(String)

    var errorDescription: String? {
        switch self {
        case .rejected:
            String(localized: "The Mac turned the request down, or no one answered it in time.")
        case .failed(let failure):
            PairingProtocolError.failed(failure).errorDescription
        case .noAnswer:
            String(localized: "The Mac didn't answer in time. Show a new QR code on the Mac and scan it again.")
        case .closedWithoutAnswer:
            String(localized: "The Mac closed the connection without answering. Check that the Mac still shows the QR code and that this device is on the network the code is for.")
        case .couldNotConnect(let host, let reason):
            String(localized: "Couldn't connect to the Mac at \(host): \(reason). Check that the Mac still shows the QR code and that this device is on the network the code is for.")
        case .localNetworkDenied:
            String(localized: "hrdrhrdrhrdr isn't allowed to use the local network. Turn on Local Network for hrdrhrdrhrdr in Settings, then scan again.")
        case .unreadableAnswer:
            String(localized: "The Mac's answer couldn't be read.")
        case .alreadyAdded(let name):
            String(localized: "\(name) is already in Machines.")
        case .couldNotSave(let reason):
            String(localized: "The Mac let this device in, but the device couldn't save its key: \(reason)")
        case .newAddressFailed(let reason):
            String(localized: "Couldn't connect to the Mac at its new address, so its address wasn't changed: \(reason)")
        }
    }
}

/// For a name the device has already looked up: the address it got,
/// whatever the name. The first connection after a pairing goes to the
/// address the pairing went to, without a second lookup.
nonisolated struct ResolvedPairingName: PairingNameResolving {
    let address: PairingIPv4

    func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        [address]
    }
}
