import Foundation

/// The launcher's way to add a herdr machine to the host, at the end of its
/// Machine step: the one place to start from while the host has none saved,
/// when the board has no group headers to open a menu on.
struct AddHerdrMachineOffer: Equatable {
    /// Why no herdr machine can be added right now — the host's herdr is too
    /// old for them, or couldn't list them — or nil when one can.
    let unavailableReason: String?
}

/// What the launcher's Machine step lists, and when Backspace on the
/// Workspace step goes back to it.
struct LauncherMachineStep: Equatable {
    enum Entry: Equatable, Identifiable {
        case target(LaunchTarget)
        case addHerdrMachine(AddHerdrMachineOffer)

        var id: String {
            switch self {
            case .target(let target): "target/\(target.id)"
            case .addHerdrMachine: "add-herdr-machine"
            }
        }

        var isEnabled: Bool {
            switch self {
            case .target(let target): target.unavailableReason == nil
            case .addHerdrMachine(let offer): offer.unavailableReason == nil
            }
        }
    }

    let targets: [LaunchTarget]
    /// Nil where herdr machines aren't offered at all.
    let addHerdrMachine: AddHerdrMachineOffer?

    /// The targets whose names have every word typed in them, and — always,
    /// at the end — the way to add a herdr machine.
    func entries(matching text: String) -> [Entry] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = targets.filter { target in terms.allSatisfy { target.label.localizedStandardContains($0) } }
        return matching.map(Entry.target) + (addHerdrMachine.map { [.addHerdrMachine($0)] } ?? [])
    }

    /// Whether Backspace on the Workspace step takes the machine back: with
    /// another machine to pick, or the way to add one to show. With the
    /// host's own herdr alone and no way to add, there is nothing to go back
    /// to.
    var canGoBack: Bool {
        targets.count > 1 || addHerdrMachine != nil
    }
}
