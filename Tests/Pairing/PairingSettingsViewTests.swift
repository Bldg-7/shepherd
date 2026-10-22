import AppKit
import CoreImage
import CryptoKit
import Observation
import SwiftUI

// Settings' iPhone and iPad page and its Add iPhone or iPad page (SHPHRD-77),
// the real views over a coordinator with stand-ins, in windows that are
// never shown, read and pressed through the accessibility VoiceOver uses:
// the device list with a line taken out by hand, the checks, the address
// selector, the QR code as drawn read back with Core Image, the window kept
// out of screen captures while it shows, a request with its confirmation
// code turned down and another approved through to its result, and what the
// page says when Remote Login is off, the firewall blocks everything, herdr
// isn't running, the key can't be written, or there is no address. A device
// on 127.0.0.1 sends the requests. And, while the window shows a machine
// other than This Mac (SHPHRD-110), Add Device… greyed out with why, and an
// Add page already open showing no code but seeing a request through.
// And "Show Conversations on iPhone and iPad" (SHPHRD-105) on both pages,
// over the real AgentProxyService with a stand-in LaunchAgent and proxy:
// turned on and off, what it says while agents still use the proxy, while
// Login Items has it off, and greyed out while another machine is shown.
// Nothing here opens System Settings, writes to the pasteboard, presents a
// dialog, or orders a window in.

nonisolated final class ResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}

@main @MainActor enum PairingSettingsViewTests {
    static var windows: [NSWindow] = []

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let enable = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        check(NSApp.responds(to: enable), "this process can turn its own accessibility on")
        _ = NSApp.perform(enable, with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        sharingGuard()
        deviceList(root.appending(path: "list"))
        pairPage(root.appending(path: "pair"))
        problems(root.appending(path: "problems"))
        noAddress(root.appending(path: "no-address"))
        localOnly(root.appending(path: "local-only"))
        conversations(root.appending(path: "conversations"))
        check(windows.allSatisfy { !$0.isVisible }, "no window was ever shown")
        for window in windows { window.contentView = nil; window.close() }
        Checks.finish("Settings pairing view checks in never-shown windows, read and pressed through accessibility")
    }

    // MARK: - Harness

