import Testing
@testable import SwiftTerm

final class SavedCursorWrapTests {
    private let esc = "\u{1b}"
    private let marker = "HC-DROP-READY"

    private func expectWrapped(_ terminal: Terminal) {
        #expect(terminal.wraparound)
        terminal.feed(text: marker)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "HC-DRO")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "P-READ")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "Y")
    }

    @Test(arguments: ["\u{1b}8", "\u{1b}[?1048l", "\u{1b}[?1049l"])
    func unsavedRestoreUsesDefaultAutowrap(_ restore: String) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 6, rows: 5)
        withExtendedLifetime(delegate) {
            terminal.feed(text: restore)
            expectWrapped(terminal)
        }
    }

    @Test func softResetDiscardsPreviouslySavedDisabledWrap() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 6, rows: 5)
        withExtendedLifetime(delegate) {
            terminal.feed(text: "\(esc)[?7l\(esc)7\(esc)[!p\(esc)[?1049l")
            expectWrapped(terminal)
        }
    }

    @Test func snapshotPrefixAcrossByteBoundariesUsesDefaultAutowrap() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 6, rows: 5)
        withExtendedLifetime(delegate) {
            for byte in "\(esc)[!p\(esc)[?1049l".utf8 {
                terminal.feed(buffer: [byte][...])
            }
            expectWrapped(terminal)
        }
    }

    @Test(arguments: ["\u{1b}7\u{1b}[?7h\u{1b}8", "\u{1b}[?1049h\u{1b}[?7h\u{1b}[?1049l"])
    func explicitlySavedDisabledWrapRemainsDisabled(_ saveAndRestore: String) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 6, rows: 5)
        withExtendedLifetime(delegate) {
            terminal.feed(text: "\(esc)[?7l" + saveAndRestore)
            #expect(!terminal.wraparound)
            terminal.feed(text: marker)
            TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "HC-DRY")
            TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
        }
    }

    @Test func alternateRestorePreservesExplicitSavedEnabledWrap() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 6, rows: 5)
        withExtendedLifetime(delegate) {
            terminal.feed(text: "\(esc)[?7h\(esc)[?1049h\(esc)[?7l\(esc)[?1049l")
            expectWrapped(terminal)
        }
    }
}
