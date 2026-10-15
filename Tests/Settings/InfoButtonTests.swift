import SwiftUI
import AppKit

@MainActor @Observable final class InfoProbe {
    var enabled = false
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var backs = 0
}

/// The two places Settings puts an ⓘ: in a Toggle's label, and in a plain row
/// before a status. Escape also belongs to the page's Back button, as on
/// Experimental Features.
private struct InfoFixture: View {
    @Bindable var probe: InfoProbe
    var body: some View {
        Form {
            Button(String("Back")) { probe.backs += 1 }.keyboardShortcut(.cancelAction)
            Section {
                Toggle(isOn: $probe.enabled) {
                    HStack {
                        Text(verbatim: "Feature")
                        InfoButton(accessibilityLabel: "About Feature", explanation: "Feature explanation")
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["toggle"] = $0 }
                    }
                }
            }
            Section {
                HStack {
                    Text(verbatim: "Preparation")
                    InfoButton(accessibilityLabel: "About Preparation", explanation: "Preparation explanation")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["row"] = $0 }
                    Spacer()
                    Text(verbatim: "Ready")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 260)
    }
}

@main @MainActor enum InfoButtonTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    /// Like the app's run loop: posted events go through NSApp, so a popover's
    /// own monitors see them as well.
    static func drain(_ seconds: TimeInterval = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
    }
    static func popovers() -> [NSWindow] { NSApp.windows.filter { $0.className.contains("Popover") && $0.isVisible } }

    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let probe = InfoProbe()
        let host = NSHostingView(rootView: InfoFixture(probe: probe))
        // SwiftUI takes clicks, and opens a popover, only in a window that is
        // ordered in. Far below every screen, borderless and never activated,
        // it and its popovers stay out of sight. Within a screen's horizontal
        // span, so AppKit leaves a popover's x at its ⓘ.
        let left = (NSScreen.screens.first?.frame.minX ?? 0) + 100
        let window = NSWindow(contentRect: NSRect(x: left, y: -6000, width: 520, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView = host
        window.orderFrontRegardless(); drain()
        check(window.isVisible && !window.occlusionState.contains(.visible), "fixture window is ordered in but not on any screen")
        check(probe.frames.count == 2 && probe.frames.values.allSatisfy { $0.width > 8 && $0.height > 8 }, "both ⓘ are laid out")
        func send(_ type: NSEvent.EventType, at point: CGPoint) {
            let location = host.convert(point, to: nil)
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
        }
        func click(_ point: CGPoint) { send(.leftMouseDown, at: point); send(.leftMouseUp, at: point); drain() }
        func click(_ name: String) { click(CGPoint(x: probe.frames[name]!.midX, y: probe.frames[name]!.midY)) }
        // In the active app the popover takes key when it opens, over a key
        // Settings window. This process is never activated, so Escape goes to
        // the popover window the way NSApp hands a key down to the key window:
        // key equivalents first, then the window itself.
        func escape() {
            let popover = popovers()[0]
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popover.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            check(!popover.performKeyEquivalent(with: event), "Escape is no key equivalent in the popover")
            popover.sendEvent(event); drain()
        }
        func opensBeside(_ name: String) -> Bool {
            let anchor = window.convertToScreen(host.convert(probe.frames[name]!, to: nil))
            return popovers().count == 1 && popovers()[0].frame.insetBy(dx: -24, dy: -24).intersects(anchor)
        }
        for name in ["toggle", "row"] {
            click(name)
            check(opensBeside(name), "\(name): clicking ⓘ opens one popover at it")
            click(name)
            check(popovers().isEmpty, "\(name): clicking ⓘ again closes the popover and leaves it closed")
            click(name)
            check(opensBeside(name), "\(name): ⓘ opens it once more")
            click(CGPoint(x: 260, y: 250))
            check(popovers().isEmpty, "\(name): a click outside closes the popover")
            click(name)
            check(opensBeside(name), "\(name): ⓘ opens it after an outside click")
            escape()
            check(popovers().isEmpty, "\(name): Escape closes the popover")
        }
        click("toggle")
        click("row")
        check(opensBeside("row"), "clicking the other ⓘ moves the popover to it")
        escape()
        check(!probe.enabled, "clicking an ⓘ in a Toggle's label never flips the toggle")
        check(probe.backs == 0, "Escape on the popover leaves the page's Back button alone")
        print("PASS \(checks) ⓘ click/popover checks in a grouped Form; owned offscreen window, no user input")
    }
}
