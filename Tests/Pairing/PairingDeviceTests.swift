import CryptoKit
import Darwin
import Foundation

// The iOS app's side of pairing by QR code (SHPHRD-77, "단계 C"), without
// the app, a camera, SSH, DNS, the Keychain or the Secure Enclave: the
// device's PairingClient and the sheet's PairingFlow, end to end over
// 127.0.0.1 against the Mac's own PairingCoordinator (with stand-ins for
// its owner's approval and its SSH server probe, from PairingMacFixtures),
// and against a made-up Mac for answers the real one doesn't give. The
// device's connections are the app's Network framework ones, sent to
// 127.0.0.1 in place of the address the code resolved to; its name lookups
// come from a table; its key is a software P-256 key; its machine list is
// a MachineStore over defaults and secrets kept in memory; and the first
// SSH connection after an approval is a stand-in that records what it was
// asked to do. Run in a sandbox that reaches only loopback.

@main enum PairingDeviceTests {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        scanInputs()
        await roundTrip(root.appending(path: "trip"))
        await firstConnectionFails(root.appending(path: "ssh-fails"))
        await turnedDown(root.appending(path: "rejected"))
        await expiry(root.appending(path: "expiry"))
        await usedAndReplaced(root.appending(path: "used"))
        await busyListener(root.appending(path: "busy"))
        await waitingForTheAnswer(root.appending(path: "waiting"))
        await rescans(root.appending(path: "rescan"))
        await madeUpMac()
        await connectionLimits()
        await addressLookups()
        Checks.finish("device pairing checks: scanning, the request and answers against the Mac's coordinator on loopback, retries, waiting, the first connection, rescans, key cleanup")
    }

    // MARK: - The device's world

    static let magic = Net.magicDNSName
    static let tailscale = Net.tailscaleAddress

    /// A device with its machine list in memory, connecting to loopback.
    @MainActor final class Device {
        let defaults = MemoryDefaults()
        let secrets = MemorySecrets()
        let store: MachineStore
        let dialer = LoopbackDialer()
        let names: FakeNames
        let keys = KeyMaker()
        let checker = FakeChecker()
        let clock: TestClock
        let info = PairingDeviceInfo(id: UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!, model: "iPhone", appVersion: "0.1.0 (2)")
        var remembered: [String] = []

        init(clock: TestClock, names: FakeNames = FakeNames([Net.magicDNSName: [Net.tailscaleAddress]])) {
            self.clock = clock
            self.names = names
            store = MachineStore(defaults: defaults, keychain: secrets)
        }

        func client(responseTimeout: Duration = PairingClient.responseTimeout, attempts: Int = 5,
                    retryDelay: Duration = .milliseconds(300)) -> PairingClient {
            let keys = keys
            var client = PairingClient(resolver: PairingAddressResolver(resolver: names, timeout: .seconds(2)), dialer: dialer,
                                       makeDeviceKey: { keys.make() }, checker: checker)
            client.responseTimeout = responseTimeout
            client.attempts = attempts
            client.retryDelay = retryDelay
            client.reportTimeout = .seconds(2)
            return client
        }

        func flow(_ client: PairingClient? = nil, name: String = "Minsu’s iPhone") -> PairingFlow {
            let clock = clock
            let environment = PairingFlow.Environment(client: client ?? self.client(), store: store, device: info,
                                                      now: { clock.now }, rememberDeviceName: { [weak self] in self?.remembered.append($0) })
            return PairingFlow(environment: environment, deviceName: name)
        }

        var isClean: Bool { store.machines.isEmpty && secrets.items.isEmpty }
    }

    static func started(_ world: PairingWorld) async -> PairingCoordinator {
        let coordinator = PairingCoordinator(environment: world.environment())
        coordinator.start()
        _ = await waitUntil { coordinator.hasLookedUpAddresses && coordinator.remoteLogin != .checking }
        return coordinator
    }

    /// A Mac showing a code: MagicDNS is chosen on a first visit.
    static func showing(_ root: URL) async -> (PairingWorld, PairingCoordinator, String)? {
        let world = PairingWorld(home: root)
        let coordinator = await started(world)
        coordinator.showCode()
        guard let text = coordinator.code?.text else {
            check(false, "the Mac shows a code (\(root.lastPathComponent))")
            return nil
        }
        return (world, coordinator, text)
    }

    static func makeDevice(for world: PairingWorld) -> Device {
        Device(clock: TestClock(world.clock.now))
    }

    // MARK: - Scanning

    static func scanInputs() {
        let device = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let flow = device.flow()
        flow.scanned("https://example.com/not-a-pairing-code")
        check(flow.step == .scanning && flow.scanNotice == PairingPayloadError.notAPairingCode.errorDescription,
              "another QR code: the camera stays, saying it isn't a pairing code")
        flow.scanned("SHPHRD2:AAAA")
        check(flow.step == .scanning && flow.scanNotice == PairingPayloadError.needsNewerApp.errorDescription,
              "a later version's code: an update is needed")
        flow.scanned("SHPHRD1:!!!")
        check(flow.step == .scanning && flow.scanNotice == PairingPayloadError.malformed.errorDescription, "a damaged code")
        check(device.dialer.opened.isEmpty && device.names.lookups.isEmpty && device.keys.made.isEmpty,
              "nothing scanned so far was looked up, connected to or made a key for")

        let payload = madeUpPayload(port: 40_000, expiresAt: device.clock.now.addingTimeInterval(120))
        flow.scanned(try! payload.encoded())
        check(flow.step == .preview(payload) && flow.scanNotice == nil, "a pairing code: its preview")
        check(flow.secondsLeft(payload, at: device.clock.now) == 120, "two minutes left")
        let names: [(String, Bool)] = [("Minsu’s iPhone", true), ("  Minsu’s iPhone  ", true), ("", false), ("   ", false),
                                       (String(repeating: "a", count: 64), true), (String(repeating: "a", count: 65), false),
                                       ("Minsu\u{0007}", false), ("Minsu\nPhone", false), ("민수의 iPhone", true)]
        for (name, valid) in names {
            flow.deviceName = name
            check(flow.canConnect == valid, "the device's name \(name.debugDescription) is \(valid ? "" : "not ")one the Mac takes")
        }
        flow.deviceName = "  Minsu’s iPhone  "
        check(flow.validDeviceName == "Minsu’s iPhone", "the name is sent trimmed")
        check(PairingFlow(environment: flowEnvironment(device), deviceName: String(repeating: "b", count: 80)).deviceName.count == 64,
              "a long system name is cut to the 64 characters the Mac takes")

        flow.scanAgain()
        check(flow.step == .scanning && flow.scanNotice == nil, "Scan Again: the camera")
        flow.scanned(try! payload.encoded())
        check(flow.step == .preview(payload), "the same code again, after Scan Again")
    }

    static func flowEnvironment(_ device: Device) -> PairingFlow.Environment {
        let clock = device.clock
        return PairingFlow.Environment(client: device.client(), store: device.store, device: device.info, now: { clock.now })
    }

    // MARK: - A pairing from start to end

    static func roundTrip(_ root: URL) async {
        guard let (world, coordinator, text) = await showing(root) else { return }
        let device = makeDevice(for: world)
        let flow = device.flow()
        flow.scanned(text)
        guard case .preview(let payload) = flow.step else { check(false, "the Mac's code is previewed"); return }
        check(payload.macName == "Minsu’s MacBook Pro" && payload.username == "minsu" && payload.address.kind == .tailscaleMagicDNS
              && payload.address.hostname == magic && payload.hostKey.fingerprint == FakeProbe.hostKey.fingerprint,
              "the preview: the Mac's name, user@address and kind, host key")
        check(device.dialer.opened.isEmpty && device.keys.made.isEmpty, "nothing is sent or made before Connect")

        flow.connect()
        check(await waitUntil { coordinator.phase == .request }, "the Mac shows the device's request")
        check(device.remembered == ["Minsu’s iPhone"], "the name given is kept for next time")
        guard let request = coordinator.request else { return }
        check(await waitUntil { if case .waitingForApproval = flow.step { true } else { false } }, "the device waits for the Mac's owner")
        if case .waitingForApproval(_, let code) = flow.step {
            check(code == request.confirmationCode, "both screens show the same confirmation code (\(code))")
        }
        check(request.request.deviceName == "Minsu’s iPhone" && request.request.deviceModel == "iPhone"
              && request.request.deviceID == device.info.id && request.request.appVersion == "0.1.0 (2)",
              "the request: the device's name, model, ID and app version")
        check(device.keys.made.count == 1 && request.request.publicKey == device.keys.made[0].publicKeyBlob,
              "a key made for the request, its public half sent")
        check(device.names.lookups == [magic], "the MagicDNS name was looked up once")
        check(device.dialer.opened.map(\.address) == [tailscale] && device.dialer.opened.map(\.port) == [coordinator.code?.port ?? payload.pairingPort],
              "connected to the address the name resolved to, at the code's port")
        check(device.isClean, "nothing saved before the Mac approves")

        await coordinator.approve()
        check(await waitUntil { if case .paired = flow.step { true } else { false } }, "approved, saved and checked")
        guard case .paired(let machine, let result) = flow.step else { return }
        check(result.succeeded && PairingFlow.summary(of: result, macName: machine.displayName) == nil, "the first connection went through")
        check(device.store.machines == [machine] && machine.id == coordinator.installationID && machine.displayName == "Minsu’s MacBook Pro"
              && machine.hostname == magic && machine.addressKind == .tailscaleMagicDNS && machine.port == 22 && machine.username == "minsu"
              && machine.sessionName.isEmpty && machine.authMethod == .secureEnclaveKey
              && machine.pinnedHostKeyFingerprint == FakeProbe.hostKey.fingerprint,
              "the machine: the Mac's installation ID, name, address and kind, port 22, user, herdr's default session, the pinned host key")
        check(device.secrets.items == [machine.keychainTag: device.keys.made[0].storedRepresentation], "the key saved under the machine's tag")
        check(device.checker.calls.count == 1 && device.checker.calls.first?.machine == machine
              && device.checker.calls.first?.credential == device.keys.made[0].storedRepresentation
              && device.checker.calls.first?.address == tailscale,
              "the first connection: the saved machine, its key, the address the pairing went to")

        check(await waitUntil { coordinator.phase == .finished }, "the Mac gets the report")
        check(coordinator.finished?.report == PairingReport(sshConnected: true, herdrReached: true, failure: nil), "the report: SSH and herdr reached")
        let line = try! AuthorizedKeyLine(devicePublicKey: device.keys.made[0].publicKeyBlob, deviceID: device.info.id, deviceName: "Minsu’s iPhone")
        check((try? String(contentsOfFile: world.authorizedKeys.path, encoding: .utf8)) == line.text + "\n",
              "the Mac let the device's own key in")
        check(device.dialer.links.allSatisfy(\.isClosed), "the device closed its connection")
        check(device.dialer.opened.count == 1, "one connection")
    }

    static func firstConnectionFails(_ root: URL) async {
        guard let (world, coordinator, text) = await showing(root) else { return }
        let device = makeDevice(for: world)
        device.checker.result = PairingConnectionCheck(sshConnected: false, herdrReached: false, failure: "Connection refused")
        let flow = device.flow()
        flow.scanned(text)
        flow.connect()
        _ = await waitUntil { coordinator.phase == .request }
        await coordinator.approve()
        check(await waitUntil { coordinator.phase == .finished }, "the Mac gets a report of a failed connection")
        check(coordinator.finished?.report == PairingReport(sshConnected: false, herdrReached: false, failure: "Connection refused"),
              "the report says SSH failed, and why")
        guard case .paired(let machine, let result) = flow.step else { check(false, "paired despite the failure"); return }
        check(!result.succeeded && device.store.machines == [machine] && device.secrets.items.count == 1,
              "approved but not connected: the machine and its key stay")
        check(PairingFlow.summary(of: result, macName: machine.displayName)?.contains("Connection refused") == true, "the sheet says why")

        let refused = PairingConnectionCheck(sshConnected: false, herdrReached: false, failure: "x", keyRefused: true)
        check(PairingFlow.summary(of: refused, macName: "Studio")?.contains("Terminal") == true,
              "a key turned down right after approval: run the Mac's command")
        let herdr = PairingConnectionCheck(sshConnected: true, herdrReached: false, failure: "herdr.sock closed the connection without responding")
        check(PairingFlow.summary(of: herdr, macName: "Studio")?.contains("herdr") == true, "herdr didn't answer: said so")
        let long = PairingConnectionCheck(sshConnected: false, herdrReached: false, failure: String(repeating: "x", count: 500))
        check(long.report.failure?.count == PairingConnectionCheck.maximumReportedFailure, "the Mac is told at most 200 characters")
        check(PairedConnectionError.accessRemoved.errorDescription?.contains("removed") == true,
              "a paired Mac that turns the key down later: its access was removed")
    }

    static func turnedDown(_ root: URL) async {
        // Rejected by the owner.
        guard let (world, coordinator, text) = await showing(root.appending(path: "owner")) else { return }
        let device = makeDevice(for: world)
        let flow = device.flow()
        flow.scanned(text)
        flow.connect()
        _ = await waitUntil { coordinator.phase == .request }
        coordinator.reject()
        check(await waitUntil { if case .failed = flow.step { true } else { false } }, "rejected: the device says so")
        check(flow.step == .failed(PairingClientError.rejected.errorDescription!), "…that the Mac turned it down")
        check(device.keys.made.count == 1 && device.isClean, "rejected: the key made for it is dropped, nothing saved")
        check(device.checker.calls.isEmpty, "no connection is tried")
        flow.scanAgain()
        check(flow.step == .scanning, "Scan Again after a rejection")

        // No answer on the Mac within its minute.
        guard let (world2, coordinator2, text2) = await showing(root.appending(path: "timeout")) else { return }
        let device2 = makeDevice(for: world2)
        let flow2 = device2.flow()
        flow2.scanned(text2)
        flow2.connect()
        _ = await waitUntil { coordinator2.phase == .request }
        world2.clock.advance(61)
        coordinator2.tick()
        check(await waitUntil { flow2.step == .failed(PairingClientError.rejected.errorDescription!) }, "unanswered on the Mac: turned down")
        check(device2.isClean, "…and nothing kept")
    }

    static func expiry(_ root: URL) async {
        // Past its time on the Mac, not on the device: the Mac decides.
        guard let (world, coordinator, text) = await showing(root.appending(path: "mac")) else { return }
        let device = makeDevice(for: world)
        let flow = device.flow()
        flow.scanned(text)
        check(flow.canConnect, "the device's clock has time left")
        world.clock.advance(121)
        flow.connect()
        check(await waitUntil { flow.step == .failed(PairingProtocolError.failed(.expired).errorDescription!) }, "the Mac says the code expired")
        check(device.isClean, "expired: nothing kept")
        _ = coordinator

        // Past its time on the device.
        let device2 = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let payload = madeUpPayload(port: 40_000, expiresAt: device2.clock.now)
        let flow2 = device2.flow()
        device2.clock.advance(PairingFlow.expiryLeeway + 1)
        flow2.scanned(try! payload.encoded())
        check(flow2.step == .scanning && flow2.scanNotice == PairingPayloadError.expired.errorDescription,
              "a code well past its time isn't taken")
        device2.clock.advance(-20)
        flow2.scanAgain()
        flow2.scanned(try! payload.encoded())
        check(flow2.step == .preview(payload) && flow2.canConnect && flow2.secondsLeft(payload, at: device2.clock.now) == 0,
              "a code just past its time on the device's clock is still tried: the Mac decides")
        device2.clock.advance(20)
        flow2.tick()
        check(flow2.step == .expired && !flow2.canConnect, "once well past it, the preview says it expired")
        check(device2.dialer.opened.isEmpty && device2.keys.made.isEmpty, "no connection for an expired code")
    }

    static func usedAndReplaced(_ root: URL) async {
        // Someone else's request came first.
        guard let (world, coordinator, text) = await showing(root.appending(path: "used")) else { return }
        let first = makeDevice(for: world), second = makeDevice(for: world)
        let flow1 = first.flow(), flow2 = second.flow(name: "Someone’s iPhone")
        flow1.scanned(text)
        flow2.scanned(text)
        flow1.connect()
        _ = await waitUntil { coordinator.phase == .request }
        flow2.connect()
        check(await waitUntil { flow2.step == .failed(PairingProtocolError.failed(.alreadyUsed).errorDescription!) },
              "a second request for the code: already used")
        check(second.isClean && second.dialer.opened.count == 1, "…nothing kept, and not tried again")
        check(coordinator.request?.laterRequests == 1, "the Mac counts the later request")
        coordinator.reject()
        _ = await waitUntil { if case .failed = flow1.step { true } else { false } }
        check(first.isClean, "the first one rejected: nothing kept")

        // The Mac moved on to another code.
        guard let (world2, coordinator2, text2) = await showing(root.appending(path: "replaced")) else { return }
        let device = makeDevice(for: world2)
        let flow = device.flow()
        flow.scanned(text2)
        coordinator2.select(PairingAddressOption.ID(kind: .tailscaleIPv4, interfaceName: nil))
        check(coordinator2.code?.text != text2, "the Mac shows a new code for another address")
        flow.connect()
        check(await waitUntil { flow.step == .failed(PairingProtocolError.failed(.unknownSession).errorDescription!) },
              "the old code: the Mac isn't showing it anymore")
        check(device.isClean && coordinator2.phase == .showingCode, "nothing kept; the Mac's new code still waits")
    }

    static func busyListener(_ root: URL) async {
        guard let (world, coordinator, text) = await showing(root) else { return }
        guard let port = coordinator.code?.port, let idle = await Wire.connect(port: port) else { check(false, "a connection holds the listener"); return }
        defer { Darwin.close(idle) }
        let device = makeDevice(for: world)
        let flow = device.flow(device.client(retryDelay: .milliseconds(300)))
        flow.scanned(text)
        flow.connect()
        check(await waitUntil { coordinator.phase == .request }, "the device got through once the other connection was dropped")
        check(device.dialer.opened.count >= 2 && device.dialer.links.dropLast().allSatisfy(\.isClosed),
              "the connections the Mac closed while another waited were tried again (\(device.dialer.opened.count) in all)")
        if case .waitingForApproval(_, let code) = flow.step {
            check(code == coordinator.request?.confirmationCode, "the same request each time: the same confirmation code")
        } else {
            check(false, "the device shows the code")
        }
        coordinator.reject()
        _ = await waitUntil { if case .failed = flow.step { true } else { false } }
    }

    static func waitingForTheAnswer(_ root: URL) async {
        check(PairingClient.responseTimeout >= .seconds(130), "the device waits at least 130 seconds for the Mac's answer")

        // The owner takes longer than the listener's ten seconds; the device waits.
        guard let (world, coordinator, text) = await showing(root.appending(path: "slow")) else { return }
        let device = makeDevice(for: world)
        let flow = device.flow()
        flow.scanned(text)
        flow.connect()
        _ = await waitUntil { coordinator.phase == .request }
        world.approval.holds = true
        let approving = Task { await coordinator.approve() }
        try? await Task.sleep(for: .seconds(11))
        check(coordinator.request?.isAuthenticating == true, "the Mac's owner is still at Touch ID after 11 seconds")
        if case .waitingForApproval = flow.step {
            check(true, "the device still waits")
        } else {
            check(false, "the device still waits (\(flow.step))")
        }
        world.approval.holds = false
        await approving.value
        check(await waitUntil { if case .paired = flow.step { true } else { false } }, "then approved, it pairs")

        // An answer that never comes, with the wait cut short for the test.
        guard let (world2, coordinator2, text2) = await showing(root.appending(path: "never")) else { return }
        let device2 = makeDevice(for: world2)
        let flow2 = device2.flow(device2.client(responseTimeout: .seconds(1)))
        flow2.scanned(text2)
        let start = ContinuousClock.now
        flow2.connect()
        check(await waitUntil(10) { flow2.step == .failed(PairingClientError.noAnswer.errorDescription!) }, "no answer: the device stops waiting")
        check(ContinuousClock.now - start >= .milliseconds(900), "…only once its time is up")
        check(device2.isClean && device2.dialer.links.allSatisfy(\.isClosed), "…and keeps nothing, its connection closed")
        coordinator2.reject()

        // Cancelled while waiting: the connection closes and nothing is kept.
        guard let (world3, coordinator3, text3) = await showing(root.appending(path: "cancel")) else { return }
        let device3 = makeDevice(for: world3)
        let flow3 = device3.flow()
        flow3.scanned(text3)
        flow3.connect()
        _ = await waitUntil { coordinator3.phase == .request }
        _ = await waitUntil { if case .waitingForApproval = flow3.step { true } else { false } }
        flow3.cancel()
        await flow3.settle()
        check(device3.dialer.links.allSatisfy(\.isClosed) && device3.isClean, "Cancel: the connection closed, nothing kept")
        check(await waitUntil { coordinator3.phase != .request }, "…and the Mac closes the request on its screen")
        if case .cancelled? = coordinator3.lastDecision {
            check(coordinator3.phase == .showingCode, "…saying the device cancelled, over a new code")
        } else {
            check(false, "…saying the device cancelled (\(String(describing: coordinator3.lastDecision)))")
        }
        await coordinator3.approve()
        check(!FileManager.default.fileExists(atPath: world3.authorizedKeys.path) && coordinator3.finished == nil,
              "…so it can't be approved, and authorized_keys is left as it was")
        coordinator3.reject()
    }

    // MARK: - The same Mac's code again

    static func rescans(_ root: URL) async {
        guard let (world, coordinator, text) = await showing(root) else { return }
        let device = makeDevice(for: world)
        let flow = device.flow()
        flow.scanned(text)
        flow.connect()
        _ = await waitUntil { coordinator.phase == .request }
        await coordinator.approve()
        _ = await waitUntil { coordinator.phase == .finished }
        guard let saved = device.store.machines.first else { check(false, "paired before the rescans"); return }
        let opened = device.dialer.opened.count, checks = device.checker.calls.count

        // The same address.
        coordinator.reset()
        coordinator.showCode()
        let again = device.flow()
        again.scanned(coordinator.code?.text ?? "")
        check(again.step == .alreadyAdded(saved), "the same Mac and address: already added")
        check(device.dialer.opened.count == opened && device.checker.calls.count == checks && coordinator.phase == .showingCode,
              "…nothing connected to; the Mac's code isn't used")

        // Another address.
        coordinator.select(PairingAddressOption.ID(kind: .tailscaleIPv4, interfaceName: nil))
        guard let movedText = coordinator.code?.text, let movedPayload = try? PairingPayload(scanned: movedText) else { return }
        let move = device.flow()
        move.scanned(movedText)
        check(move.step == .newAddress(saved, movedPayload), "the same Mac at another address: the old and new address")
        device.checker.result = PairingConnectionCheck(sshConnected: false, herdrReached: false, failure: "Timed out")
        move.moveAddress()
        check(await waitUntil { if case .failed = move.step { true } else { false } }, "a new address that doesn't answer")
        check(device.store.machines == [saved], "…changes nothing")
        device.checker.result = PairingConnectionCheck(sshConnected: true, herdrReached: true)
        move.scanAgain()
        move.scanned(movedText)
        move.moveAddress()
        check(await waitUntil { if case .moved = move.step { true } else { false } }, "a new address that answers")
        guard case .moved(let moved) = move.step else { return }
        check(moved.hostname == tailscale.description && moved.addressKind == .tailscaleIPv4 && moved.id == saved.id
              && moved.keychainTag == saved.keychainTag && moved.pinnedHostKeyFingerprint == saved.pinnedHostKeyFingerprint
              && moved.username == saved.username && moved.authMethod == .secureEnclaveKey && device.store.machines == [moved],
              "…moves the machine there: the address and its kind only")
        let last = device.checker.calls.last
        check(last?.machine.hostname == tailscale.description && last?.machine.addressKind == .tailscaleIPv4
              && last?.machine.pinnedHostKeyFingerprint == saved.pinnedHostKeyFingerprint && last?.address == tailscale
              && last?.credential == device.secrets.items[saved.keychainTag],
              "checked first with the key and host key it already had, at the new address")
        check(device.dialer.opened.count == opened && coordinator.phase == .showingCode && coordinator.request == nil,
              "the Mac wasn't asked: its code goes unused")
        check(device.secrets.items.count == 1 && device.keys.made.count == 1, "no new key")

        // Another host key under the same Mac ID.
        let other = PairingWorld(home: root.appending(path: "other"), probe: .on(try! PairingPayload.HostKey(algorithm: .ed25519, sha256: Data(repeating: 9, count: 32))))
        other.preferences.preferences.write(PairingPreferences.installationIDKey, saved.id.uuidString)
        let otherCoordinator = await started(other)
        otherCoordinator.showCode()
        let stranger = device.flow()
        stranger.scanned(otherCoordinator.code?.text ?? "")
        check(stranger.step == .differentHostKey(moved), "the same Mac ID with another host key: not taken")
        check(device.store.machines == [moved] && device.dialer.opened.count == opened, "…nothing changed or connected to")

        // A machine added by hand that has the code's ID isn't taken over.
        var manual = Machine(id: UUID(), displayName: "By Hand", hostname: "192.168.0.12", username: "minsu", authMethod: .key)
        manual.pinnedHostKeyFingerprint = FakeProbe.hostKey.fingerprint
        let payload = madeUpPayload(port: 40_000, expiresAt: device.clock.now.addingTimeInterval(60), macID: manual.id)
        check(PairingScanMatch.match(payload, in: [manual]) == .differentHostKey(manual), "a machine added by hand is never changed by a code")
        check(PairingScanMatch.match(payload, in: []) == .new, "no machine with the ID: a new pairing")
    }

    // MARK: - A made-up Mac

    /// Answers the real Mac doesn't give: a response for another Mac, bytes
    /// that aren't a message, a frame too long, and a failure.
    static func madeUpMac() async {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        func payload(port: UInt16) -> (PairingPayload, Data) {
            let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let payload = try! PairingPayload(sessionID: Data((0..<16).map { UInt8($0) }), presharedKey: secret,
                                              macPublicKey: macKey.publicKey.rawRepresentation,
                                              expiresAt: Date(timeIntervalSince1970: 1_800_000_120), pairingPort: port,
                                              address: try! PairingAddress(kind: .tailscaleIPv4, ipv4: tailscale),
                                              hostKey: FakeProbe.hostKey, username: "minsu", macID: UUID(), macName: "Made-up Mac")
            return (payload, secret)
        }

        // Approved, but for another Mac ID.
        guard let mac = FakeMac() else { check(false, "a made-up Mac listens on 127.0.0.1"); return }
        let (wrongID, secret) = payload(port: mac.port)
        let served = mac.serve { frame in
            guard let envelope = try? PairingEnvelope(body: frame),
                  let opened = try? PairingMacChannel.open(request: envelope, sessionID: wrongID.sessionID, presharedKey: secret, privateKey: macKey)
            else { return (nil, nil) }
            return (try? opened.channel.response(PairingResponse(decision: .approved, macID: UUID())), opened.channel)
        }
        let device = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let flow = device.flow()
        flow.scanned(try! wrongID.encoded())
        flow.connect()
        check(await waitUntil { flow.step == .failed(PairingClientError.unreadableAnswer.errorDescription!) },
              "an approval for another Mac ID isn't taken")
        check(device.isClean && device.checker.calls.isEmpty, "…nothing saved or connected to")
        let report = await served.value
        check(report?.sshConnected == false && report?.failure == "The Mac's answer didn't match its QR code.", "…and the Mac is told why")
        mac.stop()

        for (name, answer, expected) in [("bytes that aren't a message", Data([0, 0, 0, 4, 1, 2, 3, 4]), PairingClientError.unreadableAnswer),
                                         ("a frame longer than 8 KiB", Data([0, 0, 0x20, 1]), PairingClientError.unreadableAnswer)] {
            guard let mac = FakeMac() else { return }
            let (code, _) = payload(port: mac.port)
            let served = mac.serve { _ in (answer, nil) }
            let device = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
            let flow = device.flow()
            flow.scanned(try! code.encoded())
            flow.connect()
            check(await waitUntil { flow.step == .failed(expected.errorDescription!) }, "\(name): unreadable")
            check(device.isClean, "\(name): nothing kept")
            _ = await served.value
            mac.stop()
        }

        guard let closing = FakeMac() else { return }
        let (closed, _) = payload(port: closing.port)
        let servedClosed = closing.serve { _ in (try? PairingProtocol.failure(.closed, sessionID: closed.sessionID), nil) }
        let device2 = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let flow2 = device2.flow()
        flow2.scanned(try! closed.encoded())
        flow2.connect()
        check(await waitUntil { flow2.step == .failed(PairingProtocolError.failed(.closed).errorDescription!) }, "the Mac stopped pairing: said so")
        check(device2.isClean, "…nothing kept")
        _ = await servedClosed.value
        closing.stop()
    }

    // MARK: - Connections that don't get anywhere

    static func connectionLimits() async {
        // A Mac that closes every connection at once.
        guard let mac = FakeMac() else { return }
        let closer = mac.closeEach(3)
        let device = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let payload = madeUpPayload(port: mac.port, expiresAt: device.clock.now.addingTimeInterval(120))
        let flow = device.flow(device.client(attempts: 3, retryDelay: .milliseconds(200)))
        flow.scanned(try! payload.encoded())
        flow.connect()
        check(await waitUntil { flow.step == .failed(PairingClientError.closedWithoutAnswer.errorDescription!) },
              "closed each time: the device gives up, saying so")
        let taken = await closer.value
        check(device.dialer.opened.count == 3 && taken == 3, "after three connections, as many as it tries")
        check(device.isClean, "…and keeps nothing")
        mac.stop()

        // Nothing listening.
        let port = FakeMac.unusedPort()
        let device2 = Device(clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)))
        let refused = madeUpPayload(port: port, expiresAt: device2.clock.now.addingTimeInterval(120))
        let flow2 = device2.flow(device2.client(attempts: 2, retryDelay: .milliseconds(100)))
        flow2.scanned(try! refused.encoded())
        flow2.connect()
        let reason = PairingLinkError.refused.reason
        check(await waitUntil {
            flow2.step == .failed(PairingClientError.couldNotConnect(host: tailscale.description, reason: reason).errorDescription!)
        }, "nothing listens: couldn't connect, refused")
        check(device2.dialer.opened.count == 2 && device2.isClean, "tried twice, nothing kept")
    }

    // MARK: - Looking the address up

    static func addressLookups() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        // A MagicDNS name that resolves outside Tailscale.
        let device = Device(clock: clock, names: FakeNames([magic: [Net.ip("203.0.113.7")]]))
        let payload = madeUpPayload(port: 40_000, expiresAt: clock.now.addingTimeInterval(120),
                                    address: try! PairingAddress(kind: .tailscaleMagicDNS, name: magic))
        let flow = device.flow()
        flow.scanned(try! payload.encoded())
        flow.connect()
        check(await waitUntil { if case .failed = flow.step { true } else { false } }, "a name outside its kind's range")
        if case .failed(let message) = flow.step {
            check(message.contains("Tailscale"), "…is refused, pointing at Tailscale: \(message)")
        }
        check(device.dialer.opened.isEmpty && device.keys.made.isEmpty && device.isClean, "…before any key or connection")

        // A name that doesn't resolve.
        let device2 = Device(clock: clock, names: FakeNames([:]))
        let flow2 = device2.flow()
        flow2.scanned(try! payload.encoded())
        flow2.connect()
        check(await waitUntil { if case .failed = flow2.step { true } else { false } }, "a name that doesn't resolve")
        check(device2.dialer.opened.isEmpty && device2.keys.made.isEmpty, "…nothing connected to")

        // A private IPv4 address isn't looked up.
        let device3 = Device(clock: clock, names: FakeNames([:]))
        let lan = madeUpPayload(port: FakeMac.unusedPort(), expiresAt: clock.now.addingTimeInterval(120),
                                address: try! PairingAddress(kind: .privateIPv4, ipv4: Net.ip("192.168.0.12")))
        let flow3 = device3.flow(device3.client(attempts: 1))
        flow3.scanned(try! lan.encoded())
        flow3.connect()
        _ = await waitUntil { if case .failed = flow3.step { true } else { false } }
        check(device3.names.lookups.isEmpty && device3.dialer.opened.map(\.address) == [Net.ip("192.168.0.12")],
              "an address is connected to as it is, without a lookup")
    }

    static func madeUpPayload(port: UInt16, expiresAt: Date, macID: UUID = UUID(),
                              address: PairingAddress = try! PairingAddress(kind: .tailscaleIPv4, ipv4: Net.tailscaleAddress)) -> PairingPayload {
        try! PairingPayload(sessionID: Data(repeating: 1, count: 16), presharedKey: Data(repeating: 2, count: 32),
                            macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, expiresAt: expiresAt,
                            pairingPort: max(port, 1024), address: address, hostKey: FakeProbe.hostKey, username: "minsu", macID: macID,
                            macName: "Studio")
    }
}

