import AppKit
import SwiftUI

// Adding a herdr machine or a device only while the window shows This Mac
// (SHPHRD-110), without the app or a window: the rule for each kind of
// machine, the launcher's Add herdr Machine… row it makes, and the menus'
// Add herdr Machine… item as AppKit gets it from SwiftUI (NSHostingMenu,
// never opened): its title, the reason under it, whether it can be chosen,
// and that choosing it runs its action only when it can be.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

let herdrReason = "Connect to This Mac to add a herdr machine."
let deviceReason = "Connect to This Mac to add a device."

let thisMac = Machine(id: UUID(uuidString: "79763D9A-997B-4E75-A3FA-6EF5D0338479")!, displayName: "This Mac", hostname: "localhost",
                      port: 0, username: "minsu", isLocal: true)
let sshHost = Machine(displayName: "workbox", hostname: "workbox.example", username: "minsu")
let pairedMac = Machine(displayName: "Minsu’s MacBook Pro", hostname: "minsus-macbook-pro.local", username: "minsu",
                        authMethod: .secureEnclaveKey, addressKind: .localName)
/// An SSH machine named and set up like This Mac: only `isLocal` counts.
let lookalike = Machine(displayName: "This Mac", hostname: "localhost", port: 22, username: "minsu")

func ruleTests() {
    for addition in [LocalOnlyAddition.herdrMachine, .device] {
        expect(addition.unavailableReason(on: thisMac) == nil, "\(addition) on This Mac: allowed")
    }
    for machine in [sshHost, pairedMac, lookalike] {
        expect(LocalOnlyAddition.herdrMachine.unavailableReason(on: machine) == herdrReason, "a herdr machine on \(machine.displayName) (\(machine.hostname)): why not")
        expect(LocalOnlyAddition.device.unavailableReason(on: machine) == deviceReason, "a device on \(machine.displayName) (\(machine.hostname)): why not")
    }
    expect(LocalOnlyAddition.herdrMachine.unavailableReason(on: nil) == herdrReason && LocalOnlyAddition.device.unavailableReason(on: nil) == deviceReason,
           "no machine shown: not allowed either")
}

func launcherTests() {
    let host = LaunchTarget(herdrMachine: nil, label: "workbox", workspaces: [], unavailableReason: nil)
    let tooOld = "This machine's herdr is older than 0.9.0, the first to save machines. Update herdr to add machines to it."
    expect(AddHerdrMachineOffer(on: thisMac, herdrBlocker: nil).unavailableReason == nil, "This Mac whose herdr can have them: the row can be used")
    expect(AddHerdrMachineOffer(on: thisMac, herdrBlocker: tooOld).unavailableReason == tooOld, "This Mac with a herdr too old: herdr's reason, as before")
    expect(AddHerdrMachineOffer(on: thisMac, herdrBlocker: "Loading…").unavailableReason == "Loading…", "This Mac still loading: as before")
    for machine in [sshHost, pairedMac] {
        expect(AddHerdrMachineOffer(on: machine, herdrBlocker: nil).unavailableReason == herdrReason, "\(machine.displayName) whose herdr could: This Mac's reason")
        expect(AddHerdrMachineOffer(on: machine, herdrBlocker: tooOld).unavailableReason == herdrReason, "\(machine.displayName) with a herdr too old: This Mac's reason first")
    }
    let remote = LauncherMachineStep(targets: [host], addHerdrMachine: AddHerdrMachineOffer(on: sshHost, herdrBlocker: nil))
    let entries = remote.entries(matching: "")
    expect(entries.map(\.id) == ["target/host", "add-herdr-machine"] && entries.map(\.isEnabled) == [true, false],
           "another machine's launcher: the row is still there, last, greyed out: \(entries.map(\.id)) \(entries.map(\.isEnabled))")
    if case .addHerdrMachine(let offer) = entries.last {
        expect(offer.unavailableReason == herdrReason, "…with why beside it, where herdr's reason goes")
    } else {
        expect(false, "the Add row")
    }
    expect(remote.canGoBack, "Backspace still goes back to it")
    let local = LauncherMachineStep(targets: [host], addHerdrMachine: AddHerdrMachineOffer(on: thisMac, herdrBlocker: nil))
    expect(local.entries(matching: "").allSatisfy(\.isEnabled), "This Mac's launcher: the row can be used")
}

final class Presses { var count = 0 }

/// The items AppKit gets for `view` as a menu's content, without opening it.
func menuItems<V: View>(_ view: V) -> (NSMenu, [NSMenuItem]) {
    let menu = NSHostingMenu(rootView: view)
    menu.update()
    return (menu, menu.items.filter { !$0.isSeparatorItem })
}

func menuTests() {
    let presses = Presses()
    // On This Mac, its herdr able to have them.
    var (menu, items) = menuItems(AddHerdrMachineMenuItem(unavailableReason: nil, isEnabled: true) { presses.count += 1 })
    expect(items.count == 1 && items[0].title == "Add herdr Machine…" && items[0].subtitle == nil && items[0].isEnabled,
           "This Mac: Add herdr Machine…, with nothing under it, can be chosen: \(items.map { ($0.title, $0.subtitle ?? "-", $0.isEnabled) })")
    menu.performActionForItem(at: 0)
    expect(presses.count == 1, "choosing it opens the panel")

    // On This Mac, but not now (herdr too old, still loading, something
    // over the window): greyed out as before, with no reason of this kind.
    (menu, items) = menuItems(AddHerdrMachineMenuItem(unavailableReason: nil, isEnabled: false) { presses.count += 1 })
    expect(items.count == 1 && items[0].subtitle == nil && !items[0].isEnabled, "This Mac, not now: greyed out, as before")

    // Another machine: greyed out, whatever else holds, with why under it.
    for isEnabled in [true, false] {
        (menu, items) = menuItems(AddHerdrMachineMenuItem(unavailableReason: herdrReason, isEnabled: isEnabled) { presses.count += 1 })
        expect(items.count == 1 && items[0].title == "Add herdr Machine…" && items[0].subtitle == herdrReason && !items[0].isEnabled
               && items[0].action == nil, "another machine (otherwise \(isEnabled ? "able" : "not able")): greyed out, why under it: \(items.map { ($0.title, $0.subtitle ?? "-", $0.isEnabled) })")
    }
    expect(presses.count == 1, "nothing ran for a greyed-out item")

    // As the host group header's menu has it, with the rule in it.
    (menu, items) = menuItems(AddHerdrMachineMenuItem(unavailableReason: LocalOnlyAddition.herdrMachine.unavailableReason(on: pairedMac), isEnabled: true) {
        presses.count += 1
    })
    expect(items.first?.subtitle == herdrReason && items.first?.isEnabled == false, "a Mac added by QR code: greyed out, with why")
}

@main
struct LocalOnlyAdditionTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        ruleTests()
        launcherTests()
        menuTests()
        expect(NSApp.windows.allSatisfy { !$0.isVisible }, "no window shown")
        print("\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
