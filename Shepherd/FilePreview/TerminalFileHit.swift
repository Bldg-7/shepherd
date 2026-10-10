import SwiftTerm
import Foundation
import CoreGraphics
import AppKit

/// Uses the terminal emulator's final cells, not raw output bytes. OSC8 and
/// URL detection uses SwiftTerm's public cells/link API. File OSC8/URIs and
/// plain paths are claimed before native mouse reporting can reach a TUI.
@MainActor enum TerminalFileHit {
    static func link(in view: TerminalView, point: CGPoint) -> String? {
        let terminal = view.getTerminal()
        let cell = view.caretFrame.size
        guard cell.width > 0, cell.height > 0, view.bounds.contains(point) else { return nil }
        let col = Int((point.x - view.bounds.minX) / cell.width)
        let row = Int((view.bounds.maxY - point.y) / cell.height)
        guard col >= 0, col < terminal.cols, row >= 0, row < terminal.rows else { return nil }
        let position = Terminal.LinkLookupLocation.screen(Position(col: col, row: row))
        if let line = terminal.getLine(row: row) {
            for c in 0..<terminal.cols {
                let char = terminal.getCharacter(for: line[c])
                if char.unicodeScalars.contains(where: { (0x0590...0x08ff).contains($0.value) || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value) }) { return nil }
            }
        }
        if let explicit = terminal.link(at: position, mode: .explicitOnly) {
            return FilePreviewLink.isFileGestureLink(explicit) ? explicit : nil
        }
        if let native = terminal.link(at: position, mode: .explicitAndImplicit) {
            // The implicit matcher can include padding; OSC8 payloads above
            // remain exact (including escaped filenames and source locations).
            let candidate = native.trimmingCharacters(in: .whitespaces)
            return FilePreviewLink.isFileGestureLink(candidate) ? candidate : nil
        }
        var start = row, end = row
        while start > 0, row - start < 4, terminal.getLine(row: start)?.isWrapped == true { start -= 1 }
        while end + 1 < terminal.rows, end - row < 4, terminal.getLine(row: end + 1)?.isWrapped == true { end += 1 }
        var text = "", offset: Int?
        for r in start...end {
            guard let line = terminal.getLine(row: r) else { return nil }
            for c in 0..<terminal.cols {
                let data = line[c]
                if data.width == 0 { continue }
                let char = terminal.getCharacter(for: data)
                // Visual/logical BiDi remapping isn't public in SwiftTerm.
                // Refuse fallback hits on RTL rows instead of guessing.
                if char.unicodeScalars.contains(where: { (0x0590...0x08ff).contains($0.value) || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value) }) { return nil }
                if r == row, c == col || (data.width == 2 && c + 1 == col) { offset = text.count }
                text.append(char == "\0" ? " " : char)
            }
        }
        guard let offset else { return nil }
        return FilePreviewLink.token(in: text, characterOffset: offset)
    }
}
