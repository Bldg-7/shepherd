import Foundation
import Observation

/// Scan Mac's QR Code, from the scan to the board (SHPHRD-77, "화면 흐름"):
/// what the sheet shows at each step, and what each of its buttons does.
/// Nothing here needs iOS, so the tests run it on a Mac against the Mac's
/// own pairing code on loopback; the sheet (`PairingSheet`) only draws it.
///
/// A code scanned is checked before anything is connected to: that it is a
/// pairing code at all, that it hasn't run out, and what an earlier pairing
/// makes of it (`PairingScanMatch`). The Mac decides when a code has
/// expired; the device only turns down a code that is past its time by more
/// than `expiryLeeway`, so that a clock a little ahead of the Mac's doesn't
/// refuse a code the Mac would still take.
@Observable final class PairingFlow {
    struct Environment {
        var client: PairingClient
        var store: MachineStore
        var device: PairingDeviceInfo
        var now: () -> Date = { Date() }
        /// Keeps the name the person gave the device, for the next pairing.
        var rememberDeviceName: (String) -> Void = { _ in }
    }

    enum Step: Equatable {
        case scanning
        /// A new Mac: what the code says, before connecting.
        case preview(PairingPayload)
        case alreadyAdded(Machine)
        case differentHostKey(Machine)
        /// A Mac already added, at an address it isn't saved with.
        case newAddress(Machine, PairingPayload)
        /// The code ran out while it was shown.
        case expired
        case connecting(PairingPayload)
        case waitingForApproval(PairingPayload, PairingConfirmationCode)
        /// Approved and saved: the first connection.
        case checking(Machine)
        case paired(Machine, PairingConnectionCheck)
        case movingAddress(Machine, PairingPayload)
        case moved(Machine)
        case failed(String)
    }

    /// How far past its expiry a code is still tried; see the type's
    /// description.
    static let expiryLeeway: TimeInterval = 30

    private(set) var step: Step = .scanning
    /// Why the last code scanned wasn't taken, shown over the camera.
    private(set) var scanNotice: String?
    /// The name the Mac shows for this device.
    var deviceName: String

    private let environment: Environment
    private var lastScanned: String?
    private var work: Task<Void, Never>?

    init(environment: Environment, deviceName: String) {
        self.environment = environment
        self.deviceName = String(deviceName.prefix(PairingRequest.maximumNameLength))
    }

    var now: Date { environment.now() }

    // MARK: - Scanning

    /// A code the camera read. The same text twice in a row is read once.
    func scanned(_ text: String) {
        guard step == .scanning, text != lastScanned else { return }
        lastScanned = text
        let payload: PairingPayload
        do {
            payload = try PairingPayload(scanned: text)
        } catch {
            scanNotice = error.localizedDescription
            return
        }
        guard !isPastLeeway(payload) else {
            scanNotice = PairingPayloadError.expired.errorDescription
            return
        }
        scanNotice = nil
        switch PairingScanMatch.match(payload, in: environment.store.machines) {
        case .new: step = .preview(payload)
        case .sameAddress(let machine): step = .alreadyAdded(machine)
        case .differentHostKey(let machine): step = .differentHostKey(machine)
        case .newAddress(let machine): step = .newAddress(machine, payload)
        }
    }

    /// Back to the camera, for another code.
    func scanAgain() {
        work?.cancel()
        work = nil
        lastScanned = nil
        scanNotice = nil
        step = .scanning
    }

    // MARK: - Time

    /// Whole seconds until the code expires on the Mac's clock as the code
    /// gives it, never below zero.
    func secondsLeft(_ payload: PairingPayload, at date: Date) -> Int {
        max(0, Int(payload.expiresAt.timeIntervalSince(date).rounded(.up)))
    }

    private func isPastLeeway(_ payload: PairingPayload) -> Bool {
        payload.isExpired(at: now.addingTimeInterval(-Self.expiryLeeway))
    }

    /// Once a second while the sheet is up: a code shown too long expires.
    func tick() {
        if case .preview(let payload) = step, isPastLeeway(payload) {
            step = .expired
        }
    }

    // MARK: - Connecting

    /// The name as the Mac will show it, or nil when it can't be one: one
    /// line of 1 to 64 characters, without control characters.
    var validDeviceName: String? {
        let name = deviceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= PairingRequest.maximumNameLength,
              name.unicodeScalars.allSatisfy({ ![.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) })
        else { return nil }
        return name
    }

    var canConnect: Bool {
        guard case .preview(let payload) = step else { return false }
        return validDeviceName != nil && !isPastLeeway(payload)
    }

    /// Connect: the request to the Mac, then its answer, then the first
    /// connection.
    func connect() {
        guard case .preview(let payload) = step, canConnect, let name = validDeviceName else { return }
        environment.rememberDeviceName(name)
        step = .connecting(payload)
        let environment = environment
        work = Task { [weak self] in
            do {
                let paired = try await environment.client.pair(payload, device: environment.device, deviceName: name,
                                                               store: environment.store) { progress in
                    guard let self, !Task.isCancelled else { return }
                    switch progress {
                    case .connecting: self.step = .connecting(payload)
                    case .waitingForApproval(let code): self.step = .waitingForApproval(payload, code)
                    case .checkingConnection(let machine): self.step = .checking(machine)
                    }
                }
                self?.step = .paired(paired.machine, paired.check)
            } catch is CancellationError {
                // The person cancelled; the sheet is going away.
            } catch {
                guard !Task.isCancelled else { return }
                self?.step = .failed(Self.message(for: error))
            }
        }
    }

    /// Use New Address: the known Mac at the code's address.
    func moveAddress() {
        guard case .newAddress(let machine, let payload) = step else { return }
        step = .movingAddress(machine, payload)
        let environment = environment
        work = Task { [weak self] in
            do {
                let moved = try await environment.client.moveAddress(of: machine, to: payload, store: environment.store)
                self?.step = .moved(moved)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.step = .failed(Self.message(for: error))
            }
        }
    }

    /// The sheet is closing: whatever is under way stops, and its
    /// connection closes. A Mac already approved stays added.
    func cancel() {
        work?.cancel()
    }

    /// Waits for the work under way to end; for the tests.
    func settle() async {
        await work?.value
    }

    // MARK: - Words

    static func message(for error: any Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// What to say about a pairing whose first connection didn't get
    /// through; nil when it did.
    static func summary(of check: PairingConnectionCheck, macName: String) -> String? {
        guard !check.succeeded else { return nil }
        if check.keyRefused {
            return String(localized: "\(macName) was added, but it didn't let this device in. If the Mac showed a command to run in Terminal, run it there, then open \(macName) in Machines.")
        }
        let reason = check.failure ?? String(localized: "The connection failed")
        if !check.sshConnected {
            return String(localized: "\(macName) was added, but connecting to it failed: \(reason)")
        }
        return String(localized: "\(macName) was added, but its herdr didn't answer: \(reason) Check that herdr is running on the Mac.")
    }
}
