import SwiftUI
import AppKit
import SwiftTerm
import Observation
import Darwin

@MainActor @Observable final class ModalProbe {
    @ObservationIgnored var terminal: TerminalView?
    @ObservationIgnored var creations = 0
    @ObservationIgnored var resizes: [(Int, Int)] = []
    @ObservationIgnored let slave: Int32
    init(slave: Int32) { self.slave = slave }
}
private struct ModalTerminal: View {
    let probe: ModalProbe
    var body: some View {
        TerminalPaneFrame(isFocused: false) {
            TerminalHostView(onCreate: { probe.terminal = $0; probe.creations += 1 }, onInput: { _ in }, onResize: { cols, rows in
                probe.resizes.append((cols, rows))
                var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                precondition(ioctl(probe.slave, TIOCSWINSZ, &size) == 0)
            })
        }
    }
}
@main @MainActor enum PreviewModalLayoutTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func drain(_ view: NSView, _ turns: Int = 25) {
        for _ in 0..<turns { view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var master: Int32 = -1, slave: Int32 = -1
        precondition(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        let probe = ModalProbe(slave: slave)
        let controller = WorkspaceDetailSplitView<ModalTerminal, SwiftUI.Color>.Controller(terminal: ModalTerminal(probe: probe), panel: .white, environment: EnvironmentValues())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        controller.showPanel(true); drain(controller.view, 50)
        check(controller.view.bounds.size == NSSize(width: 1200, height: 700), "fixture must use a real nonzero production-proposed viewport")
        let terminal = probe.terminal!, panel = controller.panelHost.view, surface = controller.panelSurfaceView
        let before = terminal.convert(terminal.bounds, to: controller.view)
        check(before.width > 500 && before.height == 686, "real terminal must occupy visible cells inside7pt gutter, not a zero-sized mount")
        let grid = (terminal.getTerminal().cols, terminal.getTerminal().rows), count = probe.resizes.count
        // Establish the owned attach's initial winsize before measuring the
        // transition. A bare openpty starts at0x0; no session handshake exists
        // in this native layout component fixture.
        var initial = winsize(ws_row: UInt16(grid.1), ws_col: UInt16(grid.0), ws_xpixel: 0, ws_ypixel: 0)
        check(ioctl(slave, TIOCSWINSZ, &initial) == 0, "initial owned attach winsize")
        for _ in 0..<4 {
            window.makeFirstResponder(terminal)
            controller.presentPanelAsModal(true); drain(controller.view)
            check(surface.frame == controller.view.bounds && panel.frame == surface.bounds, "single native preview panel covers whole detail/terminal region")
            check(terminal.convert(terminal.bounds, to: controller.view) == before, "modal expansion must not move/resize underlying terminal")
            check(terminal.getTerminal().cols == grid.0 && terminal.getTerminal().rows == grid.1 && probe.resizes.count == count, "modal must not resize terminal grid/PTY")
            check(window.firstResponder !== terminal, "expanded modal must take keyboard away from live terminal")
            let hit = controller.view.hitTest(NSPoint(x: before.midX, y: before.midY))
            if hit?.isDescendant(of: surface) != true {
                print("POINTER DIAGNOSTIC", "root", controller.view.frame, controller.view.bounds, "terminal", before, "surface", surface.frame, "hidden", surface.isHidden, "hit", String(describing: hit), "children", controller.view.subviews)
                print("SURFACE HIT", String(describing: surface.hitTest(NSPoint(x: before.midX, y: before.midY))))
                fflush(stdout)
            }
            check(hit?.isDescendant(of: surface) == true, "modal must own clicks over the covered terminal")
            check(controller.panelHost.view === panel && probe.terminal === terminal && probe.creations == 1, "single panel and same live terminal hosts")
            var size = winsize(); check(ioctl(slave, TIOCGWINSZ, &size) == 0 && Int(size.ws_col) == grid.0 && Int(size.ws_row) == grid.1, "owned kernel PTY unchanged")
            controller.presentPanelAsModal(false); drain(controller.view)
            check(surface.frame.minX > 0 && surface.frame.width < controller.view.bounds.width, "modal contracts to original side panel")
            check(terminal.convert(terminal.bounds, to: controller.view) == before && probe.resizes.count == count, "contracting modal retains terminal rectangle/PTY")
            check(window.firstResponder === terminal, "contracting modal returns focus to same terminal")
        }
        controller.showPanel(false); controller.presentPanelAsModal(false); drain(controller.view)
        check(controller.terminalHost.view.frame == controller.view.bounds && probe.creations == 1, "closing preview fills viewport without reattaching terminal")
        print("PASS \(checks) actual SwiftTerm/single native modal panel/frame/grid/keyboard/owned kernelPTY checks; unshown owned window, no SSH/user GUI")
    }
}
