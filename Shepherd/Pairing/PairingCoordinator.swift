#if os(macOS)
import CryptoKit
import Foundation
import Observation

/// The Add iPhone or iPad page's state and everything it does (SHPHRD-77):
/// the checks before a code is shown, the address selector, the code — a
/// new one every 120 seconds, and at once when the address changes — the
/// listener while it is shown, a device's request with its confirmation
/// code, the person's answer, the `authorized_keys` line, and the device's
/// report of its first connection.
///
/// Everything outside the app's own state comes through `Environment`, so
/// that the tests run it against made-up networks, a stand-in SSH server
/// probe and approval, a temporary home folder and a listener on loopback.
/// Time is `Environment.now`, read when `tick()` runs — every second in the
/// app, when the tests say.
@MainActor @Observable final class PairingCoordinator {
    /// A code is good for this long.
    static let codeLifetime: TimeInterval = 120
    /// The listener stays open this long at most, however many codes it shows.
    static let listenerLifetime: TimeInterval = 600
    /// Requests for a code that weren't right — a frame that isn't one, a
    /// connection that sent nothing in time, a request for a code the Mac
    /// never showed, one that doesn't open — before the listener closes.
    static let failureLimit = 20
    /// A request with no answer for this long is turned down.
    static let approvalTimeout: TimeInterval = 60
    /// …and one whose Touch ID or password prompt is still up after this long.
    static let authenticationLimit: TimeInterval = 120
    /// How long the device has, after the approval, to report its connection.
    static let reportTimeout: Duration = .seconds(60)
    /// While Remote Login is off, it is checked again this often.
    static let remoteLoginRecheck: TimeInterval = 2

    struct Environment {
        var snapshot: @Sendable () -> NetworkSnapshot
        var tailscaleResolver: any TailscaleNameResolving
        var lookupTimeout: Duration = TailscaleNameLookup.timeout
        var hostKeyProbe: any SSHHostKeyProbing
        var firewall: @Sendable () async -> FirewallState
        var herdrIsRunning: @Sendable () async -> Bool
        var approval: any PairingApprovalAuthenticating
        var authorizedKeys: AuthorizedKeysFile
        var store: PairedDeviceStore
        var preferences: PairingPreferences
        var username: String
        var macName: String
        var listenAddress: PairingListener.Address = .any
        /// The listener's filter for a row; the tests' lets loopback through.
        var filter: @Sendable (PairingAddressOption) -> PairingConnectionFilter = { PairingConnectionFilter(option: $0) }
        var handshakeTimeout: Duration = PairingListener.handshakeTimeout
        var reportTimeout: Duration = PairingCoordinator.reportTimeout
        /// Whether to follow the system's network changes.
        var watchesNetwork = true
        /// Whether to call `tick()` every second.
        var ticks = true
        var now: () -> Date = { Date() }
        /// When a request arrives: the app bounces its Dock icon.
        var requestAttention: () -> Void = {}
    }

    enum RemoteLogin: Equatable {
        case checking
        case on(PairingPayload.HostKey)
        case off
        case failed(String)
    }

    enum Phase: Equatable {
        /// Checks and the address selector; no code shown.
        case preparing
        case showingCode
        /// A device's request is waiting for the person's answer.
        case request
        /// Approved: the line written, waiting for the device's report.
        case finishing
        case finished
        case stopped(StopReason)
    }

    enum StopReason: Equatable {
        /// The listener's ten minutes are up.
        case timeLimit
        case tooManyFailures
        case listenerFailed(String)
        case codeFailed(String)
    }

    /// Why the chosen row changed without the person choosing.
    enum AddressNotice: Equatable {
        case switched(from: PairingAddressKind, to: PairingAddressKind)
        case unavailable(PairingAddressKind)
    }

    struct ShownCode: Equatable {
        let text: String
        let sessionID: Data
        let expiresAt: Date
        let option: PairingAddressOption
        let port: UInt16
    }

