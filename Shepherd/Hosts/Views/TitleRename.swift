import Foundation

/// A pane's or a tab's name, as it is typed into the window's title: what
/// the field starts out with, and what is sent to herdr when it is done.
///
/// A tab can't be given an empty name — herdr would show it as one. A pane
/// can: that is how its own name is taken away again, and it goes back to
/// being called by its title.
enum TitleRename {
    /// The name the pane or tab already has. A pane that has none of its own
    /// starts out empty, with its title as the prompt: filled in with the
    /// title, a rename would pin today's title on it for good, where left
    /// alone it follows whatever runs in the pane.
    static func startText(for item: BoardItem) -> String {
        switch item {
        case .tab(let tab): tab.label
        case .pane(let pane): pane.label ?? ""
        }
    }

    /// What the field shows while it is empty: what the item is called
    /// without a name of its own.
    static func prompt(for item: BoardItem) -> String {
        switch item {
        case .tab(let tab): tab.title
        case .pane(let pane): pane.automaticTitle
        }
    }

    /// Whether Return may send `typed`: not an empty name for a tab.
    static func canSubmit(_ typed: String, for item: BoardItem) -> Bool {
        if case .tab = item {
            return !trimmed(typed).isEmpty
        }
        return true
    }

    /// What to send to herdr for `typed`, or nil for nothing: an empty name
    /// for a tab, or the name the item already has.
    static func commit(_ typed: String, for item: BoardItem) -> TitleRenameCommit? {
        let name = trimmed(typed)
        switch item {
        case .tab(let tab):
            guard !name.isEmpty, name != tab.label else { return nil }
            return TitleRenameCommit(item: item, name: name, shownTitle: name)
        case .pane(let pane):
            guard (name.isEmpty ? nil : name) != pane.label else { return nil }
            return TitleRenameCommit(item: item, name: name, shownTitle: name.isEmpty ? pane.automaticTitle : name)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One name being typed into the window's title, from a row's Rename item —
/// or a double-click on the title — until the field is done with it.
///
/// A reference, and nothing on screen follows it: the field writes what is
/// typed into `text` as it goes, and nothing about that may change SwiftUI's
/// state — AppKit reports some of it in the middle of SwiftUI's updates (a
/// composition committed as the field goes away), where a change of state
/// isn't allowed. What is typed only matters when the rename ends.
final class TitleRenameSession {
    let id = UUID()
    /// The pane or tab, as it was when the rename began.
    let item: BoardItem
    let startText: String
    /// Kept as it was when the rename began, so that the field is never
    /// changed while something is typed into it.
    let prompt: String
    /// What the field holds — what the input method is still composing
    /// aside, which AppKit only reports once it is committed.
    var text: String
    /// What had the keyboard before the field took it, to be given it back
    /// after Return or Escape.
    weak var keyboardBefore: AnyObject?
    private(set) var isEnded = false

    init(item: BoardItem) {
        self.item = item
        startText = TitleRename.startText(for: item)
        prompt = TitleRename.prompt(for: item)
        text = startText
    }

    /// Marks the rename ended. True only the first time: of the ways a
    /// rename can end, whichever comes first is the one that counts.
    func end() -> Bool {
        guard !isEnded else { return false }
        isEnded = true
        return true
    }
}

/// How a rename typed into the window's title ended.
enum TitleRenameEnding {
    /// Return: the name is sent, if it can be (see `TitleRename.commit`).
    case submit
    /// Escape: nothing is sent.
    case cancel
    /// The keyboard went elsewhere, or the field went away: as Return, but
    /// a tab's name left empty is let go of instead.
    case left
}

/// A name typed into the window's title, from when it is ready to be sent
/// until herdr reports it. Meanwhile the title shows it: the board only
/// hears of the new name when it next reads herdr, which over SSH or
/// through a herdr machine can be seconds after it was typed, and the old
/// one would show again until then.
struct TitleRenameCommit: Equatable {
    let id = UUID()
    /// The pane or tab, as it was when the rename began.
    let item: BoardItem
    /// The name to send. Empty for a pane: take its name away.
    let name: String
    /// What the window's title shows meanwhile.
    let shownTitle: String
    /// How many times the herdr the item is on has been read since it took
    /// the name; nil while the request is still out.
    var readsSinceSent: Int?

    init(item: BoardItem, name: String, shownTitle: String) {
        self.item = item
        self.name = name
        self.shownTitle = shownTitle
    }

    /// The window's title while `selected` is selected, if this is what to
    /// show for it.
    func title(for selected: BoardItem) -> String? {
        selected.id == item.id ? shownTitle : nil
    }

    /// The commit after a read of the herdr the item is on, which lists the
    /// item as `current` — nil if it no longer does. Nil once the read ends
    /// it: one that shows the new name, or the second since herdr took it
    /// (herdr may keep a name otherwise than it was typed; the first read
    /// can be one that began before herdr took it), or one without the item.
    /// Reads before herdr took the name count for nothing.
    func afterRead(of current: BoardItem?) -> TitleRenameCommit? {
        guard let reads = readsSinceSent else { return self }
        guard let current, current.title != shownTitle, reads + 1 < 2 else { return nil }
        var next = self
        next.readsSinceSent = reads + 1
        return next
    }
}