    static func drain(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    static func drainUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            drain(0.02)
        }
        return condition()
    }

    /// Runs async work off the main actor, keeping the run loop going until it is done.
    static func run<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) -> Value? {
        let box = ResultBox<Value>()
        Task.detached { box.set(await work()) }
        _ = drainUntil(10) { box.value != nil }
        return box.value
    }

    static func show<V: View>(_ view: V, height: CGFloat = 620) -> NSHostingView<AnyView> {
        let size = CGSize(width: 540, height: height)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        drain(0.5)
        host.layoutSubtreeIfNeeded()
        drain(0.2)
        return host
    }

    static func accessibility(_ view: NSView) -> [String: NSObject] {
        var found: [String: NSObject] = [:]
        func walk(_ node: AnyObject, _ depth: Int) {
            guard depth < 80 else { return }
            if let element = node as? NSAccessibilityElementProtocol, let id = element.accessibilityIdentifier?(), !id.isEmpty,
               let object = node as? NSObject, found[id] == nil { found[id] = object }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        }
        walk(view, 0)
        return found
    }

    /// Every label and value text in the tree.
    static func texts(_ view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ node: AnyObject, _ depth: Int) {
            guard depth < 80 else { return }
            if let object = node as? NSObject {
                if object.responds(to: NSSelectorFromString("accessibilityLabel")), let label = object.value(forKey: "accessibilityLabel") as? String,
                   !label.isEmpty { found.append(label) }
                if object.responds(to: NSSelectorFromString("accessibilityValue")), let value = object.value(forKey: "accessibilityValue") as? String,
                   !value.isEmpty { found.append(value) }
            }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        }
        walk(view, 0)
        return found
    }

    static func label(_ element: NSObject?) -> String {
        guard let element else { return "" }
        let label = element.value(forKey: "accessibilityLabel") as? String ?? ""
        let value = element.responds(to: NSSelectorFromString("accessibilityValue")) ? element.value(forKey: "accessibilityValue") as? String ?? "" : ""
        return value.isEmpty ? label : label + " " + value
    }

    static func isEnabled(_ element: NSObject?) -> Bool {
        (element?.value(forKey: "accessibilityEnabled") as? Bool) ?? false
    }

    @discardableResult
    static func press(_ element: NSObject?) -> Bool {
        guard let element, element.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
        return true
    }

    /// The QR codes in what `view` draws.
    static func drawnQRCodes(_ view: NSView) -> [String] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return [] }
        return PairingQRCode.messages(in: image)
    }

    static func sharingType(_ view: NSView) -> NSWindow.SharingType? {
        view.window?.sharingType
    }

    /// The guard on a window that was never put on screen, where macOS
    /// lets the sharing type go back.
    static func sharingGuard() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        WindowSharingProtection.protect(window)
        WindowSharingProtection.protect(window)
        check(window.sharingType == NSWindow.SharingType.none, "protected: out of screen captures")
        WindowSharingProtection.release(window)
        check(window.sharingType == NSWindow.SharingType.none, "still protected while another guard holds it")
        WindowSharingProtection.release(window)
        check(window.sharingType == .readOnly && !WindowSharingProtection.protects(window), "the last guard gone: shared as before")
    }

    // MARK: - The device list

    static func deviceList(_ root: URL) {
        let world = PairingWorld(home: root.appending(path: "home"))
        let keys = world.authorizedKeys
        let lineA = PairingMacTestsSupport.line("Phone A"), lineB = PairingMacTestsSupport.line("Phone B")
        _ = try? keys.add(lineA)
        let a = PairedDevice(deviceID: UUID(), name: "Phone A", model: "iPhone", appVersion: "1.0", keyFingerprint: lineA.fingerprint, line: lineA.text,
                             addedAt: Date(timeIntervalSince1970: 1_000), addressKind: .localName)
        let b = PairedDevice(deviceID: UUID(), name: "Tablet B", model: "iPad", appVersion: "1.0", keyFingerprint: lineB.fingerprint, line: lineB.text,
                             addedAt: Date(timeIntervalSince1970: 2_000), addressKind: .tailscaleMagicDNS)
        try? world.store.add(a)
        try? world.store.add(b)
        try? world.store.record(PairingAuditEntry(date: Date(timeIntervalSince1970: 1_000), event: .approved, deviceID: a.deviceID, deviceName: "Phone A"))
        try? world.store.record(PairingAuditEntry(date: Date(timeIntervalSince1970: 1_500), event: .requestAfterUse, remoteAddress: "192.168.0.77"))

        let model = PairedDevicesModel(store: world.store, authorizedKeys: keys)
        var made: [PairingCoordinator] = []
        var wentBack = false
        let host = show(PairedDevicesSettingsView(model: model, makeCoordinator: {
            let coordinator = PairingCoordinator(environment: world.environment())
            made.append(coordinator)
            return coordinator
        }, onBack: { wentBack = true }), height: 900)
        var ax = accessibility(host)
        check(ax["settings.devices.page"] != nil, "the iPhone and iPad page")
        check(ax["settings.devices.row.\(a.id)"] != nil && ax["settings.devices.row.\(b.id)"] != nil, "both devices are listed")
        check(ax["settings.devices.not-in-file.\(b.id)"] != nil && ax["settings.devices.not-in-file.\(a.id)"] == nil,
              "the one whose line was taken out by hand says so; the other doesn't")
        check(label(ax["settings.devices.remove.\(a.id)"]).contains("Remove Phone A…"), "each has its remove button, named")
        let all = texts(host)
        check(all.contains { $0.contains("You approved “Phone A”.") } && all.contains { $0.contains("Another device asked to connect with a QR code already used, from 192.168.0.77.") },
              "the history is shown")
        check(all.contains { $0.contains(lineA.fingerprint) }, "a device's key fingerprint is shown")
        check(ax["settings.devices.add"] != nil && ax["settings.devices.empty"] == nil, "Add Device…, and no empty note")

        press(ax["settings.devices.add"])
        check(drainUntil { accessibility(host)["settings.pair.page"] != nil }, "Add Device… opens the Add iPhone or iPad page in its place")
        check(made.count == 1 && drainUntil { label(accessibility(host)["settings.pair.remote-login"]).contains("Remote Login is on") },
              "…which starts its checks")
        ax = accessibility(host)
        check(label(ax["settings.pair.back"]).contains("iPhone and iPad"), "its back button goes to iPhone and iPad")
        press(ax["settings.pair.back"])
        check(drainUntil { accessibility(host)["settings.devices.page"] != nil }, "back on the list")
        check(drainUntil { made.first?.isActive == false }, "the page left: its coordinator stopped")
        check(!wentBack, "the list's own back button wasn't pressed")

        // An empty list.
        let empty = PairingWorld(home: root.appending(path: "empty"))
        let emptyHost = show(PairedDevicesSettingsView(model: PairedDevicesModel(store: empty.store, authorizedKeys: empty.authorizedKeys),
                                                       makeCoordinator: { PairingCoordinator(environment: empty.environment()) }, onBack: {}))
        check(accessibility(emptyHost)["settings.devices.empty"] != nil && texts(emptyHost).contains { $0.contains("Nothing yet.") },
              "no devices and no history: said so")
    }

    // MARK: - Adding a device

    static func pairPage(_ root: URL) {
        let world = PairingWorld(home: root)
        let coordinator = PairingCoordinator(environment: world.environment())
        var wentBack = false
        let host = show(PairDeviceView(coordinator: coordinator, onBack: { wentBack = true }), height: 1700)
        check(drainUntil { coordinator.hasLookedUpAddresses && accessibility(host)["settings.pair.address.tailscaleMagicDNS"] != nil },
              "the page started its checks and lists the addresses")
        var ax = accessibility(host)
        check(label(ax["settings.pair.remote-login"]).contains("Remote Login is on"), "Remote Login is on")
        check(texts(host).contains("About Password Login"), "with a note on turning password login off")
        check(label(ax["settings.pair.herdr"]).contains("herdr is running"), "herdr is running")
        check(ax["settings.pair.firewall"] == nil && ax["settings.pair.authorized-keys"] == nil, "nothing about the firewall or authorized_keys when they're fine")
        check(ax["settings.pair.awake"] != nil, "the note about sleep and full disk access")
        for id in ["localName", "privateIPv4.en0", "tailscaleIPv4", "tailscaleMagicDNS"] {
            check(ax["settings.pair.address.\(id)"] != nil, "an address row for \(id)")
        }
        let localRow = label(ax["settings.pair.address.localName"])
        check(localRow.contains(".local Name") && localRow.contains("minsus-macbook-pro.local") && localRow.contains("Only on the same Wi-Fi or wired network"),
              "a row says its kind, its value and how far it reaches")
        check(label(ax["settings.pair.address.privateIPv4.en0"]).contains("Private IPv4 · Wi-Fi")
              && label(ax["settings.pair.address.privateIPv4.en0"]).contains("192.168.0.12"), "the private row names its service")
        check(label(ax["settings.pair.address.tailscaleMagicDNS"]).contains(Net.magicDNSName)
              && label(ax["settings.pair.address.tailscaleMagicDNS"]).contains("Use Tailscale DNS"), "the MagicDNS row says what the device needs")
        check(coordinator.selectedOption?.kind == .tailscaleMagicDNS, "MagicDNS is chosen first")
        check(ax["settings.pair.qr"] == nil && sharingType(host) == .readOnly, "no code yet, and the window shares as usual")

        press(ax["settings.pair.address.privateIPv4.en0"])
        check(drainUntil { coordinator.selectedOption?.kind == .privateIPv4 }, "choosing a row")
        ax = accessibility(host)
        check(isEnabled(ax["settings.pair.show-code"]), "Show QR Code can be pressed")
        press(ax["settings.pair.show-code"])
        check(drainUntil { accessibility(host)["settings.pair.qr"] != nil }, "Show QR Code shows the code")
        ax = accessibility(host)
        guard let code = coordinator.code else { check(false, "a code"); return }
        check(label(ax["settings.pair.qr"]).contains("QR code for 192.168.0.12"), "the code's image is named with its address")
        check(label(ax["settings.pair.time-left"]).contains("2:00"), "how long until a new code")
        check(ax["settings.pair.screen-warning"] != nil && ax["settings.pair.hide-code"] != nil, "the warning about screen sharing, and Hide QR Code")
        check(ax["settings.pair.address.localName"] != nil, "the selector stays beside the code")
        check(sharingType(host) == NSWindow.SharingType.none && WindowSharingProtection.protects(host.window!),
              "while the code shows, the window is kept out of screen captures")
        check(drawnQRCodes(host) == [code.text], "the QR code as drawn reads back as the code's text")

        press(ax["settings.pair.address.tailscaleIPv4"])
        check(drainUntil { coordinator.code.map { $0.sessionID != code.sessionID } == true
                           && label(accessibility(host)["settings.pair.qr"]).contains("100.101.102.103") },
              "choosing another row shows a new code for it")
        guard let tailscaleCode = coordinator.code else { return }
        check(drainUntil { drawnQRCodes(host) == [tailscaleCode.text] }, "…which is what is drawn")

        // A request, turned down.
        guard var device = try? TestDevice(scanning: tailscaleCode.text), let m1 = try? device.request(),
              let fd = run({ await Wire.connect(port: tailscaleCode.port) }) ?? nil else { check(false, "a device connects"); return }
        _ = run { await Wire.send(fd, m1) }
        check(drainUntil { accessibility(host)["settings.pair.request.title"] != nil }, "the request is shown")
        ax = accessibility(host)
        check(label(ax["settings.pair.request.title"]).contains("“Minsu’s iPhone” (iPhone) wants to connect to this Mac."), "who is asking")
        check(label(ax["settings.pair.request.code"]).contains(device.channel.confirmationCode.description),
              "the confirmation code the device shows (\(device.channel.confirmationCode))")
        check(ax["settings.pair.qr"] == nil && !WindowSharingProtection.protects(host.window!),
              "the code is gone, and the page lets go of the window's sharing type")
        check(ax["settings.pair.reject"] != nil && ax["settings.pair.approve"] != nil, "Reject and Approve…")
        press(ax["settings.pair.reject"])
        let answer = run { await Wire.readFrame(fd) } ?? nil
        check(answer.flatMap { try? device.channel.openResponse(PairingEnvelope(body: $0)) }?.decision == .rejected, "Reject turns the device down")
        close(fd)
        check(drainUntil { accessibility(host)["settings.pair.qr"] != nil && label(accessibility(host)["settings.pair.last-decision"]).contains("You turned down") },
              "a new code, saying what happened to the last request")

        // A device that goes before the answer.
        guard let gone = coordinator.code, var leaving = try? TestDevice(scanning: gone.text), let m1g = try? leaving.request(),
              let fdg = run({ await Wire.connect(port: gone.port) }) ?? nil else { check(false, "a device that leaves"); return }
        _ = run { await Wire.send(fdg, m1g) }
        check(drainUntil { accessibility(host)["settings.pair.request.title"] != nil }, "its request is shown")
        close(fdg)
        check(drainUntil { label(accessibility(host)["settings.pair.last-decision"]).contains("cancelled its request or lost its connection") },
              "it closes its connection: the request goes, said so over a new code")
        check(accessibility(host)["settings.pair.approve"] == nil && accessibility(host)["settings.pair.qr"] != nil, "…with no Approve… left to press")

        // Another, approved.
        guard let next = coordinator.code, var second = try? TestDevice(scanning: next.text, name: "Minsu’s iPad", model: "iPad"),
              let m1b = try? second.request(), let fd2 = run({ await Wire.connect(port: next.port) }) ?? nil else { check(false, "a second device"); return }
        _ = run { await Wire.send(fd2, m1b) }
        check(drainUntil { accessibility(host)["settings.pair.approve"] != nil }, "the second request")
        press(accessibility(host)["settings.pair.approve"])
        check(drainUntil { accessibility(host)["settings.pair.result.waiting"] != nil }, "approved: waiting for the device")
        check(label(accessibility(host)["settings.pair.result.key"]).contains("was added to ~/.ssh/authorized_keys"), "the key added")
        let m2 = run { await Wire.readFrame(fd2) } ?? nil
        check(m2.flatMap { try? second.channel.openResponse(PairingEnvelope(body: $0)) }?.decision == .approved, "the device is told it was approved")
        if let report = try? second.channel.report(PairingReport(sshConnected: true, herdrReached: true)) {
            _ = run { await Wire.send(fd2, report) }
        }
        check(drainUntil { label(accessibility(host)["settings.pair.result.title"]).contains("“Minsu’s iPad” can now connect to this Mac.") },
              "the result: it can connect")
        ax = accessibility(host)
        check(label(ax["settings.pair.result.ssh"]).contains("logged in over SSH") && label(ax["settings.pair.result.herdr"]).contains("reached herdr"),
              "it logged in over SSH and reached herdr")
        check(ax["settings.pair.another"] != nil && ax["settings.pair.result.back"] != nil, "Add Another Device, and back")
        close(fd2)
        press(ax["settings.pair.result.back"])
        check(drainUntil { wentBack }, "back to iPhone and iPad")
    }

    // MARK: - What the checks say

    static func problems(_ root: URL) {
        var world = PairingWorld(home: root, probe: .off)
        world.firewall = .blocksAllIncoming
        world.herdrIsRunning = false
        mkdir(root.appending(path: "elsewhere").path, 0o700)
        symlink(root.appending(path: "elsewhere").path, world.authorizedKeys.directoryPath)
        let coordinator = PairingCoordinator(environment: world.environment())
        let host = show(PairDeviceView(coordinator: coordinator, onBack: {}), height: 1400)
        check(drainUntil { label(accessibility(host)["settings.pair.remote-login"]).contains("Remote Login is off") }, "Remote Login off: said so")
        let ax = accessibility(host)
        check(ax["settings.pair.open-sharing"] != nil, "with a way to the Sharing settings (not pressed here)")
        check(ax["settings.pair.show-code"] != nil && !isEnabled(ax["settings.pair.show-code"]), "Show QR Code can't be pressed")
        check(label(ax["settings.pair.firewall"]).contains("blocks all incoming connections"), "the firewall blocking everything: said so")
        check(label(ax["settings.pair.herdr"]).contains("herdr isn't running"), "herdr not running: said so")
        check(label(ax["settings.pair.authorized-keys"]).contains("symbolic link"), "authorized_keys that can't be written: said why")

        var onWorld = PairingWorld(home: root.appending(path: "firewall-on"))
        onWorld.firewall = .on
        let onHost = show(PairDeviceView(coordinator: PairingCoordinator(environment: onWorld.environment()), onBack: {}), height: 1400)
        check(drainUntil { label(accessibility(onHost)["settings.pair.firewall"]).contains("click Allow") }, "the firewall on: what to answer macOS")
    }

    static func noAddress(_ root: URL) {
        let world = PairingWorld(home: root, snapshot: NetworkSnapshot())
        let coordinator = PairingCoordinator(environment: world.environment())
        let host = show(PairDeviceView(coordinator: coordinator, onBack: {}), height: 1400)
        check(drainUntil { accessibility(host)["settings.pair.no-address"] != nil }, "no address: said so")
        check(label(accessibility(host)["settings.pair.no-address"]).contains("Wi-Fi or a wired network, or turn on Tailscale"), "…with what to do")
        check(!isEnabled(accessibility(host)["settings.pair.show-code"]), "…and no code can be shown")
    }
}