    struct Request: Equatable {
        let request: PairingRequest
        let confirmationCode: PairingConfirmationCode
        let receivedAt: Date
        let remote: PairingIPv4
        let addressKind: PairingAddressKind
        var isAuthenticating = false
        var authenticationError: String?
        /// Requests for the same code that came after this one.
        var laterRequests = 0
    }

    /// The last request that was turned down, shown over the next code.
    enum LastDecision: Equatable {
        case rejected(String)
        case timedOut(String)
        /// The device closed its connection before an answer: it cancelled,
        /// or lost the connection.
        case cancelled(String)
    }

    enum KeyOutcome: Equatable {
        case added
        case alreadyPresent
        /// The line wasn't written: why, and the command to run instead.
        case notWritten(problem: String, command: String)
    }

    struct Finished: Equatable {
        let device: PairedDevice
        let key: KeyOutcome
        var report: PairingReport?
        /// The device didn't report in time.
        var reportMissing = false
        var recordError: String?
    }

    // MARK: - State

    private(set) var remoteLogin: RemoteLogin = .checking
    private(set) var firewall: FirewallState?
    private(set) var herdrIsRunning: Bool?
    private(set) var authorizedKeys: AuthorizedKeysFile.Inspection?
    private(set) var options: [PairingAddressOption] = []
    /// False until the first look at the network and its Tailscale names is done.
    private(set) var hasLookedUpAddresses = false
    private(set) var selectedOption: PairingAddressOption?
    private(set) var addressNotice: AddressNotice?
    private(set) var phase: Phase = .preparing
    private(set) var code: ShownCode?
    private(set) var request: Request?
    private(set) var lastDecision: LastDecision?
    private(set) var finished: Finished?
    /// Requests for the code shown that weren't right; see `failureLimit`.
    private(set) var failureCount = 0
    /// Between `start()` and `stop()`: while the page is open.
    private(set) var isActive = false
    /// Why no device can be added now, or nil: see `setUnavailable`.
    private(set) var unavailableReason: String?
    /// This Mac's installation ID: the `mac_id` every code carries.
    let installationID: UUID

    // MARK: - Private

    private struct CodeSession {
        let sessionID: Data
        let presharedKey: Data
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let payload: PairingPayload
    }

    private enum Retired {
        case expired
        case replaced
        case used
    }