// MARK: - Stand-ins

/// Defaults kept in a dictionary: every call MachineStore makes is answered
/// here, so nothing is read from or written to any defaults domain.
nonisolated final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    nonisolated(unsafe) private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: "shepherd.pairing-device-tests.unused")!
    }

    override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }
}

/// The Keychain's place: secrets by tag, in memory.
final class MemorySecrets: MachineSecretStore {
    private(set) var items: [String: Data] = [:]

    func saveSecret(_ data: Data, tag: String) throws { items[tag] = data }
    func loadSecret(tag: String) throws -> Data? { items[tag] }
    func deleteSecret(tag: String) throws { items[tag] = nil }
}

/// Software keys in the Secure Enclave's place, each one kept to compare.
final class KeyMaker {
    private(set) var made: [SecureEnclaveSSHKey] = []

    func make() -> SecureEnclaveSSHKey {
        let key = SecureEnclaveSSHKey.makeSoftware()
        made.append(key)
        return key
    }
}

/// Name lookups from a table, each one recorded.
nonisolated final class FakeNames: PairingNameResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let table: [String: [PairingIPv4]]
    private var asked: [String] = []

    init(_ table: [String: [PairingIPv4]]) { self.table = table }

    var lookups: [String] { lock.withLock { asked } }

    func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        lock.withLock { asked.append(name) }
        guard let found = table[name] else { throw FakeTailscaleResolver.NotFound() }
        return found
    }
}

