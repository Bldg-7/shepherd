import SwiftUI
import UniformTypeIdentifiers

/// A pane's or a tab's row dragged from the sidebar onto a terminal pastes
/// the row's herdr ID there: the pane's `paneID` or the tab's `tabID`, with
/// a space after it and no Return, in one paste — between the bracketed
/// paste markers when the program asked for them — as a File Drop pastes a
/// path (see `FocusReportingTerminalView.sendPaste`). Any terminal with a
/// live attach takes it, whether or not an agent runs in it and whatever the
/// Terminal File Drop setting, but only one on the same herdr server as the
/// row: the same Shepherd Machine connection, and the same herdr machine or
/// both the host's own herdr. A herdr ID means something only to the server
/// that gave it out.
///
/// The drag carries two things on its pasteboard: the ID as plain text,
/// which another app takes as it takes any dragged text, and a type that
/// marks it as a row's drag, which only this process sees and whose data
/// AppKit leaves promised. What the row is — pane or tab, its ID, its
/// connection and herdr machine — stays in the app, in `dragged`, set when
/// the list asks the row for its drag. A terminal takes a drop only if it
/// is marked, comes from this process, and its text is the ID of the row
/// dragged last (`pasteText`).
enum HerdrItemDrag {
    /// The type that marks a row's drag.
    nonisolated static let typeIdentifier = "com.bldg-7.shepherd.herdr-item"

    static var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(typeIdentifier) }

    /// What a row's drag is of.
    nonisolated struct Item: Equatable, Sendable {
        nonisolated enum Kind: Equatable, Sendable {
            case pane, tab
        }

        let kind: Kind
        /// herdr's own ID: the pane's `paneID`, the tab's `tabID`.
        let herdrID: String
        /// The Shepherd Machine connection the row was listed for.
        let connection: Machine.ConnectionIdentity
        /// The herdr machine the item is on, by its profile ID, or nil for
        /// the host's own herdr.
        let herdrMachineID: String?

        init(pane: AgentSummary, on connection: Machine.ConnectionIdentity) {
            kind = .pane
            herdrID = pane.paneID
            self.connection = connection
            herdrMachineID = pane.herdrMachine?.id
        }

        init(tab: TabSummary, on connection: Machine.ConnectionIdentity) {
            kind = .tab
            herdrID = tab.tabID
            self.connection = connection
            herdrMachineID = tab.herdrMachine?.id
        }
    }

    /// The item of the row a drag was last started from. A drag that ends
    /// elsewhere leaves it, to be replaced by the next one: a drop that isn't
    /// marked, or isn't from this process, never gets as far as reading it.
    private(set) static var dragged: Item?

    /// A row's drag, asked for by the list when a drag starts from the row.
    static func provider(for item: Item) -> NSItemProvider {
        dragged = item
        return makeProvider(text: item.herdrID)
    }

    /// The mark, for this process only, and `text` for any app.
    nonisolated static func makeProvider(text: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        // As UTF-8 data rather than an NSString: a string would go on the
        // pasteboard as a URL too, and "w1:p4" reads as one.
        let data = Data(text.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// What a terminal attached on `connection` and `herdrMachineID` (nil
    /// for the host's own herdr) pastes for a marked drop whose plain text
    /// is `text`, or nil to refuse it: the ID and a space, when `text` is
    /// the ID of the row dragged last, that row is on the same herdr server,
    /// and the ID is one `isPastable` lets through.
    nonisolated static func pasteText(for text: String, dragged: Item?, connection: Machine.ConnectionIdentity, herdrMachineID: String?) -> String? {
        guard let dragged, text == dragged.herdrID, isPastable(text),
              dragged.connection == connection, dragged.herdrMachineID == herdrMachineID else { return nil }
        return text + " "
    }

    /// Whether an ID is pasted at all: 1 to 64 ASCII letters, digits, `:`,
    /// `_` and `-`, as herdr writes its IDs (`w1:p4`, `w1:t2`). Anything
    /// else could take a control character, or the end of a bracketed
    /// paste, into the program.
    nonisolated static func isPastable(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        return (1...64).contains(scalars.count) && scalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == ":" || scalar == "_" || scalar == "-"
        }
    }

    /// The drop a terminal attached on `connection` and `herdrMachineID`
    /// takes rows' drags with; `onTargetChange` is `TerminalTextDrop`'s.
    static func terminalDrop(connection: Machine.ConnectionIdentity, herdrMachineID: String?, onTargetChange: @escaping (Bool) -> Void) -> TerminalTextDrop {
        TerminalTextDrop(type: pasteboardType, text: { text in
            pasteText(for: text, dragged: dragged, connection: connection, herdrMachineID: herdrMachineID)
        }, onTargetChange: onTargetChange)
    }
}

extension View {
    /// Lets the row be dragged onto a terminal, which pastes its ID (see
    /// `HerdrItemDrag`). `itemProvider` rather than `onDrag`: only it gives
    /// a row of a macOS List a drag. A click still selects the row.
    func herdrItemDrag(_ item: HerdrItemDrag.Item) -> some View {
        itemProvider { HerdrItemDrag.provider(for: item) }
    }

    /// The accent border over a terminal while a row dragged over it would
    /// be pasted into it. It takes no clicks and no drags.
    func itemDropHighlight(_ isShown: Bool) -> some View {
        overlay {
            if isShown {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}