    private let environment: Environment
    private var snapshot = NetworkSnapshot()
    private var tailscaleNames: [PairingIPv4: TailscaleNameLookup.Result] = [:]
    private var lookupsInFlight = 0
    private var listener: PairingListener?
    private var listenerPort: UInt16?
    private var listenerOpenedAt: Date?
    private var listenerClosedForFailures = false
    private var session: CodeSession?
    private var retired: [(sessionID: Data, reason: Retired)] = []
    private var pendingConnection: PairingConnection?
    private var pendingChannel: PairingMacChannel?
    private var isProbing = false
    private var lastProbeAt: Date?
    private var watcher: NetworkChangeWatcher?
    private var clock: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
        installationID = environment.preferences.installationID()
    }

    var now: Date { environment.now() }

    /// When the code shown runs out.
    var secondsLeft: Int? {
        code.map { max(0, Int(($0.expiresAt.timeIntervalSince(now)).rounded(.up))) }
    }

    var canShowCode: Bool {
        guard isActive, unavailableReason == nil, case .on = remoteLogin, selectedOption != nil else { return false }
        switch phase {
        case .preparing, .stopped, .finished: return true
        case .showingCode, .request, .finishing: return false
        }
    }

    // MARK: - The page

    /// When the page opens.
    func start() {
        guard !isActive else { return }
        isActive = true
        phase = .preparing
        recheck()
        refreshAddresses(lookingUpAll: true)
        if environment.watchesNetwork {
            let watcher = NetworkChangeWatcher { [weak self] in self?.refreshAddresses(lookingUpAll: false) }
            watcher.start()
            self.watcher = watcher
        }
        if environment.ticks {
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.tick()
                }
            }
        }
    }

    /// When the page closes: a request waiting is turned down, and the
    /// listener closes.
    func stop() {
        guard isActive else { return }
        if phase == .request {
            if request?.isAuthenticating == true { environment.approval.cancel() }
            answerPendingRequest(.rejected)
        }
        isActive = false
        clock?.cancel()
        clock = nil
        watcher?.stop()
        watcher = nil
        closeListener()
        session = nil
        code = nil
        retired.removeAll()
        if phase != .finishing { phase = .preparing }
    }

    /// Why no device can be added now — the window shows a machine other
    /// than This Mac (SHPHRD-110) — or nil when one can. While there is a
    /// reason no code is shown: one on screen stops working and the listener
    /// closes, as with Hide QR Code, and none follows a request answered. A
    /// request already on screen can still be answered, and an approval
    /// under way — Touch ID or the password, the `authorized_keys` line, the
    /// device's report — goes on to its result.
    func setUnavailable(_ reason: String?) {
        unavailableReason = reason
        if reason != nil, phase == .showingCode {
            hideCode()
        }
    }

    /// The checks again: Remote Login and its host key, herdr, the
    /// firewall, `authorized_keys`.
    func recheck() {
        remoteLogin = .checking
        probeRemoteLogin()
        authorizedKeys = environment.authorizedKeys.inspect()
        let firewall = environment.firewall, herdr = environment.herdrIsRunning
        Task { [weak self] in
            let state = await firewall()
            self?.firewall = state
        }
        Task { [weak self] in
            let running = await herdr()
            self?.herdrIsRunning = running
        }
    }

    /// The person chose a row.
    func select(_ id: PairingAddressOption.ID) {
        guard let option = options.first(where: { $0.id == id }) else { return }
        addressNotice = nil
        environment.preferences.setLastAddressKind(option.kind)
        guard option != selectedOption else { return }
        selectedOption = option
        if phase == .showingCode {
            makeCode(retiring: .replaced)
        } else {
            updateFilter()
        }
    }

    /// Show QR Code, Show Again, Add Another Device.
    func showCode() {
        guard canShowCode else { return }
        finished = nil
        lastDecision = nil
        listenerClosedForFailures = false
        do {
            try openListener()
        } catch {
            phase = .stopped(.listenerFailed(error.localizedDescription))
            return
        }
        makeCode(retiring: nil)
    }

    /// Hide QR Code: the code stops working, and the listener closes.
    func hideCode() {
        guard phase == .showingCode else { return }
        retireSession(.replaced)
        closeListener()
        phase = .preparing
    }

    /// Back to the checks and the selector, from a result or a stop.
    func reset() {
        switch phase {
        case .finished, .stopped:
            finished = nil
            lastDecision = nil
            phase = .preparing
        default:
            break
        }
    }

    func reject() {
        guard phase == .request else { return }
        if request?.isAuthenticating == true { environment.approval.cancel() }
        answerPendingRequest(.rejected)
        continueAfterAnswer()
    }

    /// Approve…: Touch ID or the password, then the line, then the answer.
    func approve() async {
        guard phase == .request, var current = request, !current.isAuthenticating else { return }
        current.isAuthenticating = true
        current.authenticationError = nil
        request = current
        let reason = String(localized: "let “\(current.request.deviceName)” connect to this Mac")
        let failure = await environment.approval.authenticate(reason: reason)
        // The request may have been answered meanwhile: timed out, or the page closed.
        guard phase == .request, request?.receivedAt == current.receivedAt else { return }
        if let failure {
            request?.isAuthenticating = false
            request?.authenticationError = failure
            return
        }
        finishApproval()
    }

    /// Once a second: the code's 120 seconds, the listener's ten minutes,
    /// the request's minute, and Remote Login while it is off.
    func tick() {
        guard isActive else { return }
        let now = self.now
        if remoteLogin == .off, !isProbing, now.timeIntervalSince(lastProbeAt ?? .distantPast) >= Self.remoteLoginRecheck {
            probeRemoteLogin()
        }
        switch phase {
        case .showingCode:
            if let opened = listenerOpenedAt, now.timeIntervalSince(opened) >= Self.listenerLifetime {
                stopListening(.timeLimit)
            } else if let code, now >= code.expiresAt {
                retireSession(.expired)
                refreshAddresses(lookingUpAll: true)
                if phase == .showingCode, self.code == nil { makeCode(retiring: nil) }
            }
        case .request:
            guard let request else { break }
            let waited = now.timeIntervalSince(request.receivedAt)
            if request.isAuthenticating ? waited >= Self.authenticationLimit : waited >= Self.approvalTimeout {
                if request.isAuthenticating { environment.approval.cancel() }
                answerPendingRequest(.timedOut)
                continueAfterAnswer()
            }
        default:
            break
        }
    }

    // MARK: - Addresses

    /// Reads the network again. With `lookingUpAll`, every Tailscale
    /// address's names are looked up again — when the page opens and with
    /// each new code, since a MagicDNS name changes without the network
    /// telling; otherwise only addresses not seen before are.
    func refreshAddresses(lookingUpAll: Bool) {
        guard isActive else { return }
        snapshot = environment.snapshot()
        let candidates = PairingAddressOptions.tailscaleCandidates(in: snapshot).map(\.address)
        tailscaleNames = tailscaleNames.filter { candidates.contains($0.key) }
        let wanted = lookingUpAll ? candidates : candidates.filter { tailscaleNames[$0] == nil }
        if !wanted.isEmpty { lookupsInFlight += 1 }
        applyOptions()
        guard !wanted.isEmpty else { return }
        let resolver = environment.tailscaleResolver, timeout = environment.lookupTimeout
        Task { [weak self] in
            var found: [PairingIPv4: TailscaleNameLookup.Result] = [:]
            for address in wanted {
                found[address] = await TailscaleNameLookup.lookUp(address, resolver: resolver, timeout: timeout)
            }
            self?.lookupsFinished(found)
        }
    }

    private func lookupsFinished(_ found: [PairingIPv4: TailscaleNameLookup.Result]) {
        lookupsInFlight -= 1
        guard isActive else { return }
        let candidates = PairingAddressOptions.tailscaleCandidates(in: snapshot).map(\.address)
        for (address, result) in found where candidates.contains(address) { tailscaleNames[address] = result }
        applyOptions()
    }

    private func applyOptions() {
        options = PairingAddressOptions.options(snapshot: snapshot, tailscaleNames: tailscaleNames)
        if lookupsInFlight == 0 { hasLookedUpAddresses = true }
        guard let previous = selectedOption else {
            // The first choice waits for the names, so that MagicDNS can be it.
            if hasLookedUpAddresses {
                selectedOption = PairingAddressOptions.defaultOption(in: options, lastKind: environment.preferences.lastAddressKind)
                updateFilter()
            }
            return
        }
        switch PairingAddressOptions.reselect(previous, in: options) {
        case .unchanged(let option):
            selectedOption = option
            updateFilter()
        case .changed(let option):
            selectedOption = option
            addressChanged()
        case .replaced(let lost, let option):
            selectedOption = option
            addressNotice = .switched(from: lost, to: option.kind)
            addressChanged()
        case .none(let lost):
            selectedOption = nil
            addressNotice = .unavailable(lost)
            addressChanged()
        }
    }

    /// The chosen address isn't the one the code shows anymore.
    private func addressChanged() {
        guard phase == .showingCode else {
            updateFilter()
            return
        }
        if selectedOption == nil {
            retireSession(.replaced)
            closeListener()
            phase = .preparing
        } else {
            makeCode(retiring: .replaced)
        }
    }

    // MARK: - Codes

    private func makeCode(retiring reason: Retired?) {
        if let reason { retireSession(reason) }
        failureCount = 0
        guard let option = selectedOption, case .on(let hostKey) = remoteLogin, let port = listenerPort else {
            closeListener()
            phase = .preparing
            return
        }
        let sessionID = Self.randomBytes(PairingProtocol.sessionIDLength)
        let presharedKey = Self.randomBytes(PairingProtocol.presharedKeyLength)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let expiresAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) + Self.codeLifetime)
        do {
            let payload = try PairingPayload(sessionID: sessionID, presharedKey: presharedKey,
                                             macPublicKey: privateKey.publicKey.rawRepresentation, expiresAt: expiresAt,
                                             pairingPort: port, address: option.address, hostKey: hostKey,
                                             username: environment.username, macID: installationID, macName: environment.macName)
            let text = try payload.encoded()
            session = CodeSession(sessionID: sessionID, presharedKey: presharedKey, privateKey: privateKey, payload: payload)
            code = ShownCode(text: text, sessionID: sessionID, expiresAt: payload.expiresAt, option: option, port: port)
            updateFilter()
            phase = .showingCode
        } catch {
            closeListener()
            phase = .stopped(.codeFailed(error.localizedDescription))
        }
    }

    private func retireSession(_ reason: Retired) {
        if let session {
            retired.append((session.sessionID, reason))
            if retired.count > 32 { retired.removeFirst(retired.count - 32) }
        }
        session = nil
        code = nil
    }

    private static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: - Listener

    private func openListener() throws {
        guard listener == nil else { return }
        let listener = PairingListener(
            handshakeTimeout: environment.handshakeTimeout,
            onFirstFrame: { [weak self] frame, connection in
                let coordinator = self
                Task { @MainActor in
                    if let coordinator { coordinator.received(frame, on: connection) } else { connection.close() }
                }
            },
            onHandshakeFailure: { [weak self] _, _ in
                let coordinator = self
                Task { @MainActor in coordinator?.countFailure() }
            })
        listenerPort = try listener.start(on: environment.listenAddress, filter: selectedOption.map(environment.filter))
        self.listener = listener
        listenerOpenedAt = now
    }

    private func closeListener() {
        listener?.stop()
        listener = nil
        listenerPort = nil
        listenerOpenedAt = nil
    }

    private func updateFilter() {
        listener?.setFilter(selectedOption.map(environment.filter))
    }

    private func stopListening(_ reason: StopReason) {
        retireSession(.replaced)
        closeListener()
        phase = .stopped(reason)
    }

    private func countFailure() {
        guard listener != nil else { return }
        failureCount += 1
        guard failureCount >= Self.failureLimit else { return }
        record(PairingAuditEntry(date: now, event: .tooManyFailures, addressKind: selectedOption?.kind, detail: "\(failureCount)"))
        if phase == .showingCode {
            stopListening(.tooManyFailures)
        } else {
            // A request is waiting: no more come in, and none follow it.
            closeListener()
            listenerClosedForFailures = true
        }
    }

    // MARK: - Requests

    /// A connection's first frame.
    private func received(_ frame: Data, on connection: PairingConnection) {
        guard isActive, listener != nil, let envelope = try? PairingEnvelope(body: frame), envelope.type == .request else {
            connection.close()
            if isActive { countFailure() }
            return
        }
        let sessionID = envelope.sessionID
        if let session, session.sessionID == sessionID {
            guard now < session.payload.expiresAt else {
                send(.expired, for: sessionID, on: connection)
                return
            }
            let opened: (channel: PairingMacChannel, request: PairingRequest)
            do {
                opened = try PairingMacChannel.open(request: envelope, sessionID: sessionID, presharedKey: session.presharedKey,
                                                    privateKey: session.privateKey)
            } catch {
                connection.close()
                countFailure()
                return
            }
            // The code is used up by its first request that opens.
            retireSession(.used)
            pendingConnection = connection
            pendingChannel = opened.channel
            // A device that goes before the answer takes its request with it.
            connection.whenEnded { [weak self] _ in
                let coordinator = self
                Task { @MainActor in coordinator?.connectionEnded(connection) }
            }
            let kind = session.payload.address.kind
            request = Request(request: opened.request, confirmationCode: opened.channel.confirmationCode, receivedAt: now,
                              remote: connection.endpoints.remote, addressKind: kind)
            lastDecision = nil
            phase = .request
            record(entry(.requested, for: opened.request, remote: connection.endpoints.remote, kind: kind))
            environment.requestAttention()
            return
        }
        switch retired.last(where: { $0.sessionID == sessionID })?.reason {
        case .used:
            if phase == .request { request?.laterRequests += 1 }
            record(PairingAuditEntry(date: now, event: .requestAfterUse, remoteAddress: connection.endpoints.remote.description,
                                     addressKind: request?.addressKind))
            send(.alreadyUsed, for: sessionID, on: connection)
        case .expired:
            send(.expired, for: sessionID, on: connection)
        case .replaced:
            send(.unknownSession, for: sessionID, on: connection)
        case nil:
            send(.unknownSession, for: sessionID, on: connection)
            countFailure()
        }
    }

    private func send(_ failure: PairingFailure, for sessionID: Data, on connection: PairingConnection) {
        let message = try? PairingProtocol.failure(failure, sessionID: sessionID)
        Task {
            if let message { try? await connection.send(message) }
            connection.close()
        }
    }

    private enum Answer {
        case rejected
        case timedOut
        /// The device's connection ended first: there is no one to answer.
        case cancelled
    }

    /// Turns the waiting request down, and says so to the device while it
    /// is still there.
    private func answerPendingRequest(_ answer: Answer) {
        guard let current = request else { return }
        if let connection = pendingConnection {
            if answer != .cancelled, let channel = pendingChannel {
                let message = try? channel.response(PairingResponse(decision: .rejected, macID: installationID))
                Task {
                    if let message { try? await connection.send(message) }
                    connection.close()
                }
            } else {
                connection.close()
            }
        }
        pendingConnection = nil
        pendingChannel = nil
        request = nil
        let name = current.request.deviceName
        switch answer {
        case .rejected:
            record(entry(.rejected, for: current.request, remote: current.remote, kind: current.addressKind))
            lastDecision = .rejected(name)
        case .timedOut:
            record(entry(.timedOut, for: current.request, remote: current.remote, kind: current.addressKind))
            lastDecision = .timedOut(name)
        case .cancelled:
            record(entry(.cancelled, for: current.request, remote: current.remote, kind: current.addressKind))
            lastDecision = .cancelled(name)
        }
    }

    /// The connection of the request on screen ended before it was
    /// answered: the request goes, with the owner's prompt if it is up, and
    /// nothing is written. Once the approval has begun writing the key —
    /// `finishApproval` runs to the end in one go — this comes too late and
    /// changes nothing.
    private func connectionEnded(_ connection: PairingConnection) {
        guard phase == .request, pendingConnection === connection else { return }
        if request?.isAuthenticating == true { environment.approval.cancel() }
        answerPendingRequest(.cancelled)
        continueAfterAnswer()
    }

    /// After a request was turned down: a new code, while the listener may
    /// still take requests and a device can be added.
    private func continueAfterAnswer() {
        guard isActive else { return }
        if listenerClosedForFailures {
            phase = .stopped(.tooManyFailures)
        } else if let opened = listenerOpenedAt, now.timeIntervalSince(opened) >= Self.listenerLifetime {
            stopListening(.timeLimit)
        } else if listener != nil, unavailableReason == nil {
            makeCode(retiring: nil)
        } else {
            closeListener()
            phase = .preparing
        }
    }

    private func finishApproval() {
        guard let current = request, let connection = pendingConnection, let channel = pendingChannel else { return }
        // A device that has gone is told nothing and given nothing, even if
        // the news of it hasn't reached the main actor yet.
        guard !connection.hasEnded else {
            answerPendingRequest(.cancelled)
            continueAfterAnswer()
            return
        }
        let device = current.request
        record(entry(.approved, for: device, remote: current.remote, kind: current.addressKind))
        let line: AuthorizedKeyLine
        do {
            line = try AuthorizedKeyLine(devicePublicKey: device.publicKey, deviceID: device.deviceID, deviceName: device.deviceName)
        } catch {
            // The request was checked when it opened; this doesn't happen.
            answerPendingRequest(.rejected)
            continueAfterAnswer()
            return
        }
        let key: KeyOutcome
        do {
            key = try environment.authorizedKeys.add(line) == .added ? .added : .alreadyPresent
        } catch {
            key = .notWritten(problem: error.localizedDescription, command: AuthorizedKeysFile.addCommand(for: line))
        }
        let event: PairingAuditEntry.Event
        switch key {
        case .added: event = .keyAdded
        case .alreadyPresent: event = .keyAlreadyPresent
        case .notWritten: event = .keyNotWritten
        }
        var keyEntry = entry(event, for: device, remote: current.remote, kind: current.addressKind)
        if case .notWritten(let problem, _) = key { keyEntry.detail = problem }
        record(keyEntry)

        let paired = PairedDevice(deviceID: device.deviceID, name: device.deviceName, model: device.deviceModel,
                                  appVersion: device.appVersion, keyFingerprint: line.fingerprint, line: line.text,
                                  addedAt: now, addressKind: current.addressKind)
        var recordError: String?
        do {
            try environment.store.add(paired)
        } catch {
            recordError = error.localizedDescription
        }
        // No other request is needed now.
        closeListener()
        pendingConnection = nil
        pendingChannel = nil
        request = nil
        finished = Finished(device: paired, key: key, recordError: recordError)
        phase = .finishing

        let response = try? channel.response(PairingResponse(decision: .approved, macID: installationID))
        let timeout = environment.reportTimeout
        Task { [weak self] in
            var report: PairingReport?
            if let response, (try? await connection.send(response)) != nil,
               let frame = try? await connection.nextFrame(timeout: timeout),
               let envelope = try? PairingEnvelope(body: frame) {
                var reader = channel
                report = try? reader.openReport(envelope)
            }
            connection.close()
            self?.reported(report, by: paired, remote: current.remote)
        }
    }

    private func reported(_ report: PairingReport?, by device: PairedDevice, remote: PairingIPv4) {
        var entry = PairingAuditEntry(date: now, event: report == nil ? .connectionNotReported : .connectionChecked,
                                      deviceID: device.deviceID, deviceName: device.name, deviceModel: device.model,
                                      keyFingerprint: device.keyFingerprint, remoteAddress: remote.description,
                                      addressKind: device.addressKind)
        if let report {
            entry.detail = "ssh=\(report.sshConnected) herdr=\(report.herdrReached)" + (report.failure.map { " " + $0 } ?? "")
        }
        record(entry)
        guard finished?.device == device, phase == .finishing else { return }
        finished?.report = report
        finished?.reportMissing = report == nil
        phase = .finished
    }

    // MARK: - Remote Login

    private func probeRemoteLogin() {
        guard !isProbing else { return }
        isProbing = true
        lastProbeAt = now
        let probe = environment.hostKeyProbe
        Task { [weak self] in
            let result = await probe.probe()
            self?.probed(result)
        }
    }

    private func probed(_ result: SSHHostKeyProbeResult) {
        isProbing = false
        lastProbeAt = now
        switch result {
        case .on(let hostKey): remoteLogin = .on(hostKey)
        case .off: remoteLogin = .off
        case .failed(let message): remoteLogin = .failed(message)
        }
    }

    // MARK: - History

    private func entry(_ event: PairingAuditEntry.Event, for request: PairingRequest, remote: PairingIPv4,
                       kind: PairingAddressKind) -> PairingAuditEntry {
        PairingAuditEntry(date: now, event: event, deviceID: request.deviceID, deviceName: request.deviceName,
                          deviceModel: request.deviceModel,
                          keyFingerprint: (try? SSHP256PublicKey.publicKey(fromBlob: request.publicKey))
                            .map { SSHKeyFingerprint.sha256(ofBlob: SSHP256PublicKey.blob(for: $0)) },
                          remoteAddress: remote.description, addressKind: kind)
    }

    private func record(_ entry: PairingAuditEntry) {
        try? environment.store.record(entry)
    }
}
#endif