/// The first connection after an approval, or at a new address: recorded,
/// answered as told. Never SSH.
final class FakeChecker: PairedMacChecking {
    struct Call {
        let machine: Machine
        let credential: Data
        let address: PairingIPv4
    }

    var result = PairingConnectionCheck(sshConnected: true, herdrReached: true)
    private(set) var calls: [Call] = []

    func check(_ machine: Machine, credential: Data, at address: PairingIPv4) async -> PairingConnectionCheck {
        calls.append(Call(machine: machine, credential: credential, address: address))
        return result
    }
}

/// The app's Network framework connections, made to 127.0.0.1 at the port
/// asked for, whatever the address: the address is recorded, never
/// connected to.
nonisolated final class LoopbackDialer: PairingDialing, @unchecked Sendable {
    struct Target: Equatable {
        let address: PairingIPv4
        let port: UInt16
    }

    private let lock = NSLock()
    private var targets: [Target] = []
    private var made: [RecordedLink] = []
    private let inner = NetworkPairingDialer(connectTimeout: .seconds(3))

    var opened: [Target] { lock.withLock { targets } }
    var links: [RecordedLink] { lock.withLock { made } }

    func open(_ address: PairingIPv4, port: UInt16) async throws -> any PairingLink {
        lock.withLock { targets.append(Target(address: address, port: port)) }
        let link = RecordedLink(try await inner.open(PairingIPv4(127, 0, 0, 1), port: port))
        lock.withLock { made.append(link) }
        return link
    }
}

