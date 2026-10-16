import SwiftUI
import AppKit
import Vision

// The page's own reads, over AgentSkillPreparationSeams' stand-ins. Nothing
// here prepares, connects, launches or writes a preference.
@MainActor enum LayoutFixture {
    static var refusal: String?
    static let machine = Machine(displayName: "This Mac", hostname: "localhost", username: "fixture", isLocal: true)
    /// Registered values only: in memory, never written.
    static let passwords: PasswordManagerPreferences = {
        let defaults = UserDefaults(suiteName: "test.experimental-features-layout")!
        defaults.register(defaults: [PasswordManagerPreferences.managerKey: PasswordManagerProviderID.onePassword.rawValue,
                                     PasswordManagerPreferences.onboardingKey: PasswordManagerPreferences.Onboarding.completed.rawValue])
        return PasswordManagerPreferences(defaults: defaults)
    }()
}
extension ShepherdBrowserFeature {
    var isTransitioning: Bool { false }
    var refusal: String? { LayoutFixture.refusal }
    var passwordManagers: PasswordManagerPreferences { LayoutFixture.passwords }
    func setEnabled(_ enabled: Bool, presentationOwner: UUID? = nil) async {}
}
extension CDPProxy {
    nonisolated static let defaultPort = 9334
    var error: String? { nil }
}
extension MachineStore { var activeMachine: Machine? { LayoutFixture.machine } }

/// The real Experimental Features page, rendered in a window that is never
/// ordered in. Cards are found in the pixels (a grouped Form draws each
/// Section as one rounded card) and rows by the text drawn in them.
@main @MainActor enum ExperimentalFeaturesLayoutTests {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); print("FAIL \(message)") }
    }
    static func drain(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
    }

    struct Line { let text: String; let rect: CGRect }
    struct Render { let cards: [ClosedRange<CGFloat>]; let lines: [Line] }

    static func render(browser: Bool, diagnostics: Bool, appearance: NSAppearance.Name, png: URL) -> Render {
        ShepherdBrowserFeature.shared.isEnabled = browser
        LayoutFixture.refusal = diagnostics ? "Synthetic diagnostic message" : nil
        let size = CGSize(width: 600, height: 1000)
        let host = NSHostingView(rootView: ExperimentalFeaturesSettingsView(machineStore: MachineStore(),
            passwordManagerWindowID: UUID(), onBack: {}).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        drain(0.8); host.layoutSubtreeIfNeeded(); drain(0.2)
        check(!window.isVisible, "the page's window is never ordered in")

        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        // The header and footer draw on the window's background, which a
        // view's cache leaves clear.
        let context = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var background = CGColor(gray: 0.5, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        let image = context.makeImage()!
        let bitmap = NSBitmapImageRep(cgImage: image)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: png)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try! VNImageRequestHandler(cgImage: image).perform([request])
        let height = CGFloat(rep.pixelsHigh), width = CGFloat(rep.pixelsWide)
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Line(text: text, rect: CGRect(x: box.minX * width / scale, y: (1 - box.maxY) * height / scale,
                                                 width: box.width * width / scale, height: box.height * height / scale))
        }.sorted { $0.rect.midY < $1.rect.midY }

        // Cards: runs, down one column inside the cards' left padding, of
        // pixels that differ from the Form's own background.
        guard let scroll = descendants(of: host).first(where: { $0 is NSScrollView }),
              let anchor = lines.first(where: { $0.text.contains("Shepherd Browser") }) else {
            check(false, "the Form and its first card's toggle are drawn"); return Render(cards: [], lines: lines)
        }
        var frame = host.convert(scroll.bounds, from: scroll)
        if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)!
            return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        func differs(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).map { abs($0 - $1) }.reduce(0, +) > 4 }
        let ground = pixel(frame.minX + 3, anchor.rect.midY)
        var edge = frame.minX + 3
        while edge < anchor.rect.minX, !differs(pixel(edge, anchor.rect.midY), ground) { edge += 0.5 }
        let column = edge + 5
        check(column < anchor.rect.minX - 2, "a column inside the first card's padding, left of its text")
        var cards: [ClosedRange<CGFloat>] = []
        var start: CGFloat?
        var y = frame.minY + 1
        while y < frame.maxY - 1 {
            let inside = differs(pixel(column, y), ground)
            if inside, start == nil { start = y }
            if !inside, let top = start { if y - top > 8 { cards.append(top...y) }; start = nil }
            y += 0.5
        }
        if let top = start, frame.maxY - 1 - top > 8 { cards.append(top...(frame.maxY - 1)) }
        return Render(cards: cards, lines: lines)
    }

    static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var report: [[String: Any]] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (browser, diagnostics) in [(true, false), (true, true), (false, false), (false, true)] {
                let name = "\(browser ? "browser-on" : "browser-off")-\(diagnostics ? "diagnostics" : "no-diagnostics")-\(appearance == .aqua ? "light" : "dark")"
                let result = render(browser: browser, diagnostics: diagnostics, appearance: appearance,
                                    png: output.appendingPathComponent(name + ".png"))
                func card(_ text: String) -> Int? {
                    guard let line = result.lines.first(where: { $0.text.contains(text) }) else { return nil }
                    return result.cards.firstIndex { $0.contains(line.rect.midY) }
                }
                func top(_ text: String) -> CGFloat { result.lines.first { $0.text.contains(text) }?.rect.midY ?? .infinity }
                let rows = result.cards.map { range in result.lines.filter { range.contains($0.rect.midY) }.map(\.text) }
                report.append(["scenario": name, "cards": rows])
                print("\(name): \(rows)")

                check(result.cards.count == 2, "\(name): the Form draws exactly two cards")
                check(card("Shepherd Browser") == 0, "\(name): Shepherd Browser's toggle is in the first card")
                check(card("Terminal File Drop") == 1, "\(name): Terminal File Drop's toggle is in the second card")
                // Its ⓘ may read as a line of its own, on the same row.
                check(result.cards.count == 2 && result.lines.filter { result.cards[1].contains($0.rect.midY) }
                        .allSatisfy { abs($0.rect.midY - top("Terminal File Drop")) < 12 },
                      "\(name): the second card holds nothing but Terminal File Drop")
                if browser {
                    for row in ["Password Manager", "Preparation", "Advanced"] {
                        check(card(row) == 0, "\(name): \(row) is in the browser's card")
                    }
                    check(top("Shepherd Browser") < top("Password Manager") && top("Password Manager") < top("Preparation")
                          && top("Preparation") < top("Advanced"), "\(name): toggle, Password Manager, Preparation, Advanced in that order")
                } else {
                    for row in ["Password Manager", "Preparation", "Advanced"] {
                        check(card(row) == nil && top(row) == .infinity, "\(name): no \(row) while the browser is off")
                    }
                }
                if diagnostics {
                    check(card("Diagnostics") == 0 && card("Synthetic diagnostic message") == 0, "\(name): Diagnostics is in the browser's card")
                    let last = browser ? top("Advanced") : top("Shepherd Browser")
                    check(last < top("Diagnostics") && top("Diagnostics") < top("Synthetic diagnostic message"),
                          "\(name): Diagnostics comes last, its label row first and its messages shown")
                } else {
                    check(top("Diagnostics") == .infinity, "\(name): no Diagnostics without an issue")
                }
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: output.appendingPathComponent("layout.json"))
        if !failures.isEmpty { print("FAILED \(failures.count) of \(checks) checks"); exit(1) }
        print("PASS \(checks) Experimental Features layout checks; real page, never-shown window, no app")
    }
}
