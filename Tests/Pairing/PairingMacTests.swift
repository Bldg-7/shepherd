import CryptoKit
import Darwin
import Foundation

// The Mac side of pairing by QR code (SHPHRD-77), without the app: the
// address selector from made-up networks, the Tailscale name lookups with a
// stand-in resolver, the listener's filter, authorized_keys in a temporary
// home folder, the device list and history in a temporary folder, the
// installation ID in memory, the QR code read back with Core Image, and the
// coordinator end to end with a device on 127.0.0.1 — codes, requests,
// answers and limits. Run in a sandbox that reaches only loopback.

@main enum PairingMacTests {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        addressOptions()
        listenerFilter()
        await tailscaleLookup()
        firewallParsing()
        authorizedKeys(root.appending(path: "keys"))
        deviceStore(root.appending(path: "store"))
        installationID()
        qrCode()
        systemSnapshot()
        await coordinatorCodes(root.appending(path: "codes"))
        await roundTrip(root.appending(path: "trip"))
        await answers(root.appending(path: "answers"))
        await cancelled(root.appending(path: "cancelled"))
        await listenerLimits(root.appending(path: "limits"))
        Checks.finish("Mac pairing checks: address selector, Tailscale names, filter, authorized_keys, device list and history, installation ID, QR code, coordinator on loopback")
    }

    static let ts = Net.tailscaleAddress
    static let magic = try! PairingAddress(kind: .tailscaleMagicDNS, name: Net.magicDNSName)

    // MARK: - Address selector

    static func addressOptions() {
        typealias O = PairingAddressOptions
        let ip = Net.ip

        // Wi-Fi only.
        let wifiOnly = NetworkSnapshot(interfaces: [Net.wifi("192.168.0.12")], services: [Net.service("W", "Wi-Fi", "en0")],
                                       localHostName: "Minsus-MacBook-Pro")
        var options = O.options(snapshot: wifiOnly, tailscaleNames: [:])
        check(options.map(\.kind) == [.localName, .privateIPv4], "Wi-Fi only: a .local name and a private IPv4 address")
        check(options.first?.address.hostname == "minsus-macbook-pro.local" && options.first?.localAddresses == [ip("192.168.0.12")],
              "the .local name is the local host name, lower-cased, answered on Wi-Fi's address")
        check(options.last?.address.hostname == "192.168.0.12" && options.last?.title == "Private IPv4 · Wi-Fi"
              && options.last?.interfaceName == "en0", "the private row is Wi-Fi's address, named after its service")
        check(O.defaultOption(in: options, lastKind: nil)?.kind == .localName, "Wi-Fi only: .local comes before private IPv4")

        // Wi-Fi and wired, the wired service first.
        let both = NetworkSnapshot(interfaces: [Net.wifi("192.168.0.12"), Net.ethernet("10.0.1.5", name: "en7")],
                                   services: [Net.service("E", "USB 10/100/1000 LAN", "en7"), Net.service("W", "Wi-Fi", "en0")],
                                   localHostName: "Minsus-MacBook-Pro")
        options = O.options(snapshot: both, tailscaleNames: [:])
        check(options.map(\.title) == [".local Name", "Private IPv4 · USB 10/100/1000 LAN", "Private IPv4 · Wi-Fi"],
              "Wi-Fi and wired: a private row for each, in service order")
        check(options.first?.localAddresses == [ip("10.0.1.5"), ip("192.168.0.12")], ".local is answered on both")
        check(O.defaultOption(in: options, lastKind: .privateIPv4)?.interfaceName == "en7",
              "last time's private IPv4: the first private row")

        // Bridges, virtual machines and a company VPN's 10.x tunnel.
        let virtual = NetworkSnapshot(
            interfaces: [Net.wifi("192.168.0.12"), Net.ethernet("192.168.64.1", name: "bridge100"), Net.ethernet("172.16.5.1", name: "vmnet8"),
                         Net.tunnel("utun3", "10.8.0.2", ula: false), Net.ethernet("192.168.2.1", name: "ap1")],
            services: [Net.service("W", "Wi-Fi", "en0"), Net.service("B", "Thunderbolt Bridge", "bridge100"), Net.service("V", "VMware", "vmnet8"),
                       Net.service("C", "Company VPN", "utun3"), Net.service("A", "Access Point", "ap1")],
            localHostName: "mac")
        options = O.options(snapshot: virtual, tailscaleNames: [:])
        check(options.map(\.title) == [".local Name", "Private IPv4 · Wi-Fi"], "bridge100, vmnet8, a 10.x VPN tunnel and ap1 give no rows")
        check(options.first?.localAddresses == [ip("192.168.0.12")], ".local is answered only on Wi-Fi's address")
        check(O.tailscaleCandidates(in: virtual).isEmpty, "a 10.x tunnel isn't a Tailscale candidate")

        // A tunnel with a 100.64/10 address and nothing else.
        let tunnelOnly = NetworkSnapshot(interfaces: [Net.tunnel("utun4", "100.101.102.103", ula: false)], localHostName: "mac")
        check(O.tailscaleCandidates(in: tunnelOnly).map(\.address) == [ts], "utun with 100.101.102.103 is a candidate")
        check(O.options(snapshot: tunnelOnly, tailscaleNames: [:]).isEmpty, "100.x alone isn't taken for Tailscale")
        for result: TailscaleNameLookup.Result in [.noName, .otherName, .timedOut] {
            check(O.options(snapshot: tunnelOnly, tailscaleNames: [ts: result]).isEmpty, "100.x with a lookup giving \(result): nothing")
        }
        check(O.options(snapshot: tunnelOnly, tailscaleNames: [ts: .tailscaleNameOnly]).map(\.kind) == [.tailscaleIPv4],
              "a .ts.net reverse name confirms Tailscale IPv4, without MagicDNS")
        options = O.options(snapshot: tunnelOnly, tailscaleNames: [ts: .magicDNS(magic)])
        check(options.map(\.kind) == [.tailscaleIPv4, .tailscaleMagicDNS] && options.last?.address == magic
              && options.last?.localAddresses == [ts], "a MagicDNS name both ways: Tailscale IPv4 and MagicDNS")

        // The same with Tailscale's IPv6 prefix on the tunnel.
        let tunnelWithULA = NetworkSnapshot(interfaces: [Net.tunnel("utun4", "100.101.102.103", ula: true)], localHostName: "mac")
        check(O.options(snapshot: tunnelWithULA, tailscaleNames: [:]).map(\.kind) == [.tailscaleIPv4], "fd7a:115c:a1e0::/48 confirms Tailscale without a lookup")
        check(O.options(snapshot: tunnelWithULA, tailscaleNames: [ts: .noName]).map(\.kind) == [.tailscaleIPv4], "MagicDNS off: no MagicDNS row")

        // Tailscale's own addresses and a tunnel that isn't point-to-point.
        let reserved = NetworkSnapshot(interfaces: [Net.tunnel("utun5", "100.100.100.100", ula: true), Net.tunnel("utun6", "100.115.92.5", ula: true),
                                                    NetworkSnapshot.Interface(name: "utun7", ipv4: [ts], ipv6: [Net.tailscaleULA])])
        check(O.tailscaleCandidates(in: reserved).isEmpty, "100.100.100.100, 100.115.92.0/23 and a tunnel that isn't point-to-point aren't candidates")

        // Carrier NAT on Wi-Fi.
        let carrier = NetworkSnapshot(interfaces: [Net.wifi("100.72.1.5")], services: [Net.service("W", "Wi-Fi", "en0")], localHostName: "mac")
        check(O.options(snapshot: carrier, tailscaleNames: [:]).isEmpty && O.tailscaleCandidates(in: carrier).isEmpty,
              "a carrier NAT address on Wi-Fi gives nothing")

        // No local host name.
        let unnamed = NetworkSnapshot(interfaces: [Net.wifi("192.168.0.12")], services: [Net.service("W", "Wi-Fi", "en0")], localHostName: nil)
        check(O.options(snapshot: unnamed, tailscaleNames: [:]).map(\.kind) == [.privateIPv4], "no LocalHostName: no .local row")
        let oddName = NetworkSnapshot(interfaces: [Net.wifi("192.168.0.12")], services: [Net.service("W", "Wi-Fi", "en0")], localHostName: "Minsu's Mac")
        check(O.options(snapshot: oddName, tailscaleNames: [:]).map(\.kind) == [.privateIPv4], "a LocalHostName that isn't one DNS label: no .local row")

        // No local network.
        var down = Net.wifi("192.168.0.12")
        down.isRunning = false
        check(O.options(snapshot: NetworkSnapshot(interfaces: [down], services: [Net.service("W", "Wi-Fi", "en0")], localHostName: "mac"),
                        tailscaleNames: [:]).isEmpty, "Wi-Fi that isn't running: nothing")
        check(O.options(snapshot: NetworkSnapshot(interfaces: [Net.wifi("192.168.0.12")], services: [], localHostName: "mac"),
                        tailscaleNames: [:]).isEmpty, "an interface no active service uses: nothing")
        var pointToPoint = Net.ethernet("192.168.3.4", name: "en9")
        pointToPoint.isPointToPoint = true
        var noBroadcast = Net.ethernet("192.168.5.6", name: "en10")
        noBroadcast.isBroadcast = false
        let other = NetworkSnapshot.Interface(name: "en11", hardware: .other, isBroadcast: true, ipv4: [ip("192.168.6.7")])
        check(O.options(snapshot: NetworkSnapshot(interfaces: [pointToPoint, noBroadcast, other],
                                                  services: [Net.service("P", "P", "en9"), Net.service("N", "N", "en10"), Net.service("O", "O", "en11")],
                                                  localHostName: "mac"), tailscaleNames: [:]).isEmpty,
              "point-to-point, non-broadcast and non-Wi-Fi, non-Ethernet interfaces give nothing")
        let linkLocal = NetworkSnapshot(interfaces: [Net.ethernet("169.254.3.4", name: "en5")], services: [Net.service("T", "Thunderbolt", "en5")],
                                        localHostName: "mac")
        options = O.options(snapshot: linkLocal, tailscaleNames: [:])
        check(options.map(\.kind) == [.localName] && options.first?.localAddresses == [ip("169.254.3.4")],
              "a link-local address only: .local, but no private IPv4 row")

        for (name, excluded) in [("bridge100", true), ("vmnet8", true), ("utun10", true), ("ap1", true), ("awdl0", true), ("llw0", true),
                                 ("anpi0", true), ("feth3", true), ("en0", false), ("bridge", false), ("apple0", false)] {
            check(O.isExcluded(name) == excluded, "\(name) is \(excluded ? "" : "not ")excluded")
        }

        // Every kind, and which is chosen.
        let all = NetworkSnapshot(interfaces: [Net.wifi("192.168.0.12"), Net.ethernet("10.0.1.5", name: "en7"),
                                               Net.tunnel("utun4", "100.101.102.103", ula: true)],
                                  services: [Net.service("W", "Wi-Fi", "en0"), Net.service("E", "Ethernet", "en7")], localHostName: "mac")
        options = O.options(snapshot: all, tailscaleNames: [ts: .magicDNS(magic)])
        check(options.map(\.kind) == [.localName, .privateIPv4, .privateIPv4, .tailscaleIPv4, .tailscaleMagicDNS],
              "the selector's order: .local, private rows, Tailscale IPv4, MagicDNS")
        check(O.defaultOption(in: options, lastKind: nil)?.kind == .tailscaleMagicDNS, "first visit: MagicDNS")
        check(O.defaultOption(in: options.filter { $0.kind != .tailscaleMagicDNS }, lastKind: nil)?.kind == .tailscaleIPv4, "then Tailscale IPv4")
        check(O.defaultOption(in: options.filter { !$0.kind.isName || $0.kind == .localName }.filter { $0.kind != .tailscaleIPv4 }, lastKind: nil)?.kind == .localName,
              "then .local")
        check(O.defaultOption(in: options, lastKind: .localName)?.kind == .localName, "last time's kind wins")
        check(O.defaultOption(in: options.filter { $0.kind != .tailscaleMagicDNS }, lastKind: .tailscaleMagicDNS)?.kind == .tailscaleIPv4,
              "last time's kind gone: the default order")
        check(O.defaultOption(in: [], lastKind: nil) == nil, "nothing to choose")

        // What happens to the chosen row.
        let wifiRow = options[1]
        if case .unchanged(let same) = O.reselect(wifiRow, in: options) { check(same == wifiRow, "the same row") } else { check(false, "unchanged") }
        var moved = all
        moved.interfaces[0].ipv4 = [ip("192.168.0.40")]
        let movedOptions = O.options(snapshot: moved, tailscaleNames: [ts: .magicDNS(magic)])
        if case .changed(let row) = O.reselect(wifiRow, in: movedOptions) {
            check(row.address.hostname == "192.168.0.40" && row.interfaceName == "en0", "Wi-Fi's new address: the same row, changed")
        } else { check(false, "a new address is a change") }
        var wifiGone = all
        wifiGone.services.removeFirst()
        if case .changed(let row) = O.reselect(wifiRow, in: O.options(snapshot: wifiGone, tailscaleNames: [ts: .magicDNS(magic)])) {
            check(row.interfaceName == "en7", "Wi-Fi gone with Ethernet still there: Ethernet's private address")
        } else { check(false, "another private row is a change") }
        let magicRow = options.last!
        var tailscaleGone = all
        tailscaleGone.interfaces.removeLast()
        check(O.reselect(magicRow, in: O.options(snapshot: tailscaleGone, tailscaleNames: [:]))
              == .replaced(lost: .tailscaleMagicDNS, by: O.options(snapshot: tailscaleGone, tailscaleNames: [:])[0]),
              "Tailscale off with MagicDNS chosen: the first usable kind, .local, instead")
        check(O.reselect(magicRow, in: []) == .none(lost: .tailscaleMagicDNS), "nothing left")
        let localRow = options[0]
        var moreLAN = all
        moreLAN.interfaces[0].ipv4.append(ip("169.254.9.9"))
        if case .unchanged(let row) = O.reselect(localRow, in: O.options(snapshot: moreLAN, tailscaleNames: [:])) {
            check(row.localAddresses.contains(ip("169.254.9.9")), ".local with one more local address: unchanged, the filter takes it")
        } else { check(false, ".local's name didn't change") }
    }

    // MARK: - The listener's filter

    static func listenerFilter() {
        let ip = Net.ip
        let local = PairingAddressOption(address: try! PairingAddress(kind: .localName, name: "mac.local"),
                                         localAddresses: [ip("192.168.0.12"), ip("10.0.1.5")])
        let filter = PairingConnectionFilter(option: local)
        check(filter.allows(remote: ip("192.168.0.30"), local: ip("192.168.0.12")), ".local: a LAN device to Wi-Fi's address")
        check(filter.allows(remote: ip("10.0.1.9"), local: ip("10.0.1.5")), ".local: a LAN device to Ethernet's address")
        check(filter.allows(remote: ip("169.254.1.2"), local: ip("192.168.0.12")), ".local: from a link-local address")
        check(!filter.allows(remote: ip("192.168.0.30"), local: ts), ".local: not to the Tailscale address")
        check(!filter.allows(remote: ts, local: ip("192.168.0.12")), ".local: not from a Tailscale address")
        check(!filter.allows(remote: ip("8.8.8.8"), local: ip("192.168.0.12")), ".local: not from a public address")
        check(!filter.allows(remote: ip("127.0.0.1"), local: ip("127.0.0.1")), ".local: not over loopback")

        let privateRow = PairingAddressOption(address: try! PairingAddress(kind: .privateIPv4, ipv4: ip("192.168.0.12")),
                                              serviceName: "Wi-Fi", interfaceName: "en0", localAddresses: [ip("192.168.0.12")])
        let privateFilter = PairingConnectionFilter(option: privateRow)
        check(privateFilter.allows(remote: ip("192.168.0.30"), local: ip("192.168.0.12")), "private IPv4: to that address")
        check(!privateFilter.allows(remote: ip("10.0.1.9"), local: ip("10.0.1.5")), "private IPv4: not to another local address")

        for kind in [PairingAddressKind.tailscaleIPv4, .tailscaleMagicDNS] {
            let address = kind == .tailscaleIPv4 ? try! PairingAddress(kind: kind, ipv4: ts) : magic
            let tailscale = PairingConnectionFilter(option: PairingAddressOption(address: address, interfaceName: "utun4", localAddresses: [ts]))
            check(tailscale.allows(remote: ip("100.64.0.5"), local: ts), "\(kind): a tailnet node to the Tailscale address")
            check(!tailscale.allows(remote: ip("192.168.0.30"), local: ts), "\(kind): a LAN device gets no handshake")
            check(!tailscale.allows(remote: ip("192.168.0.30"), local: ip("192.168.0.12")), "\(kind): not to a LAN address")
            check(!tailscale.allows(remote: ip("100.64.0.5"), local: ip("192.168.0.12")), "\(kind): a tailnet node not to a LAN address")
            check(!tailscale.allows(remote: ip("100.100.100.100"), local: ts), "\(kind): not from quad-100")
            check(!tailscale.allows(remote: ip("100.115.92.7"), local: ts), "\(kind): not from 100.115.92.0/23")
            check(!tailscale.allows(remote: ip("100.128.0.1"), local: ts), "\(kind): not from beyond 100.64/10")
        }
    }

    // MARK: - Tailscale names

    static func tailscaleLookup() async {
        func lookUp(_ resolver: FakeTailscaleResolver, timeout: Duration = .milliseconds(300)) async -> TailscaleNameLookup.Result {
            await TailscaleNameLookup.lookUp(ts, resolver: resolver, timeout: timeout)
        }
        check(await lookUp(.magicDNS) == .magicDNS(magic), "PTR to a .ts.net name that leads back: MagicDNS")
        check(await lookUp(FakeTailscaleResolver(reverse: [ts: "Minsus-MBP.Tail1234.TS.NET"], forward: [Net.magicDNSName: [ts]]))
              == .magicDNS(magic), "a name in capitals is taken lower-cased")
        check(await lookUp(FakeTailscaleResolver()) == .noName, "no PTR: no name")
        check(await lookUp(FakeTailscaleResolver(reverseThrows: true)) == .noName, "a failed PTR lookup: no name")
        for name in ["host.example.com", "minsus-mbp.tail1234.ts.net.example.com", "xts.net", "minsus-mbp.tail1234.ts.network"] {
            check(await lookUp(FakeTailscaleResolver(reverse: [ts: name], forward: [name: [ts]])) == .otherName, "\(name) isn't a .ts.net name")
        }
        check(await lookUp(FakeTailscaleResolver(reverse: [ts: "tail1234.ts.net"], forward: ["tail1234.ts.net": [ts]])) == .tailscaleNameOnly,
              "a .ts.net name of three labels confirms Tailscale but isn't a MagicDNS row")
        check(await lookUp(FakeTailscaleResolver(reverse: [ts: Net.magicDNSName], forward: [Net.magicDNSName: [Net.ip("100.64.0.9")]]))
              == .tailscaleNameOnly, "a name leading to another address: Tailscale, no MagicDNS")
        check(await lookUp(FakeTailscaleResolver(reverse: [ts: Net.magicDNSName], forwardThrows: true)) == .tailscaleNameOnly,
              "a name that doesn't resolve: Tailscale, no MagicDNS")
        let start = Date()
        var slow = FakeTailscaleResolver.magicDNS
        slow.delay = .seconds(2)
        check(await lookUp(slow, timeout: .milliseconds(200)) == .timedOut, "a lookup that takes too long times out")
        check(Date().timeIntervalSince(start) < 1.5, "…without waiting for it")
        check(TailscaleNameLookup.timeout == .seconds(3), "the app waits three seconds for each lookup")
    }

    static func firewallParsing() {
        let cases: [(String, String, FirewallState)] = [
            ("Firewall is enabled. (State = 1) ", "Firewall has block all state set to disabled.", .on),
            ("Firewall is disabled. (State = 0)", "Firewall has block all state set to disabled.", .off),
            ("Firewall is enabled. (State = 1) ", "Firewall has block all state set to enabled.", .blocksAllIncoming),
            ("Firewall is set to block all non-essential incoming connections ", "", .blocksAllIncoming),
            ("Firewall is enabled. (State = 2) ", "", .blocksAllIncoming),
            ("", "", .unknown)
        ]
        for (global, all, expected) in cases {
            check(FirewallStatusReader.parse(globalState: global, blockAll: all) == expected, "firewall: \(global.isEmpty ? "nothing" : global) → \(expected)")
        }
    }

    // MARK: - authorized_keys

    static func deviceLine(_ name: String = "Minsu’s iPhone", id: UUID = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!) -> AuthorizedKeyLine {
        try! AuthorizedKeyLine(devicePublicKey: SSHP256PublicKey.blob(for: P256.Signing.PrivateKey().publicKey), deviceID: id, deviceName: name)
    }

    static func home(_ root: URL, _ name: String) -> URL {
        let url = root.appending(path: name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func mode(_ path: String) -> mode_t {
        var status = stat()
        return lstat(path, &status) == 0 ? status.st_mode & 0o7777 : 0
    }

    static func contents(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    static func write(_ text: String, to path: String, mode: mode_t = 0o600) {
        try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, mode)
    }

    static func refused(_ body: () throws -> Any) -> AuthorizedKeysFile.Problem? {
        do {
            _ = try body()
            return nil
        } catch AuthorizedKeysFileError.refused(let problem) {
            return problem
        } catch {
            return nil
        }
    }

    static func authorizedKeys(_ root: URL) {
        let line = deviceLine()

        // No ~/.ssh yet.
        let fresh = AuthorizedKeysFile(home: home(root, "fresh").path)
        check(fresh.inspect() == .writable, "no ~/.ssh: it can be made")
        check((try? fresh.add(line)) == .added, "no ~/.ssh: the line is added")
        check(mode(fresh.directoryPath) == 0o700 && mode(fresh.path) == 0o600, "~/.ssh is made 0700 and authorized_keys 0600")
        check(contents(fresh.path) == line.text + "\n", "the file is the line and a newline")
        check((try? fresh.add(line)) == .alreadyPresent && contents(fresh.path) == line.text + "\n", "the same key again: nothing written")
        check(fresh.contains(lineText: line.text) == true, "the line is found")
        let entry = AuthorizedKeysEntry(line: contents(fresh.path)!)
        check(entry?.options == "restrict,port-forwarding" && entry?.keyType == "ecdsa-sha2-nistp256"
              && entry?.comment == line.marker, "the line as sshd reads it: options, P-256 key, the marker")

        // Appending to a file that doesn't end in a newline.
        let existing = AuthorizedKeysFile(home: home(root, "existing").path)
        mkdir(existing.directoryPath, 0o700)
        let before = "# my keys\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey me@laptop"
        write(before, to: existing.path, mode: 0o644)
        check((try? existing.add(line)) == .added, "a line added to a file with keys in it, mode 0644")
        check(contents(existing.path) == before + "\n" + line.text + "\n", "the file kept as it was, with a newline before the new line")
        check(mode(existing.path) == 0o644, "its mode left alone")

        // The same key with other options and comment.
        let sameKey = AuthorizedKeysFile(home: home(root, "same-key").path)
        mkdir(sameKey.directoryPath, 0o700)
        let other = "from=\"10.0.0.1\" ecdsa-sha2-nistp256 \(line.keyBlob.base64EncodedString()) someone-else\n"
        write(other, to: sameKey.path)
        check((try? sameKey.add(line)) == .alreadyPresent && contents(sameKey.path) == other, "the key there with other options: not added again")
        check(sameKey.contains(lineText: line.text) == false, "…and that line isn't the device's")

        // A symbolic link, and the file it points to.
        let linked = AuthorizedKeysFile(home: home(root, "linked").path)
        mkdir(linked.directoryPath, 0o700)
        let target = root.appending(path: "linked-target").path
        write("ssh-ed25519 AAAA target\n", to: target)
        symlink(target, linked.path)
        check(refused { try linked.add(line) } == .fileIsSymbolicLink, "authorized_keys a symbolic link: refused")
        check(contents(target) == "ssh-ed25519 AAAA target\n", "…and what it points to untouched")
        check(linked.inspect() == .problem(.fileIsSymbolicLink), "inspect says so before anything is written")
        check(linked.contains(lineText: line.text) == nil, "a linked file isn't read as the page's")

        let linkedDirectory = AuthorizedKeysFile(home: home(root, "linked-directory").path)
        let realDirectory = root.appending(path: "real-ssh").path
        mkdir(realDirectory, 0o700)
        symlink(realDirectory, linkedDirectory.directoryPath)
        check(refused { try linkedDirectory.add(line) } == .directoryIsSymbolicLink, "~/.ssh a symbolic link: refused")
        check((try? FileManager.default.contentsOfDirectory(atPath: realDirectory))?.isEmpty == true, "…and nothing written there")

        let open = AuthorizedKeysFile(home: home(root, "open-directory").path)
        mkdir(open.directoryPath, 0o700)
        chmod(open.directoryPath, 0o777)
        check(refused { try open.add(line) } == .directoryWritableByOthers, "~/.ssh writable by others: refused")
        chmod(open.directoryPath, 0o755)
        check((try? open.add(line)) == .added, "~/.ssh 0755: written")

        let openFile = AuthorizedKeysFile(home: home(root, "open-file").path)
        mkdir(openFile.directoryPath, 0o700)
        write("", to: openFile.path, mode: 0o666)
        check(refused { try openFile.add(line) } == .fileWritableByOthers && contents(openFile.path) == "", "authorized_keys writable by others: refused")

        let directoryFile = AuthorizedKeysFile(home: home(root, "directory-file").path)
        mkdir(directoryFile.directoryPath, 0o700)
        mkdir(directoryFile.path, 0o700)
        check(refused { try directoryFile.add(line) } == .fileNotRegular, "authorized_keys a folder: refused")

        let fifo = AuthorizedKeysFile(home: home(root, "fifo").path)
        mkdir(fifo.directoryPath, 0o700)
        mkfifo(fifo.path, 0o600)
        check(refused { try fifo.add(line) } == .fileNotRegular, "authorized_keys a FIFO: refused, without waiting on it")

        // Removing: only the line with both the key and the marker.
        let removing = AuthorizedKeysFile(home: home(root, "removing").path)
        mkdir(removing.directoryPath, 0o700)
        let otherLine = deviceLine("Old iPad", id: UUID())
        let sameMarkerOtherKey = "restrict,port-forwarding ecdsa-sha2-nistp256 \(otherLine.keyBlob.base64EncodedString()) \(line.marker)"
        let sameKeyOtherComment = "ecdsa-sha2-nistp256 \(line.keyBlob.base64EncodedString()) laptop-copy"
        let kept = ["# keep me", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey me@laptop", "",
                    sameKeyOtherComment, sameMarkerOtherKey]
        let original = kept[0] + "\n" + kept[1] + "\n" + line.text + "\n" + kept[2] + "\n" + kept[3] + "\n" + kept[4]
        write(original, to: removing.path, mode: 0o640)
        check((try? removing.remove(lineText: line.text)) == .removed, "the device's line is removed")
        check(contents(removing.path) == kept.joined(separator: "\n"), "everything else kept byte for byte, the last line without its newline too")
        check(mode(removing.path) == 0o640, "the file's mode kept")
        check((try? FileManager.default.contentsOfDirectory(atPath: removing.directoryPath)) == ["authorized_keys"], "no file left beside it")
        check((try? removing.remove(lineText: line.text)) == .notFound && contents(removing.path) == kept.joined(separator: "\n"),
              "removed again: not found, nothing written")
        check((try? fresh.remove(lineText: deviceLine("Nobody", id: UUID()).text)) == .notFound, "a line never added: not found")

        // A file that changes while it is rewritten is left alone.
        var racing = AuthorizedKeysFile(home: home(root, "racing").path)
        mkdir(racing.directoryPath, 0o700)
        write(line.text + "\n", to: racing.path)
        let path = racing.path
        racing.beforeReplacing = {
            let handle = FileHandle(forWritingAtPath: path)!
            handle.seekToEndOfFile()
            handle.write(Data("ssh-ed25519 AAAA added-meanwhile\n".utf8))
            try? handle.close()
        }
        check({ () -> Bool in
            do { _ = try racing.remove(lineText: line.text); return false } catch AuthorizedKeysFileError.changedWhileWriting { return true } catch { return false }
        }(), "the file changed after it was read: removal stops")
        check(contents(racing.path) == line.text + "\nssh-ed25519 AAAA added-meanwhile\n", "…leaving the file as the other writer left it")
        check((try? FileManager.default.contentsOfDirectory(atPath: racing.directoryPath)) == ["authorized_keys"], "…and no file beside it")

        check(AuthorizedKeysFile.addCommand(for: line) == "printf '%s\\n' '\(line.text)' >> ~/.ssh/authorized_keys"
              && line.text.filter { $0 == "'" }.isEmpty, "the command to run by hand quotes a line that has no quote in it")
        check(AuthorizedKeyLine.slug(for: "Minsu’s iPhone") == "minsu-s-iphone", "the marker's slug")
    }

    // MARK: - Device list and history

    static func pairedDevice(_ line: AuthorizedKeyLine, name: String, at seconds: TimeInterval) -> PairedDevice {
        PairedDevice(deviceID: UUID(), name: name, model: "iPhone", appVersion: "1.0", keyFingerprint: line.fingerprint, line: line.text,
                     addedAt: Date(timeIntervalSince1970: seconds), addressKind: .privateIPv4)
    }

    static func deviceStore(_ root: URL) {
        let store = PairedDeviceStore(directory: root.appending(path: "support"))
        check((try? store.devices()) == [], "no file: no devices")
        let a = pairedDevice(deviceLine("Phone A"), name: "Phone A", at: 1_000)
        let b = pairedDevice(deviceLine("Phone B"), name: "Phone B", at: 2_000)
        try? store.add(a)
        try? store.add(b)
        try? store.add(a)
        check((try? store.devices())?.map(\.name) == ["Phone B", "Phone A"], "two devices, the same one added again replaced")
        check(mode(store.devicesURL.path) == 0o600 && mode(store.directory.path) == 0o700, "the list 0600 in a 0700 folder")
        let json = contents(store.devicesURL.path) ?? ""
        check(json.contains("\"device_id\"") && json.contains("\"key_fingerprint\"") && json.contains("\"added_at\"")
              && !json.contains("psk") && !json.contains("secret") && !json.contains("BEGIN"), "the list's JSON: names and fingerprints, no secrets")
        try? store.remove(a)
        check((try? store.devices())?.map(\.name) == ["Phone B"], "a device removed")
        for index in 0..<1005 {
            try? store.record(PairingAuditEntry(date: Date(timeIntervalSince1970: TimeInterval(index)), event: .requested, detail: "\(index)"))
        }
        let history = (try? store.history()) ?? []
        check(history.count == PairedDeviceStore.historyLimit && history.first?.detail == "5" && history.last?.detail == "1004",
              "the history keeps the last 1,000 entries")
        write("{not json", to: store.devicesURL.path)
        check((try? store.devices()) == nil && (try? store.add(b)) == nil && contents(store.devicesURL.path) == "{not json",
              "a damaged list is reported, not written over")

        // The page's model, against authorized_keys.
        let keysHome = home(root, "model-home")
        let keys = AuthorizedKeysFile(home: keysHome.path)
        let lineA = deviceLine("Phone A"), lineB = deviceLine("Phone B")
        _ = try? keys.add(lineA)
        let modelStore = PairedDeviceStore(directory: root.appending(path: "model-support"))
        let deviceA = pairedDevice(lineA, name: "Phone A", at: 1_000), deviceB = pairedDevice(lineB, name: "Phone B", at: 2_000)
        try? modelStore.add(deviceA)
        try? modelStore.add(deviceB)
        let model = PairedDevicesModel(store: modelStore, authorizedKeys: keys, now: { Date(timeIntervalSince1970: 3_000) })
        model.reload()
        check(model.rows.map(\.device.name) == ["Phone B", "Phone A"] && model.rows.map(\.status) == [.notInFile, .inFile],
              "the list, newest first: a line taken out by hand shows as not in the file")
        model.remove(model.rows[1])
        check(keys.contains(lineText: lineA.text) == false && model.rows.map(\.device.name) == ["Phone B"]
              && model.history.first?.event == .removed, "removing a device takes its line out and forgets it")
        model.remove(model.rows[0])
        check(model.rows.isEmpty && model.history.first?.event == .removedNotInFile, "removing one already gone from the file")

        let linkedHome = home(root, "model-linked")
        mkdir(linkedHome.path + "/.ssh", 0o700)
        let target = root.appending(path: "model-linked-target").path
        write(lineA.text + "\n", to: target)
        symlink(target, linkedHome.path + "/.ssh/authorized_keys")
        let linkedStore = PairedDeviceStore(directory: root.appending(path: "model-linked-support"))
        try? linkedStore.add(deviceA)
        let linkedModel = PairedDevicesModel(store: linkedStore, authorizedKeys: AuthorizedKeysFile(home: linkedHome.path))
        linkedModel.reload()
        check(linkedModel.rows.map(\.status) == [.unknown], "a linked authorized_keys isn't read")
        linkedModel.remove(linkedModel.rows[0])
        check(linkedModel.removalFailure?.line == lineA.text && linkedModel.rows.count == 1 && contents(target) == lineA.text + "\n",
              "a device whose line can't be taken out stays, with the line to remove by hand")
    }

    static func installationID() {
        let memory = MemoryPreferences()
        let preferences = memory.preferences
        let first = preferences.installationID()
        check(preferences.installationID() == first && memory.all[PairingPreferences.installationIDKey] == first.uuidString,
              "the installation ID is made once and kept")
        let damaged = MemoryPreferences()
        damaged.preferences.write(PairingPreferences.installationIDKey, "not-a-uuid")
        let replaced = damaged.preferences.installationID()
        check(damaged.memoryValue(PairingPreferences.installationIDKey) == replaced.uuidString, "a damaged one is made again")
        preferences.setLastAddressKind(.privateIPv4)
        check(preferences.lastAddressKind == .privateIPv4 && memory.all[PairingPreferences.lastAddressKindKey] == "privateIPv4",
              "only the kind is kept, never the address")
        preferences.write(PairingPreferences.lastAddressKindKey, "bogus")
        check(preferences.lastAddressKind == nil, "an unknown kind is none")
    }

    static func samplePayload(macName: String = "Minsu’s MacBook Pro", address: PairingAddress = magic) -> PairingPayload {
        try! PairingPayload(sessionID: Data(repeating: 1, count: 16), presharedKey: Data(repeating: 2, count: 32),
                            macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                            expiresAt: Date(timeIntervalSince1970: 1_800_000_120), pairingPort: 52_123, address: address,
                            hostKey: FakeProbe.hostKey, username: "minsu", macID: UUID(), macName: macName)
    }

    static func qrCode() {
        let text = try! samplePayload().encoded()
        guard let image = PairingQRCode.image(for: text) else { check(false, "a QR code is made"); return }
        check(PairingQRCode.messages(in: image) == [text], "the QR code reads back as the code's text (\(text.utf8.count) bytes)")
        let longName = String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 60) + "." + String(repeating: "c", count: 60) + ".ts.net"
        let long = try! samplePayload(macName: String(repeating: "Mac ", count: 50), address: try! PairingAddress(kind: .tailscaleMagicDNS, name: longName)).encoded()
        let longImage = PairingQRCode.image(for: long)
        check(longImage.map(PairingQRCode.messages(in:)) == [long], "a long name and Mac name read back too (\(long.utf8.count) bytes)")
        check(PairingQRCode.correctionLevel == "M", "medium error correction")
    }

    /// The real network's snapshot reads without trouble; nothing of it is printed.
    static func systemSnapshot() {
        let snapshot = NetworkSnapshotSource.current()
        check(snapshot.interfaces.contains { $0.name == "lo0" }, "the system's snapshot has lo0")
        _ = PairingAddressOptions.options(snapshot: snapshot, tailscaleNames: [:])
    }

    // MARK: - Coordinator: codes

    static func scanned(_ coordinator: PairingCoordinator) -> PairingPayload? {
        coordinator.code.flatMap { try? PairingPayload(scanned: $0.text) }
    }

    /// Sends `message` on a new connection and returns the answer frame.
    static func exchange(_ port: UInt16, _ message: Data) async -> Data? {
        guard let fd = await Wire.connect(port: port) else { return nil }
        defer { close(fd) }
        guard await Wire.send(fd, message) else { return nil }
        return await Wire.readFrame(fd)
    }

    static func failure(_ frame: Data?) -> PairingFailure? {
        frame.flatMap { try? PairingEnvelope(body: $0) }?.failure
    }

    static func started(_ world: PairingWorld) async -> PairingCoordinator {
        let coordinator = PairingCoordinator(environment: world.environment())
        coordinator.start()
        _ = await waitUntil { coordinator.hasLookedUpAddresses && coordinator.remoteLogin != .checking && coordinator.herdrIsRunning != nil && coordinator.firewall != nil }
        return coordinator
    }

    static func coordinatorCodes(_ root: URL) async {
        let world = PairingWorld(home: root)
        let coordinator = await started(world)
        check(coordinator.remoteLogin == .on(FakeProbe.hostKey) && coordinator.firewall == .off && coordinator.herdrIsRunning == true
              && coordinator.authorizedKeys == .writable, "the checks: Remote Login and its host key, firewall, herdr, authorized_keys")
        check(coordinator.options.map(\.kind) == [.localName, .privateIPv4, .tailscaleIPv4, .tailscaleMagicDNS], "every kind is offered")
        check(coordinator.selectedOption?.kind == .tailscaleMagicDNS, "first visit: MagicDNS is chosen")
        check(world.preferences.all[PairingPreferences.lastAddressKindKey] == nil, "a default isn't kept as a choice")
        check(coordinator.phase == .preparing && coordinator.code == nil && coordinator.canShowCode, "no code until it is asked for")

        coordinator.showCode()
        guard let first = coordinator.code, let payload = scanned(coordinator) else { check(false, "a code is shown"); return }
        check(coordinator.phase == .showingCode, "the code is shown")
        check(payload.address == magic && payload.hostKey == FakeProbe.hostKey && payload.username == "minsu" && payload.herdrSession.isEmpty
              && payload.sshPort == 22 && payload.macName == "Minsu’s MacBook Pro" && payload.macID == coordinator.installationID
              && coordinator.installationID == world.preferences.preferences.installationID(),
              "the code: the address chosen, the host key probed, the user, herdr's default session, port 22, the Mac's name and installation ID")
        check(payload.pairingPort == first.port && first.port >= 1024, "the listener's port, a user port (\(first.port))")
        check(payload.expiresAt == world.clock.now.addingTimeInterval(120) && coordinator.secondsLeft == 120, "good for 120 seconds")
        check(Set([payload.sessionID.count, payload.presharedKey.count]) == [16, 32] && payload.presharedKey != Data(repeating: 0, count: 32),
              "a 16-byte session ID and a 32-byte secret")

        // Another row: a new code, and the old one is turned away.
        coordinator.select(PairingAddressOption.ID(kind: .privateIPv4, interfaceName: "en0"))
        guard let second = coordinator.code else { check(false, "a code after choosing again"); return }
        check(second.sessionID != first.sessionID && scanned(coordinator)?.address.hostname == "192.168.0.12" && second.port == first.port,
              "choosing another address: a new code on the same listener")
        check(world.preferences.all[PairingPreferences.lastAddressKindKey] == "privateIPv4", "the choice is kept, as its kind")
        var stale = try! TestDevice(scanning: first.text)
        check(failure(await exchange(first.port, try! stale.request())) == .unknownSession, "the previous code's request: not shown anymore")
        check(coordinator.phase == .showingCode && coordinator.code?.sessionID == second.sessionID && coordinator.failureCount == 0,
              "…which uses nothing up and isn't counted as a failure")
        coordinator.select(PairingAddressOption.ID(kind: .privateIPv4, interfaceName: "en0"))
        check(coordinator.code?.sessionID == second.sessionID, "choosing the same row: the same code")

        // Wi-Fi's address changes.
        var moved = Net.home
        moved.interfaces[1].ipv4 = [Net.ip("192.168.0.40")]
        world.snapshot.value = moved
        coordinator.refreshAddresses(lookingUpAll: false)
        guard let third = coordinator.code else { check(false, "a code after the address changed"); return }
        check(third.sessionID != second.sessionID && scanned(coordinator)?.address.hostname == "192.168.0.40",
              "the chosen address changed: a new code with the new address")
        var stale2 = try! TestDevice(scanning: second.text)
        check(failure(await exchange(first.port, try! stale2.request())) == .unknownSession, "the code before it: turned away")

        // The chosen kind goes away.
        coordinator.select(PairingAddressOption.ID(kind: .tailscaleMagicDNS, interfaceName: nil))
        check(scanned(coordinator)?.address == magic, "MagicDNS chosen")
        var noTailscale = moved
        noTailscale.interfaces.removeLast()
        world.snapshot.value = noTailscale
        coordinator.refreshAddresses(lookingUpAll: false)
        check(coordinator.selectedOption?.kind == .localName && coordinator.addressNotice == .switched(from: .tailscaleMagicDNS, to: .localName)
              && scanned(coordinator)?.address.hostname == "minsus-macbook-pro.local", "Tailscale off: .local instead, with a notice, in a new code")
        check(world.preferences.all[PairingPreferences.lastAddressKindKey] == "tailscaleMagicDNS", "the switch isn't kept as a choice")

        // 120 seconds.
        guard let beforeExpiry = coordinator.code else { return }
        world.clock.advance(119)
        coordinator.tick()
        check(coordinator.code?.sessionID == beforeExpiry.sessionID && coordinator.secondsLeft == 1, "119 seconds in: the same code")
        world.clock.advance(1)
        coordinator.tick()
        check(coordinator.code.map { $0.sessionID != beforeExpiry.sessionID } == true && coordinator.secondsLeft == 120,
              "120 seconds in: a new code, good for another 120")
        var expired = try! TestDevice(scanning: beforeExpiry.text)
        check(failure(await exchange(first.port, try! expired.request())) == .expired, "the code that ran out: expired")

        // Ten minutes of listening.
        while coordinator.phase == .showingCode && world.clock.now.timeIntervalSince1970 < 1_800_000_000 + 600 {
            world.clock.advance(30)
            coordinator.tick()
        }
        check(coordinator.phase == .stopped(.timeLimit) && coordinator.code == nil, "ten minutes after the listener opened: it stops")
        check(world.clock.now.timeIntervalSince1970 == 1_800_000_600, "…at ten minutes")
        check(await Wire.connect(port: first.port) == nil, "…and nothing listens on its port")

        // Showing it again, then hiding it.
        coordinator.showCode()
        guard let again = coordinator.code else { check(false, "shown again"); return }
        check(coordinator.phase == .showingCode, "shown again, on a new listener")
        coordinator.hideCode()
        check(coordinator.phase == .preparing && coordinator.code == nil, "hidden")
        check(await Wire.connect(port: again.port) == nil, "hiding the code closes the listener")

        // Nothing usable.
        coordinator.showCode()
        world.snapshot.value = NetworkSnapshot()
        coordinator.refreshAddresses(lookingUpAll: false)
        check(coordinator.options.isEmpty && coordinator.selectedOption == nil && coordinator.addressNotice == .unavailable(.localName)
              && coordinator.phase == .preparing && coordinator.code == nil && !coordinator.canShowCode,
              "no address left: the code goes, and none can be shown")
        coordinator.stop()

        // Remote Login off, checked again every two seconds.
        let offWorld = PairingWorld(home: root.appending(path: "off"), probe: .off)
        let off = await started(offWorld)
        check(off.remoteLogin == .off && !off.canShowCode, "Remote Login off: no code")
        let calls = offWorld.probe.calls
        offWorld.clock.advance(1)
        off.tick()
        check(offWorld.probe.calls == calls, "not checked again within two seconds")
        offWorld.probe.result = .on(FakeProbe.hostKey)
        offWorld.clock.advance(1)
        off.tick()
        check(await waitUntil { off.remoteLogin == .on(FakeProbe.hostKey) } && off.canShowCode, "checked again at two seconds, and found on")
        off.stop()

        // A previous choice is chosen again.
        let returning = PairingWorld(home: root.appending(path: "returning"))
        returning.preferences.preferences.setLastAddressKind(.localName)
        let back = await started(returning)
        check(back.selectedOption?.kind == .localName, "last time's kind is chosen first")
        back.stop()
    }

    // MARK: - Coordinator: a pairing from start to end

    static func roundTrip(_ root: URL) async {
        let world = PairingWorld(home: root)
        let coordinator = await started(world)
        coordinator.select(PairingAddressOption.ID(kind: .privateIPv4, interfaceName: "en0"))
        coordinator.showCode()
        guard let code = coordinator.code, var device = try? TestDevice(scanning: code.text),
              let fd = await Wire.connect(port: code.port) else { check(false, "a device connects"); return }
        defer { close(fd) }
        check(await Wire.send(fd, try! device.request()), "M1 sent")
        check(await waitUntil { coordinator.phase == .request }, "the request is shown")
        guard let request = coordinator.request else { return }
        check(request.request.deviceName == "Minsu’s iPhone" && request.request.deviceModel == "iPhone" && request.request.deviceID == device.id
              && request.request.publicKey == device.publicKeyBlob, "the request: the device's name, model, ID and key")
        check(request.confirmationCode == device.channel.confirmationCode, "both ends show the same confirmation code (\(request.confirmationCode))")
        check(request.remote == PairingIPv4(127, 0, 0, 1) && request.addressKind == .privateIPv4, "where it came from, and over which kind")
        check(coordinator.code == nil, "the code is used up by its first request")

        await coordinator.approve()
        check(world.approval.reasons.count == 1 && world.approval.reasons[0].contains("Minsu’s iPhone"), "approving asks the owner, naming the device")
        check(coordinator.phase == .finishing, "approved: waiting for the device")
        let line = try! AuthorizedKeyLine(devicePublicKey: device.publicKeyBlob, deviceID: device.id, deviceName: device.name)
        check(contents(world.authorizedKeys.path) == line.text + "\n", "the device's line is in authorized_keys")
        check(mode(world.authorizedKeys.directoryPath) == 0o700 && mode(world.authorizedKeys.path) == 0o600, "in a 0700 ~/.ssh, 0600")
        check(coordinator.finished?.key == .added && coordinator.finished?.device.line == line.text
              && coordinator.finished?.device.keyFingerprint == line.fingerprint, "the result: the key added")
        check((try? world.store.devices()) == [coordinator.finished!.device], "the device is listed")

        guard let m2 = await Wire.readFrame(fd), let response = try? device.channel.openResponse(PairingEnvelope(body: m2)) else {
            check(false, "M2 arrives and opens"); return
        }
        check(response.decision == .approved && response.macID == coordinator.installationID, "M2: approved, with the Mac's installation ID")
        check(await Wire.connect(port: code.port) == nil, "the listener closed once approved")
        let report = PairingReport(sshConnected: true, herdrReached: true)
        check(await Wire.send(fd, try! device.channel.report(report)), "M3 sent")
        check(await waitUntil { coordinator.phase == .finished }, "the report arrives")
        check(coordinator.finished?.report == report && coordinator.finished?.reportMissing == false, "the result: SSH and herdr reached")
        check(await Wire.isClosed(fd), "the Mac closes the connection after the report")
        let events = ((try? world.store.history()) ?? []).map(\.event)
        check(events == [.requested, .approved, .keyAdded, .connectionChecked], "the history: requested, approved, key added, connection checked")
        check(((try? world.store.history()) ?? []).allSatisfy { $0.event == .requested || $0.deviceID == device.id }
              && ((try? world.store.history()) ?? []).first?.remoteAddress == "127.0.0.1", "with the device and where it came from")

        let machine = device.payload.machine()
        check(machine.id == coordinator.installationID && machine.pinnedHostKeyFingerprint == FakeProbe.hostKey.fingerprint
              && machine.addressKind == .privateIPv4 && machine.hostname == "192.168.0.12" && machine.authMethod == .secureEnclaveKey,
              "what the device saves: the installation ID, the pinned host key, the address and its kind")

        // Another device: the same key, a report that says it failed.
        coordinator.reset()
        coordinator.showCode()
        guard let code2 = coordinator.code, var device2 = try? TestDevice(scanning: code2.text),
              let fd2 = await Wire.connect(port: code2.port) else { check(false, "a second device connects"); return }
        defer { close(fd2) }
        let request2 = try! device2.channel.request(PairingRequest(deviceID: device.id, deviceName: device.name, deviceModel: "iPhone",
                                                                    appVersion: "1.0", publicKey: device.publicKeyBlob))
        _ = await Wire.send(fd2, request2)
        _ = await waitUntil { coordinator.phase == .request }
        await coordinator.approve()
        check(coordinator.finished?.key == .alreadyPresent && contents(world.authorizedKeys.path) == line.text + "\n",
              "the same key again: nothing written")
        _ = await Wire.readFrame(fd2)
        _ = await Wire.send(fd2, try! device2.channel.report(PairingReport(sshConnected: false, herdrReached: false, failure: "Permission denied")))
        check(await waitUntil { coordinator.phase == .finished } && coordinator.finished?.report?.sshConnected == false
              && coordinator.finished?.report?.failure == "Permission denied", "a failed first connection is reported as it was")
        coordinator.stop()

        // A device that never reports.
        let quiet = PairingWorld(home: root.appending(path: "quiet"))
        let quietCoordinator = await started(quiet)
        quietCoordinator.showCode()
        guard let code3 = quietCoordinator.code, var device3 = try? TestDevice(scanning: code3.text),
              let fd3 = await Wire.connect(port: code3.port) else { check(false, "a quiet device connects"); return }
        defer { close(fd3) }
        _ = await Wire.send(fd3, try! device3.request())
        _ = await waitUntil { quietCoordinator.phase == .request }
        await quietCoordinator.approve()
        check(await waitUntil(6) { quietCoordinator.phase == .finished } && quietCoordinator.finished?.reportMissing == true,
              "a device that doesn't report in time: said so")
        check(((try? quiet.store.history()) ?? []).last?.event == .connectionNotReported, "…and written down")
        quietCoordinator.stop()
    }

    // MARK: - Coordinator: answers

    static func answers(_ root: URL) async {
        let world = PairingWorld(home: root)
        let coordinator = await started(world)
        coordinator.showCode()

        // Turned down.
        guard let code = coordinator.code, var device = try? TestDevice(scanning: code.text),
              let fd = await Wire.connect(port: code.port) else { check(false, "a device connects"); return }
        _ = await Wire.send(fd, try! device.request())
        _ = await waitUntil { coordinator.phase == .request }
        coordinator.reject()
        let rejected = await Wire.readFrame(fd).flatMap { try? device.channel.openResponse(PairingEnvelope(body: $0)) }
        check(rejected?.decision == .rejected, "turned down: M2 says so")
        check(await Wire.isClosed(fd), "…and the connection ends")
        close(fd)
        check(coordinator.phase == .showingCode && coordinator.code.map { $0.sessionID != code.sessionID } == true
              && coordinator.lastDecision == .rejected("Minsu’s iPhone"), "a new code, with what happened to the last request")
        check(!FileManager.default.fileExists(atPath: world.authorizedKeys.path), "nothing written to authorized_keys")
        check(((try? world.store.history()) ?? []).map(\.event) == [.requested, .rejected], "the history: requested, rejected")

        // A second request for the same code, then no answer.
        guard let code2 = coordinator.code, var first = try? TestDevice(scanning: code2.text), var second = try? TestDevice(scanning: code2.text),
              let fd1 = await Wire.connect(port: code2.port) else { return }
        _ = await Wire.send(fd1, try! first.request())
        _ = await waitUntil { coordinator.phase == .request }
        check(failure(await exchange(code2.port, try! second.request())) == .alreadyUsed, "a second request for a used code: already used")
        check(coordinator.request?.laterRequests == 1 && coordinator.request?.request.deviceID == first.id,
              "the request shown says another came, and stays the first one's")
        check(((try? world.store.history()) ?? []).last?.event == .requestAfterUse, "the second request is written down")
        world.clock.advance(59)
        coordinator.tick()
        check(coordinator.phase == .request, "59 seconds without an answer: still waiting")
        world.clock.advance(1)
        coordinator.tick()
        let timedOut = await Wire.readFrame(fd1).flatMap { try? first.channel.openResponse(PairingEnvelope(body: $0)) }
        check(timedOut?.decision == .rejected && coordinator.lastDecision == .timedOut("Minsu’s iPhone") && coordinator.phase == .showingCode,
              "60 seconds without an answer: turned down, and a new code")
        check(((try? world.store.history()) ?? []).last?.event == .timedOut, "written down as timed out")
        close(fd1)

        // Authentication that fails, then works.
        guard let code3 = coordinator.code, var third = try? TestDevice(scanning: code3.text), let fd3 = await Wire.connect(port: code3.port) else { return }
        _ = await Wire.send(fd3, try! third.request())
        _ = await waitUntil { coordinator.phase == .request }
        world.approval.answers = ["Authentication was cancelled."]
        await coordinator.approve()
        check(coordinator.phase == .request && coordinator.request?.authenticationError == "Authentication was cancelled."
              && coordinator.request?.isAuthenticating == false && !FileManager.default.fileExists(atPath: world.authorizedKeys.path),
              "authentication cancelled: still waiting, nothing written")
        await coordinator.approve()
        check(coordinator.phase == .finishing && coordinator.finished?.key == .added, "authenticated the second time: approved")
        close(fd3)
        coordinator.stop()

        // Authentication still going after a minute, and after two.
        let slowWorld = PairingWorld(home: root.appending(path: "slow"))
        let slow = await started(slowWorld)
        slow.showCode()
        guard let code4 = slow.code, var fourth = try? TestDevice(scanning: code4.text), let fd4 = await Wire.connect(port: code4.port) else { return }
        _ = await Wire.send(fd4, try! fourth.request())
        _ = await waitUntil { slow.phase == .request }
        slowWorld.approval.holds = true
        let approving = Task { await slow.approve() }
        _ = await waitUntil { slow.request?.isAuthenticating == true }
        slowWorld.clock.advance(61)
        slow.tick()
        check(slow.phase == .request, "a minute in, with Touch ID or the password still asked for: still waiting")
        slowWorld.clock.advance(59)
        slow.tick()
        await approving.value
        let late = await Wire.readFrame(fd4).flatMap { try? fourth.channel.openResponse(PairingEnvelope(body: $0)) }
        check(slowWorld.approval.cancels == 1 && late?.decision == .rejected && slow.phase == .showingCode
              && !FileManager.default.fileExists(atPath: slowWorld.authorizedKeys.path), "two minutes in: the prompt is cancelled and the request turned down")
        close(fd4)

        // A request that doesn't open under the code's secret.
        guard let code5 = slow.code, var fifth = try? TestDevice(scanning: code5.text), let fd5 = await Wire.connect(port: code5.port) else { return }
        _ = await Wire.send(fd5, try! fifth.tamperedRequest())
        check(await Wire.isClosed(fd5), "a request under the wrong secret: the connection is closed without an answer")
        close(fd5)
        check(slow.phase == .showingCode && slow.code?.sessionID == code5.sessionID && slow.failureCount == 1,
              "…the code stays usable, and the failure is counted")
        guard let fd6 = await Wire.connect(port: code5.port) else { return }
        _ = await Wire.send(fd6, try! fifth.request())
        check(await waitUntil { slow.phase == .request }, "the real request for it still works")

        // The page closes with a request waiting.
        slow.stop()
        let closing = await Wire.readFrame(fd6).flatMap { try? fifth.channel.openResponse(PairingEnvelope(body: $0)) }
        check(closing?.decision == .rejected && slow.phase == .preparing, "the page closed: the waiting request is turned down")
        check(await Wire.connect(port: code5.port) == nil, "…and the listener is closed")
        close(fd6)

        // authorized_keys can't be written.
        let refusedWorld = PairingWorld(home: root.appending(path: "refused"))
        mkdir(root.appending(path: "refused-target").path, 0o700)
        symlink(root.appending(path: "refused-target").path, refusedWorld.authorizedKeys.directoryPath)
        let refusedCoordinator = await started(refusedWorld)
        check(refusedCoordinator.authorizedKeys == .problem(.directoryIsSymbolicLink), "the checks say the key can't be written")
        refusedCoordinator.showCode()
        guard let code7 = refusedCoordinator.code, var seventh = try? TestDevice(scanning: code7.text),
              let fd7 = await Wire.connect(port: code7.port) else { return }
        _ = await Wire.send(fd7, try! seventh.request())
        _ = await waitUntil { refusedCoordinator.phase == .request }
        await refusedCoordinator.approve()
        let line = try! AuthorizedKeyLine(devicePublicKey: seventh.publicKeyBlob, deviceID: seventh.id, deviceName: seventh.name)
        if case .notWritten(_, let command)? = refusedCoordinator.finished?.key {
            check(command == AuthorizedKeysFile.addCommand(for: line), "the key not written: the command to run instead")
        } else {
            check(false, "the key not written")
        }
        let approved = await Wire.readFrame(fd7).flatMap { try? seventh.channel.openResponse(PairingEnvelope(body: $0)) }
        check(approved?.decision == .approved && (try? refusedWorld.store.devices())?.count == 1,
              "…still approved and listed, for the line to be added by hand")
        check(((try? refusedWorld.store.history()) ?? []).map(\.event).contains(.keyNotWritten), "written down as not written")
        close(fd7)
        refusedCoordinator.stop()
    }

    // MARK: - Coordinator: a device that goes before the answer

    static func cancelled(_ root: URL) async {
        let world = PairingWorld(home: root)
        let coordinator = await started(world)
        coordinator.showCode()
        func written() -> Bool { FileManager.default.fileExists(atPath: world.authorizedKeys.path) }
        func events() -> [PairingAuditEntry.Event] { ((try? world.store.history()) ?? []).map(\.event) }

        // The device closes its connection while the request is on screen.
        guard let code = coordinator.code, var device = try? TestDevice(scanning: code.text),
              let fd = await Wire.connect(port: code.port) else { check(false, "a device connects"); return }
        _ = await Wire.send(fd, try! device.request())
        _ = await waitUntil { coordinator.phase == .request }
        close(fd)
        check(await waitUntil { coordinator.phase != .request }, "the device's connection ended: the request goes")
        check(coordinator.lastDecision == .cancelled("Minsu’s iPhone") && coordinator.phase == .showingCode
              && coordinator.code.map { $0.sessionID != code.sessionID } == true && coordinator.request == nil,
              "…said so over a new code")
        await coordinator.approve()
        check(!written() && coordinator.finished == nil && world.approval.reasons.isEmpty,
              "it can't be approved afterwards, the owner isn't asked, and authorized_keys is left as it was")
        check(events() == [.requested, .cancelled], "the history: requested, cancelled")

        // …while Touch ID or the password is being asked for.
        guard let code2 = coordinator.code, var second = try? TestDevice(scanning: code2.text),
              let fd2 = await Wire.connect(port: code2.port) else { check(false, "a second device connects"); return }
        _ = await Wire.send(fd2, try! second.request())
        _ = await waitUntil { coordinator.phase == .request }
        world.approval.holds = true
        let approving = Task { await coordinator.approve() }
        _ = await waitUntil { coordinator.request?.isAuthenticating == true }
        close(fd2)
        check(await waitUntil { coordinator.phase != .request }, "the device goes while the owner is asked: the request goes")
        await approving.value
        check(world.approval.cancels == 1 && coordinator.lastDecision == .cancelled("Minsu’s iPhone") && !written()
              && coordinator.finished == nil, "…the prompt is cancelled and nothing is written")

        // …and when the approval comes before the main actor hears of it.
        guard let code3 = coordinator.code, var third = try? TestDevice(scanning: code3.text),
              let fd3 = await Wire.connect(port: code3.port) else { check(false, "a third device connects"); return }
        _ = await Wire.send(fd3, try! third.request())
        _ = await waitUntil { coordinator.phase == .request }
        close(fd3)
        // The connection hears of the end on its own queue; the main actor waits here.
        usleep(300_000)
        await coordinator.approve()
        check(coordinator.phase == .showingCode && coordinator.lastDecision == .cancelled("Minsu’s iPhone") && !written()
              && coordinator.finished == nil && !events().contains(.approved) && ((try? world.store.devices()) ?? []).isEmpty,
              "an approval that finds the device gone writes nothing and lists nothing")
        coordinator.stop()
    }

    // MARK: - Listener limits

    static func listenerLimits(_ root: URL) async {
        check(PairingListener.handshakeTimeout == .seconds(10) && PairingCoordinator.codeLifetime == 120 && PairingCoordinator.listenerLifetime == 600
              && PairingCoordinator.failureLimit == 20 && PairingCoordinator.approvalTimeout == 60 && PairingCoordinator.authenticationLimit == 120
              && PairingCoordinator.reportTimeout == .seconds(60) && PairingCoordinator.remoteLoginRecheck == 2,
              "the limits: 10 s to the first message, codes of 120 s, ten minutes, 20 failures, a minute to answer")

        let world = PairingWorld(home: root)
        let coordinator = await started(world)
        coordinator.showCode()
        guard let code = coordinator.code else { return }

        // One connection waiting at a time.
        guard let idle = await Wire.connect(port: code.port) else { check(false, "a connection that sends nothing"); return }
        try? await Task.sleep(for: .milliseconds(50))
        let start = Date()
        guard let second = await Wire.connect(port: code.port) else { check(false, "a second connection"); return }
        check(await Wire.isClosed(second), "a connection while another waits for its first message: closed")
        check(Date().timeIntervalSince(start) < 0.4, "…at once")
        close(second)
        check(await Wire.isClosed(idle), "the one that sent nothing is closed after its time")
        check(Date().timeIntervalSince(start) >= 0.3, "…not before")
        close(idle)
        check(await waitUntil { coordinator.failureCount == 1 }, "…and counted as a failure")

        // Things that aren't a request.
        if let oversized = await Wire.connect(port: code.port) {
            _ = await Wire.send(oversized, Data([0, 0, 0x24, 0]) + Data(repeating: 0, count: 64))
            check(await Wire.isClosed(oversized), "a frame said to be over 8 KiB: closed")
            close(oversized)
        }
        check(await waitUntil { coordinator.failureCount == 2 }, "…and counted")
        if let garbage = await Wire.connect(port: code.port) {
            _ = await Wire.send(garbage, try! PairingProtocol.frame(Data("hello".utf8)))
            check(await Wire.isClosed(garbage), "a frame that isn't a message: closed")
            close(garbage)
        }
        check(await waitUntil { coordinator.failureCount == 3 }, "…and counted")
        let unknown = try! TestDevice(scanning: code.text)
        var unknownChannel = try! PairingDeviceChannel(sessionID: Data(repeating: 9, count: 16), presharedKey: unknown.payload.presharedKey,
                                                       macPublicKey: unknown.payload.macPublicKey)
        let unknownRequest = try! unknownChannel.request(PairingRequest(deviceID: unknown.id, deviceName: "x", deviceModel: "iPhone", appVersion: "1",
                                                                        publicKey: unknown.publicKeyBlob))
        check(failure(await exchange(code.port, unknownRequest)) == .unknownSession, "a request for a code never shown: unknown")
        check(await waitUntil { coordinator.failureCount == 4 }, "…and counted")

        // Twenty and the listener closes.
        while coordinator.failureCount < PairingCoordinator.failureLimit - 1 {
            let before = coordinator.failureCount
            _ = await exchange(code.port, unknownRequest)
            guard await waitUntil(5, { coordinator.failureCount == before + 1 }) else { check(false, "each failure counted"); break }
        }
        check(coordinator.phase == .showingCode, "nineteen failures: still listening")
        _ = await exchange(code.port, unknownRequest)
        check(await waitUntil { coordinator.phase == .stopped(.tooManyFailures) }, "the twentieth: listening stops")
        check(await Wire.connect(port: code.port) == nil, "…and nothing listens on the port")
        check(((try? world.store.history()) ?? []).last?.event == .tooManyFailures, "…which is written down")
        coordinator.showCode()
        check(coordinator.phase == .showingCode && coordinator.failureCount == 0, "shown again: counting starts over")
        coordinator.stop()

        // The listener's filter, on its own.
        let counter = ListenerCounter()
        let listener = PairingListener(handshakeTimeout: .milliseconds(300), onFirstFrame: { _, connection in
            counter.lock.lock(); counter.frames += 1; counter.lock.unlock()
            connection.close()
        }, onHandshakeFailure: { _, _ in
            counter.lock.lock(); counter.failures += 1; counter.lock.unlock()
        })
        guard let port = try? listener.start(on: .loopback, filter: PairingConnectionFilter(sources: .lan, destinations: [Net.ip("192.168.0.12")])) else {
            check(false, "a listener on loopback"); return
        }
        if let refused = await Wire.connect(port: port) {
            _ = await Wire.send(refused, try! PairingProtocol.frame(Data("SHP1".utf8)))
            check(await Wire.isClosed(refused), "a connection the filter doesn't let through: closed")
            close(refused)
        }
        listener.setFilter(nil)
        if let none = await Wire.connect(port: port) {
            check(await Wire.isClosed(none), "no filter: nothing let through")
            close(none)
        }
        listener.setFilter(PairingConnectionFilter(sources: .ranges([IPv4Range(PairingIPv4(127, 0, 0, 0), prefixLength: 8)]),
                                                   destinations: [PairingIPv4(127, 0, 0, 1)]))
        if let allowed = await Wire.connect(port: port) {
            _ = await Wire.send(allowed, try! PairingProtocol.frame(Data("SHP1".utf8)))
            check(await Wire.isClosed(allowed), "a connection let through is handed on with its first frame")
            close(allowed)
        }
        try? await Task.sleep(for: .milliseconds(100))
        let (frames, failures) = counter.lock.withLock { (counter.frames, counter.failures) }
        check(frames == 1 && failures == 0, "only the connection let through reached the handler, and nothing was counted for the others")
        check(listener.isListening, "listening")
        listener.stop()
        let afterStop = await Wire.connect(port: port)
        check(!listener.isListening && afterStop == nil, "stopped: the port is closed")
    }
}

nonisolated final class ListenerCounter: @unchecked Sendable {
    let lock = NSLock()
    var frames = 0
    var failures = 0
}

extension MemoryPreferences {
    func memoryValue(_ key: String) -> String? { all[key] }
}