/// The machine the window shows, as Settings hands it down: why no device
/// can be added, or nil on This Mac.
@MainActor @Observable final class ShownMachine {
    var addUnavailableReason: String?
    init(_ reason: String?) { addUnavailableReason = reason }
}

/// The iPhone and iPad page as Settings shows it, following `shown`.
struct FollowingDevicesPage: View {
    let shown: ShownMachine
    let model: PairedDevicesModel
    let makeCoordinator: () -> PairingCoordinator

    var body: some View {
        PairedDevicesSettingsView(model: model, makeCoordinator: makeCoordinator, addUnavailableReason: shown.addUnavailableReason, onBack: {})
    }
}

extension PairingSettingsViewTests {
    // MARK: - While the window shows another machine

    static func localOnly(_ root: URL) {
        let reason = "Connect to This Mac to add a device."
        let world = PairingWorld(home: root)
        let line = PairingMacTestsSupport.line("Phone A")
        _ = try? world.authorizedKeys.add(line)
        let phone = PairedDevice(deviceID: UUID(), name: "Phone A", model: "iPhone", appVersion: "1.0", keyFingerprint: line.fingerprint,
                                 line: line.text, addedAt: Date(timeIntervalSince1970: 1_000), addressKind: .localName)
        try? world.store.add(phone)
        let shown = ShownMachine(reason)
        var made: [PairingCoordinator] = []
        let host = show(FollowingDevicesPage(shown: shown, model: PairedDevicesModel(store: world.store, authorizedKeys: world.authorizedKeys)) {
            let coordinator = PairingCoordinator(environment: world.environment())
            made.append(coordinator)
            return coordinator
        }, height: 1700)

        // The list, on another machine.
        var ax = accessibility(host)
        check(ax["settings.devices.row.\(phone.id)"] != nil && isEnabled(ax["settings.devices.remove.\(phone.id)"]),
              "another machine: the devices are listed, and can be removed")
        check(ax["settings.devices.add"] != nil && !isEnabled(ax["settings.devices.add"]), "Add Device… is greyed out")
        check(label(ax["settings.devices.add-unavailable"]).contains(reason), "…with why under the list")
        press(ax["settings.devices.add"])
        drain(0.3)
        check(made.isEmpty && accessibility(host)["settings.pair.page"] == nil, "…and does nothing")

        // This Mac.
        shown.addUnavailableReason = nil
        check(drainUntil { isEnabled(accessibility(host)["settings.devices.add"]) && accessibility(host)["settings.devices.add-unavailable"] == nil },
              "This Mac: Add Device… can be pressed, with no reason shown")
        press(accessibility(host)["settings.devices.add"])
        check(drainUntil { accessibility(host)["settings.pair.page"] != nil }, "…and opens the Add page")
        guard let coordinator = made.first else { check(false, "a coordinator"); return }
        check(drainUntil { coordinator.canShowCode && isEnabled(accessibility(host)["settings.pair.show-code"]) }, "a code can be shown")
        press(accessibility(host)["settings.pair.show-code"])
        check(drainUntil { accessibility(host)["settings.pair.qr"] != nil } && WindowSharingProtection.protects(host.window!), "the code is shown")

        // Another machine, with the code on screen.
        shown.addUnavailableReason = reason
        check(drainUntil { accessibility(host)["settings.pair.qr"] == nil && accessibility(host)["settings.pair.unavailable"] != nil },
              "another machine: the code goes, the page stays")
        ax = accessibility(host)
        check(label(ax["settings.pair.unavailable"]).contains(reason) && !isEnabled(ax["settings.pair.show-code"]),
              "…saying why in its place, Show QR Code greyed out")
        check(coordinator.code == nil && coordinator.phase == .preparing && !WindowSharingProtection.protects(host.window!),
              "…the code no longer works, and the window shares as usual")
        check(ax["settings.pair.remote-login"] != nil && ax["settings.pair.address.localName"] != nil, "the checks and the addresses stay")

        // This Mac again, then a request that the window going elsewhere
        // doesn't stop.
        shown.addUnavailableReason = nil
        check(drainUntil { accessibility(host)["settings.pair.unavailable"] == nil && isEnabled(accessibility(host)["settings.pair.show-code"]) },
              "This Mac again: the reason goes, and a code can be shown")
        press(accessibility(host)["settings.pair.show-code"])
        check(drainUntil { coordinator.code != nil }, "shown")
        guard let code = coordinator.code, var device = try? TestDevice(scanning: code.text), let m1 = try? device.request(),
              let fd = run({ await Wire.connect(port: code.port) }) ?? nil else { check(false, "a device connects"); return }
        _ = run { await Wire.send(fd, m1) }
        check(drainUntil { accessibility(host)["settings.pair.approve"] != nil }, "the request is shown")
        shown.addUnavailableReason = reason
        drain(0.3)
        ax = accessibility(host)
        check(ax["settings.pair.request.title"] != nil && isEnabled(ax["settings.pair.approve"]) && isEnabled(ax["settings.pair.reject"]),
              "another machine: the request stays, and can still be answered")
        press(ax["settings.pair.approve"])
        check(drainUntil { accessibility(host)["settings.pair.result.waiting"] != nil }, "approved: waiting for the device")
        let m2 = run { await Wire.readFrame(fd) } ?? nil
        check(m2.flatMap { try? device.channel.openResponse(PairingEnvelope(body: $0)) }?.decision == .approved, "the device is told it was approved")
        if let report = try? device.channel.report(PairingReport(sshConnected: true, herdrReached: true)) {
            _ = run { await Wire.send(fd, report) }
        }
        check(drainUntil { label(accessibility(host)["settings.pair.result.title"]).contains("can now connect to this Mac") }, "the result")
        ax = accessibility(host)
        check(ax["settings.pair.another"] != nil && !isEnabled(ax["settings.pair.another"]) && label(ax["settings.pair.unavailable"]).contains(reason),
              "Add Another Device greyed out, with why")
        check(isEnabled(ax["settings.pair.result.back"]), "Back to iPhone and iPad can be pressed")
        close(fd)
        press(ax["settings.pair.result.back"])
        check(drainUntil { accessibility(host)["settings.devices.page"] != nil }, "back on the list")
        check(drainUntil { !coordinator.isActive }, "the page left: its coordinator stopped")
        let listed = (try? world.store.devices())?.first { $0.deviceID == device.id }
        check(listed != nil && drainUntil { accessibility(host)["settings.devices.row.\(listed?.id ?? "")"] != nil }
              && !isEnabled(accessibility(host)["settings.devices.add"]), "the device approved is listed, and Add Device… stays greyed out")
    }
}