nonisolated final class RecordedLink: PairingLink, @unchecked Sendable {
    private let inner: any PairingLink
    private let lock = NSLock()
    private var closed = false

    init(_ inner: any PairingLink) { self.inner = inner }

    var isClosed: Bool { lock.withLock { closed } }

    func send(_ data: Data) async throws { try await inner.send(data) }
    func receive() async throws -> Data? { try await inner.receive() }

    func close() {
        lock.withLock { closed = true }
        inner.close()
    }
}

/// A listener on 127.0.0.1 that plays a Mac.
nonisolated final class FakeMac: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0, let port = Self.port(of: fd), port >= 1024 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.port = port
    }

    /// A port on 127.0.0.1 that nothing listens on.
    static func unusedPort() -> UInt16 {
        guard let mac = FakeMac() else { return 40_001 }
        let port = mac.port
        mac.stop()
        return port
    }

    func stop() { Darwin.close(fd) }

    /// Takes one connection and its first frame, sends what `answer` gives
    /// for it, then reads the report that follows if `answer` gave a channel
    /// to open it with.
    func serve(_ answer: @escaping @Sendable (Data) -> (Data?, PairingMacChannel?)) -> Task<PairingReport?, Never> {
        let fd = fd
        return Task.detached {
            guard let connection = Self.accept(fd) else { return nil }
            defer { Darwin.close(connection) }
            guard let frame = Self.readFrame(connection) else { return nil }
            let (reply, channel) = answer(frame)
            if let reply {
                _ = reply.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
            }
            guard var channel, let m3 = Self.readFrame(connection), let envelope = try? PairingEnvelope(body: m3) else { return nil }
            return try? channel.openReport(envelope)
        }
    }

    /// Takes `count` connections and closes each at once; returns how many came.
    func closeEach(_ count: Int) -> Task<Int, Never> {
        let fd = fd
        return Task.detached {
            var taken = 0
            while taken < count, let connection = Self.accept(fd) {
                Darwin.close(connection)
                taken += 1
            }
            return taken
        }
    }

    private static func accept(_ fd: Int32) -> Int32? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 5_000) == 1 else { return nil }
        let connection = Darwin.accept(fd, nil, nil)
        guard connection >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return connection
    }

    private static func readFrame(_ fd: Int32) -> Data? {
        guard let header = Wire.readExactly(fd, 4) else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= PairingProtocol.maximumMessageLength else { return nil }
        return Wire.readExactly(fd, length).map { Data($0) }
    }

    private static func port(of fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }
}
