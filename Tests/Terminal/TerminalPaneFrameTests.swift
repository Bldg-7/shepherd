import SwiftUI
import AppKit
import SwiftTerm
import Observation
import Darwin

@MainActor @Observable final class FrameProbe {
    var focused = false
    @ObservationIgnored var terminal: TerminalView?
    @ObservationIgnored var creations = 0
    @ObservationIgnored var sizes: [(Int, Int)] = []
    @ObservationIgnored let ownedPTY: Int32
    init(ownedPTY: Int32) { self.ownedPTY = ownedPTY }
}

private struct FrameFixture: View {
    let probe: FrameProbe
    var body: some View {
        TerminalPaneFrame(isFocused: probe.focused) {
            TerminalHostView(onCreate: { view in
                probe.terminal = view; probe.creations += 1
            }, onInput: { _ in }, onResize: { cols, rows in
                probe.sizes.append((cols, rows))
                // Mirror the production delegate request into an owned kernel
                // PTY only. No shell, Herdr attach or user terminal is involved.
                var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                precondition(ioctl(probe.ownedPTY, TIOCSWINSZ, &size) == 0)
            })
        }
        .accentColor(.blue)
    }
}

@main @MainActor enum TerminalPaneFrameTests {
    static var checks = 0
    static func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
    static func settle(_ host: NSView, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return false
    }
    static func drain(_ host: NSView) {
        // Deliver SwiftUI's observation update even when geometry should NOT
        // change. This is a bounded owned-view event drain, not user input.
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var master: Int32 = -1, slave: Int32 = -1
        precondition(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        let probe = FrameProbe(ownedPTY: slave)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FrameFixture(probe: probe))
        window.contentView = host
        var receipts: [[String: Double]] = []
        for size in [CGSize(width: 800, height: 480), CGSize(width: 520, height: 330), CGSize(width: 1040, height: 600)] {
            window.setContentSize(size)
            check(settle(host) {
                guard let view = probe.terminal, let last = probe.sizes.last else { return false }
                let rect = view.convert(view.bounds, to: host)
                return abs(rect.width - size.width + 6) < 1 && abs(rect.height - size.height + 6) < 1 && last.0 == view.getTerminal().cols && last.1 == view.getTerminal().rows
            }, "real native bounds and delegate grid must settle after resize")
            let view = probe.terminal!
            let rect = view.convert(view.bounds, to: host)
            let grid = view.getTerminal()
            let cell = view.caretFrame.size
            check(abs(rect.minX - 3) < 1 && abs(rect.minY - 3) < 1, "native terminal must be outside the 2pt border band")
            check(abs(host.bounds.maxX - rect.maxX - 3) < 1 && abs(host.bounds.maxY - rect.maxY - 3) < 1, "right/bottom gutter must also stay reserved")
            check(grid.rows == Int(view.bounds.height / cell.height), "row count must use the inner native height")
            check(CGFloat(grid.cols) * cell.width <= view.bounds.width + 1, "columns must fit inner native width")
            check(view.bounds.width - CGFloat(grid.cols) * cell.width < cell.width + 20, "columns must not remain cached from a smaller viewport")
            var kernelSize = winsize()
            check(ioctl(slave, TIOCGWINSZ, &kernelSize) == 0 && Int(kernelSize.ws_col) == grid.cols && Int(kernelSize.ws_row) == grid.rows, "owned kernel PTY must receive the exact native grid")
            let previousCount = probe.sizes.count
            let previousGrid = (grid.cols, grid.rows)
            for focused in [true, false, true] {
                probe.focused = focused; drain(host)
                check(probe.terminal === view && probe.creations == 1, "focus must not recreate terminal/session")
                check(view.convert(view.bounds, to: host) == rect, "focus must not shift native content")
                check(grid.cols == previousGrid.0 && grid.rows == previousGrid.1 && probe.sizes.count == previousCount, "focus must not resize the PTY grid")
            }
            // Bottom/first-column text belongs to the emulator's content,
            // not a transformed or scrolled overlay coordinate system.
            view.feed(text: "\u{1b}[2J\u{1b}[HLEFT\u{1b}[\(grid.rows);1Hgpt owned STATUS")
            check(grid.getCharacter(col: 0, row: grid.rows - 1) == "g", "bottom-left first column preserved")
            receipts.append(["width": size.width, "height": size.height, "innerWidth": rect.width, "innerHeight": rect.height, "columns": Double(grid.cols), "rows": Double(grid.rows), "x": rect.minX, "y": rect.minY])
        }
        check(Set(probe.sizes.map { "\($0.0)x\($0.1)" }).count >= 3, "resize delegate must produce distinct actual grids")
        try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS \(checks) actual SwiftTerm gutter, focus stability, edge-cell and delegate/PTY-request grid checks; owned unshown window + kernel PTY; no Herdr/SSH/user GUI input")
    }
}