/// Lines with fresh keys.
enum PairingMacTestsSupport {
    static func line(_ name: String) -> AuthorizedKeyLine {
        try! AuthorizedKeyLine(devicePublicKey: SSHP256PublicKey.blob(for: P256Key.make()), deviceID: UUID(), deviceName: name)
    }
}

enum P256Key {
    static func make() -> P256.Signing.PublicKey { P256.Signing.PrivateKey().publicKey }
}

// MARK: - Show Conversations on iPhone and iPad

/// The proxy's control socket, in memory.
actor ProxyControlStandIn: AgentProxyControlling {
    private(set) var routes: [AgentProxyRoute] = []
    func setRoutes(_ routes: [AgentProxyRoute]) { self.routes = routes }
    func status() async throws -> AgentProxyStatus {
        AgentProxyStatus(protocolVersion: AgentProxyControl.protocolVersion, build: "build-a", port: 24680, state: .running, routeCount: routes.count,
                         inFlight: 0, recorder: .init(state: .running, pid: nil, restarts: 0),
                         counters: .init(exchanges: 0, rejected: 0, upstreamFailures: 0, recorderDropped: 0))
    }
    func restartWhenIdle() async throws -> AgentProxyRestartWhenIdle { AgentProxyRestartWhenIdle(accepted: true, inFlight: 0) }
    func createRoute(_ request: AgentProxyRouteCreate) async throws -> AgentProxyRouteCreated {
        throw AgentProxyControlFailure.unreachable
    }
    func removeRoute(_ routeID: String) async throws -> Bool {
        let before = routes.count
        routes.removeAll { $0.routeID == routeID }
        return routes.count < before
    }
    func listRoutes() async throws -> [AgentProxyRoute] { routes }
}

/// The LaunchAgent, counted and never registered.
@MainActor final class ProxyLaunchAgentStandIn: AgentProxyLaunchAgent {
    var state: AgentProxyLaunchAgentState = .notRegistered
    var registeredState: AgentProxyLaunchAgentState = .enabled
    var registered = 0, unregistered = 0, opened = 0
    func register() throws { registered += 1; state = registeredState }
    func unregister() async throws { unregistered += 1; state = .notRegistered }
    func openSystemSettings() { opened += 1 }
}

@MainActor @Observable final class ShownProxySetting {
    var reason: String?
    init(_ reason: String?) { self.reason = reason }
}

/// Both pages as Settings shows them, following `shown`.
struct FollowingProxyPages: View {
    let shown: ShownProxySetting
    let service: AgentProxyService
    let model: PairedDevicesModel
    let coordinator: PairingCoordinator?

    var body: some View {
        if let coordinator {
            PairDeviceView(coordinator: coordinator, agentProxy: service, agentProxyUnavailableReason: shown.reason, onBack: {})
        } else {
            PairedDevicesSettingsView(model: model, makeCoordinator: { preconditionFailure("not opened here") }, agentProxy: service,
                                      agentProxyUnavailableReason: shown.reason, onBack: {})
        }
    }
}

extension PairingSettingsViewTests {
    static func conversations(_ root: URL) {
        let world = PairingWorld(home: root)
        let agent = ProxyLaunchAgentStandIn(), control = ProxyControlStandIn()
        var setting = false, live: Set<String> = []
        let service = AgentProxyService(environment: AgentProxyService.Environment(
            launchAgent: agent, control: control, loadSetting: { setting }, saveSetting: { setting = $0 },
            loadRejectedKinds: { [] }, saveRejectedKinds: { _ in }, bundledBuild: { "build-a" }, systemProxyConfigured: { false },
            liveTerminals: { _ in live }, checkInterval: nil))
        let model = PairedDevicesModel(store: world.store, authorizedKeys: world.authorizedKeys)
        let shown = ShownProxySetting(nil)
        let host = show(FollowingProxyPages(shown: shown, service: service, model: model, coordinator: nil), height: 1000)
        let id = "settings.devices.conversations"

        var ax = accessibility(host)
        check(ax[id] != nil && isEnabled(ax[id]) && texts(host).contains("Show Conversations on iPhone and iPad") && !service.isOn,
              "iPhone and iPad page: the setting, off, can be turned on")
        let about = label(ax[id + ".about"])
        check(about.contains("Remote Control is turned off") && about.contains("“Background Items Added” notification")
              && about.contains("Claude Code, Codex and Pi"), "…saying Remote Control goes off and macOS's notification comes")
        check(ax[id + ".status"] == nil && ax[id + ".unavailable"] == nil, "…with nothing more while off")

        press(ax[id])
        check(drainUntil { service.isOn && service.phase == .running } && setting && agent.registered == 1, "turned on: saved, registered, running")
        check(drainUntil { label(accessibility(host)[id + ".status"]).contains("The proxy is running") }, "…and said so")

        // Turned off while two agents use it: it stays until they have ended.
        let route = { (n: Int) in AgentProxyRoute(routeID: "r\(n)", kind: .claude, session: "default", paneID: "w1:p\(n)", terminalID: "t\(n)",
                                                   cliVersion: "2.1.290", createdAt: "2026-10-22T00:00:00Z", oauthRejected: false, inFlight: 0) }
        _ = run { await control.setRoutes([route(1), route(2)]) }
        live = ["t1", "t2"]
        press(accessibility(host)[id])
        check(drainUntil { !service.isOn && service.phase == .stopping(agents: 2) } && !setting && agent.unregistered == 0,
              "turned off with 2 agents on it: still registered")
        check(drainUntil { label(accessibility(host)[id + ".status"]).contains("Stops once the 2 agents using it have ended.") },
              "…and says it stops once they have ended")
        live = []
        _ = run { await service.check() }
        check(drainUntil { service.phase == .off } && agent.unregistered == 1 && drainUntil { accessibility(host)[id + ".status"] == nil },
              "their panes gone: unregistered, and nothing more said")

        // Another machine shown: greyed out, with why, and pressing does nothing.
        let reason = "Connect to This Mac to change this setting."
        shown.reason = reason
        check(drainUntil { !isEnabled(accessibility(host)[id]) && label(accessibility(host)[id + ".unavailable"]).contains(reason) },
              "another machine: greyed out, with why under it")
        press(accessibility(host)[id])
        drain(0.3)
        check(!service.isOn && agent.registered == 1, "…and pressing it changes nothing")
        shown.reason = nil
        check(drainUntil { isEnabled(accessibility(host)[id]) && accessibility(host)[id + ".unavailable"] == nil }, "This Mac again: it can be changed")

        // Turned off in Login Items: said so, with the way there.
        agent.registeredState = .requiresApproval
        press(accessibility(host)[id])
        check(drainUntil { service.isOn && service.phase == .needsApproval }, "Login Items has it off: shown so")
        ax = accessibility(host)
        check(label(ax[id + ".status"]).contains("Login Items") && ax[id + ".login-items"] != nil, "…with Open Login Items Settings…")
        press(ax[id + ".login-items"])
        check(drainUntil { agent.opened == 1 }, "…which asks the LaunchAgent's stand-in to open them")

        // The Add page: the same setting, the same state.
        let coordinator = PairingCoordinator(environment: world.environment())
        let addHost = show(FollowingProxyPages(shown: shown, service: service, model: model, coordinator: coordinator), height: 1700)
        let addID = "settings.pair.conversations"
        check(drainUntil { accessibility(addHost)[addID] != nil && label(accessibility(addHost)[addID + ".status"]).contains("Login Items") },
              "Add page: the same setting, as it is")
        agent.registeredState = .enabled
        press(accessibility(addHost)[addID])
        check(drainUntil { !service.isOn } && !setting, "turned off from the Add page: the same setting")
        shown.reason = reason
        check(drainUntil { !isEnabled(accessibility(addHost)[addID]) && label(accessibility(addHost)[addID + ".unavailable"]).contains(reason) },
              "Add page, another machine: greyed out, with why")
        check(windows.allSatisfy { !$0.isVisible }, "the pages were never shown")
        coordinator.stop()
    }
}
