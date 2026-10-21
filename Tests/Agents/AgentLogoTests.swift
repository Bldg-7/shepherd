import AppKit
import CryptoKit
import SwiftUI

/// The sidebar's agent marks (SHPHRD-107): which herdr names have one, the
/// path data against the makers' SVGs, the parser, the marks drawn in their
/// own colors with room around them, and a pane row as tall with a mark as
/// with the name in words. Nothing is shown: views are drawn by
/// ImageRenderer and measured by an NSHostingView in no window.
@main @MainActor enum AgentLogoTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else {
            print("FAIL: \(message())")
            exit(1)
        }
        checks += 1
    }

    static func main() {
        _ = NSApplication.shared
        mapping()
        pathData()
        parsing()
        drawing()
        lineHeight()
        print("agent logo checks: \(checks)")
    }

    // MARK: Which agents have a mark

    static func mapping() {
        check(AgentLogo(herdrName: "claude") == .claude, "claude")
        check(AgentLogo(herdrName: "claude-code") == .claude, "claude-code")
        check(AgentLogo(herdrName: "pi") == .pi, "pi")
        // Every other name herdr gives an agent (src/detect/mod.rs in herdr
        // 0.9.1), and names that are not quite these.
        let herdrNames = ["codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode", "copilot",
                          "kimi", "kiro", "kiro-cli", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "letta",
                          "maki", "muse"]
        for name in herdrNames + ["", " ", "Claude", "CLAUDE", "Pi", "PI", "claude ", " pi", "claude-code-cli", "pi-agent", "π", "unknown"] {
            check(AgentLogo(herdrName: name) == nil, "no mark for \(name.debugDescription)")
        }
        check(AgentLogo.allCases == [.claude, .pi], "two marks")
        // The agents the app launches and diagnoses stay as they were.
        check(AgentKind.allCases == [.claude, .codex, .pi], "AgentKind.allCases: \(AgentKind.allCases)")
        for logo in AgentLogo.allCases {
            check(AgentLogo(herdrName: logo.kind.rawValue) == logo, "\(logo) is \(logo.kind)'s")
        }
        check(String(localized: AgentLogo.claude.kind.title) == "Claude Code", "read as Claude Code")
        check(String(localized: AgentLogo.pi.kind.title) == "Pi", "read as Pi")
        // A pane's caption: a mark for an agent with one, words for the rest.
        check(AgentPaneCaption("claude", agentName: "claude").logo == .claude, "a Claude pane")
        check(AgentPaneCaption("claude-code", agentName: "claude-code").logo == .claude, "a claude-code pane")
        check(AgentPaneCaption("pi", agentName: "pi").logo == .pi, "a Pi pane")
        check(AgentPaneCaption("codex", agentName: "codex").logo == nil, "a Codex pane in words")
        check(AgentPaneCaption("shepherd", agentName: nil).logo == nil, "a shell's folder in words")
        check(AgentPaneCaption("claude", agentName: nil).logo == nil, "a folder that happens to be called claude, in words")
        check(AgentPaneCaption("opencode", agentName: "opencode").text == "opencode", "the words kept")
    }

    // MARK: The makers' path data

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func pathData() {
        // The sha256 of each path's `d`, as in "Claude Spark - Clay.svg" (sha256
        // 6d53db4b…e219) from Anthropic's press kit and https://pi.dev/favicon.svg
        // (sha256 d266b2c1…7ce7), both downloaded on 2026-10-21.
        let official: [AgentLogo: [String]] = [
            .claude: ["1097e5265789c38109fc8cbb44b39ddaff2b7e09739a51290d600f41b3e9a4b3"],
            .pi: ["87b3fdb69b35daf73532a146f6384d8b6dd583cbe4b37be78c42c274c8ed5a16",
                  "64ef706b4a1e091230a0db05955fc74d7de046374c6a1b5c91290e675355ee85",
                  "672e38d7349412f962f18ec8e6233d20f5095674bd8f4887ea198da69ab328f8"]
        ]
        for logo in AgentLogo.allCases {
            check(logo.pathData.map(sha256) == official[logo], "\(logo)'s path data as in its SVG")
        }
        check(AgentLogo.claude.pathData[0].count == 2449, "Claude's path, 2449 characters")
        check(AgentLogo.claude.viewBox == 94 && AgentLogo.pi.viewBox == 560, "the viewBoxes")
        check(AgentLogo.claude.fill(in: .light) == 0xD97757 && AgentLogo.claude.fill(in: .dark) == 0xD97757, "Claude's clay in both modes")
        check(AgentLogo.pi.fill(in: .light) == 0x111111 && AgentLogo.pi.fill(in: .dark) == 0xF6F6F6, "Pi's #111111 and #F6F6F6")
        check(AgentLogo.clearSpace > 0.07 && AgentLogo.clearSpace < 0.09, "about 8% of room on each side: \(AgentLogo.clearSpace)")
    }

    // MARK: The parser

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    static func parsing() {
        typealias S = AgentLogoOutline.Segment
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func segments(_ data: String...) -> [S]? { AgentLogoOutline(svgPathData: data)?.segments }

        guard let claude = AgentLogo.claude.outline, let pi = AgentLogo.pi.outline else {
            check(false, "both marks parse")
            return
        }
        // Claude: M, 145 L, 8 H, 3 V, 1 C and Z, as counted in the SVG.
        check(claude.segments.count == 159, "Claude's 159 segments: \(claude.segments.count)")
        check(claude.segments.first == .move(p(18.7657, 62.4437)) && claude.segments.last == .close, "from its moveto to its closepath")
        check(claude.segments.filter { if case .curve = $0 { true } else { false } } == [.curve(to: p(22.0038, 4.65957), control1: p(22.1538, 6.51831), control2: p(22.0038, 5.68714))], "its one curve")
        check(claude.segments.filter { if case .move = $0 { true } else { false } }.count == 1, "one moveto")
        // H and V keep the other coordinate: "L37.1822 50.7085H36.2715".
        check(claude.segments[4] == .line(p(36.2715, 50.7085)), "H at the current y: \(claude.segments[4])")
        let c = claude.bounds
        check(near(c.minX, 0.399902) && near(c.minY, 0.200195) && near(c.maxX, 93.9999) && near(c.maxY, 93.8002), "Claude's bounds: \(c)")
        // Pi: three paths, of 8, 6 and 10 segments, filling the viewBox.
        check(pi.segments.count == 24, "Pi's 24 segments")
        check(pi.segments.filter { if case .move = $0 { true } else { false } } == [.move(p(420, 280)), .move(p(560, 560)), .move(p(140, 560))], "three paths")
        check(pi.segments.filter { $0 == .close }.count == 3 && pi.segments.allSatisfy { if case .curve = $0 { false } else { true } }, "closed, straight")
        check(pi.bounds == CGRect(x: 0, y: 0, width: 560, height: 560), "Pi's bounds: \(pi.bounds)")
        check(segments("M420 280H280V140H0V0H420V280Z") == [.move(p(420, 280)), .line(p(280, 280)), .line(p(280, 140)), .line(p(0, 140)), .line(p(0, 0)), .line(p(420, 0)), .line(p(420, 280)), .close], "Pi's first path")

        // What else it reads: commas, more points after a moveto, numbers
        // set apart by their signs and points, and Z going back to the start.
        check(segments("M0,0 L1,1 Z") == [.move(p(0, 0)), .line(p(1, 1)), .close], "commas")
        check(segments("M0 0 1 1 2 2") == [.move(p(0, 0)), .line(p(1, 1)), .line(p(2, 2))], "points after a moveto are linetos")
        check(segments("M0 0L1 1 2 2") == [.move(p(0, 0)), .line(p(1, 1)), .line(p(2, 2))], "a lineto's points")
        check(segments("M1-2") == [.move(p(1, -2))], "a sign apart")
        check(segments("M.5.5") == [.move(p(0.5, 0.5))], "a point apart")
        check(segments("M+1 2.") == [.move(p(1, 2))], "a plus sign and a trailing point")
        check(segments("M0 0C1 2 3 4 5 6 7 8 9 10 11 12") == [.move(p(0, 0)), .curve(to: p(5, 6), control1: p(1, 2), control2: p(3, 4)), .curve(to: p(11, 12), control1: p(7, 8), control2: p(9, 10))], "curves")
        check(segments("M1 1L5 5ZH9") == [.move(p(1, 1)), .line(p(5, 5)), .close, .line(p(9, 1))], "Z back at the start")
        check(segments("\tM 1 , 2\n L 3 4 \r") == [.move(p(1, 2)), .line(p(3, 4))], "spaces of every kind")
        check(segments("M0 0Z", "M1 1Z") == [.move(p(0, 0)), .close, .move(p(1, 1)), .close], "paths in turn")

        // And what fails the whole outline.
        let rejected = ["", " ", "Z", "L1 1", "1 2", "m0 0", "M0 0 l1 1", "M0 0 h1", "M0 0 v1", "M0 0 c1 2 3 4 5 6", "M0 0 z",
                        "M0 0 Q1 1 2 2", "M0 0 T1 1", "M0 0 S1 1 2 2", "M0 0 A1 1 0 0 1 2 2", "M0 0 X1 1",
                        "M0", "M0 0 L1", "M0 0 L1 2 3", "M0 0 C1 2 3 4 5", "M0 0 H", "M0 0 Z 1 2", "M1e2 0", "M0 0 L1 x",
                        "M- 0", "M. 0", "M0 0 L1;1", "M0 0 L1 1 Ź"]
        for data in rejected {
            check(AgentLogoOutline(svgPathData: [data]) == nil, "\(data.debugDescription) fails")
        }
        check(AgentLogoOutline(svgPathData: ["M0 0 L1 1", "Q1 1 2 2"]) == nil, "one bad path fails them all")
        check(AgentLogoOutline(svgPathData: []) == nil, "no paths")

        // Placed in the largest square of the frame, in the middle.
        let placed = AgentLogoOutline(svgPathData: ["M0 0 L94 94"])!.path(in: CGRect(x: 10, y: 20, width: 47, height: 94), viewBox: 94)
        check(placed.boundingRect == CGRect(x: 10, y: 43.5, width: 47, height: 47), "kept square: \(placed.boundingRect)")
    }

    // MARK: The marks drawn

    struct Bitmap {
        let width: Int, height: Int
        let bytes: [UInt8]
        func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
        /// Each pixel's alpha, row by row from the top.
        var alphas: [UInt8] { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }
    }

    /// `image` in 8-bit sRGB, premultiplied, its first row the top one.
    static func bitmap(_ image: CGImage) -> Bitmap {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        check(drawn, "a bitmap context")
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    static func render(_ logo: AgentLogo, scale: CGFloat, scheme: ColorScheme, prominence: BackgroundProminence) -> Bitmap {
        let renderer = ImageRenderer(content: AgentLogoMark(logo: logo, outline: logo.outline!)
            .environment(\.colorScheme, scheme)
            .environment(\.backgroundProminence, prominence))
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            check(false, "\(logo) rendered")
            preconditionFailure()
        }
        return bitmap(image)
    }

    /// The area an outline's paths enclose, each closed one in turn, for
    /// paths that don't overlap; curves taken as straight lines to their
    /// ends — for the marks' one short curve, close enough.
    static func area(of outline: AgentLogoOutline) -> Double {
        var total = 0.0, twice = 0.0, start = CGPoint.zero, current = CGPoint.zero
        func edge(to point: CGPoint) {
            twice += Double(current.x * point.y - point.x * current.y)
            current = point
        }
        for segment in outline.segments {
            switch segment {
            case .move(let point): twice = 0; start = point; current = point
            case .line(let point), .curve(let point, _, _): edge(to: point)
            case .close: edge(to: start); total += abs(twice) / 2
            }
        }
        return total
    }

    static func drawing() {
        let expected: [AgentLogo: [ColorScheme: (Int, Int, Int)]] = [
            .claude: [.light: (0xD9, 0x77, 0x57), .dark: (0xD9, 0x77, 0x57)],
            .pi: [.light: (0x11, 0x11, 0x11), .dark: (0xF6, 0xF6, 0xF6)]
        ]
        for logo in AgentLogo.allCases {
            for scale: CGFloat in [1, 2, 3] {
                var masks: [[UInt8]] = []
                for scheme: ColorScheme in [.light, .dark] {
                    var shown: [[UInt8]] = []
                    for prominence: BackgroundProminence in [.standard, .increased] {
                        let name = "\(logo) at \(Int(scale))x, \(scheme), \(prominence)"
                        let bitmap = render(logo, scale: scale, scheme: scheme, prominence: prominence)
                        // A caption line's place: 12 points wide, 13 tall.
                        check(bitmap.width == Int(12 * scale) && bitmap.height == Int(13 * scale), "\(name): \(bitmap.width)×\(bitmap.height)")
                        // The mark's box, 12 points square in the middle of the
                        // line, less a point of room on each side.
                        let inner = CGRect(x: 1, y: 1.5, width: 10, height: 10)
                        let minX = Int((inner.minX * scale).rounded(.down)), maxX = Int((inner.maxX * scale).rounded(.up))
                        let minY = Int((inner.minY * scale).rounded(.down)), maxY = Int((inner.maxY * scale).rounded(.up))
                        let (r, g, b) = expected[logo]![scheme]!
                        var covered = 0.0, drawnMinX = Int.max, drawnMaxX = Int.min, drawnMinY = Int.max, drawnMaxY = Int.min
                        for y in 0..<bitmap.height {
                            for x in 0..<bitmap.width {
                                let pixel = bitmap.rgba(x, y)
                                guard pixel.a > 0 else { continue }
                                covered += Double(pixel.a) / 255
                                check(x >= minX && x < maxX && y >= minY && y < maxY, "\(name): drawn at \(x), \(y), in the room around the mark")
                                drawnMinX = min(drawnMinX, x); drawnMaxX = max(drawnMaxX, x)
                                drawnMinY = min(drawnMinY, y); drawnMaxY = max(drawnMaxY, y)
                                // The mark's own color, at the edges as inside:
                                // only its coverage, in alpha, varies.
                                guard pixel.a >= 32 else { continue }
                                // Within a step of 8-bit premultiplied alpha.
                                let tolerance = pixel.a == 255 ? 1 : 1 + 255 / pixel.a
                                let unpremultiplied = [pixel.r, pixel.g, pixel.b].map { Int((Double($0) * 255 / Double(pixel.a)).rounded()) }
                                check(zip(unpremultiplied, [r, g, b]).allSatisfy { abs($0 - $1) <= tolerance },
                                      "\(name): \(unpremultiplied) at \(x), \(y) (alpha \(pixel.a)) is not \([r, g, b])")
                            }
                        }
                        // As much of the box covered as the outline's own
                        // area takes of its viewBox.
                        let area = Self.area(of: logo.outline!) / (logo.viewBox * logo.viewBox) * (10 * scale) * (10 * scale)
                        check(abs(covered - area) / area < 0.05, "\(name): \(covered) pixels covered for \(area)")
                        // Square, and reaching the edges of its box: neither
                        // squeezed nor smaller than the room left for it.
                        let drawnWidth = drawnMaxX - drawnMinX + 1, drawnHeight = drawnMaxY - drawnMinY + 1
                        check(abs(drawnWidth - drawnHeight) <= 1, "\(name): \(drawnWidth)×\(drawnHeight)")
                        check(drawnWidth >= maxX - minX - 1 && drawnHeight >= maxY - minY - 1, "\(name): \(drawnWidth)×\(drawnHeight) in \(maxX - minX)×\(maxY - minY)")
                        shown.append(bitmap.bytes)
                        masks.append(bitmap.alphas)
                    }
                    // A selected row's prominence changes nothing of it.
                    check(shown[0] == shown[1], "\(logo) at \(Int(scale))x, \(scheme): the same in a selected row")
                }
                // Light or dark, the same shape: only Pi's color changes.
                check(masks.allSatisfy { $0 == masks[0] }, "\(logo) at \(Int(scale))x: one shape in both modes")
            }
        }
    }

    // MARK: The row's height

    static func lineHeight() {
        func row(_ caption: AgentPaneCaption) -> CGSize {
            NSHostingView(rootView: VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(verbatim: "Refactor login flow").font(.body)
                }
                caption
            }).fittingSize
        }
        func line(_ caption: AgentPaneCaption) -> CGSize { NSHostingView(rootView: caption).fittingSize }
        let words = row(AgentPaneCaption("claude", agentName: nil))
        for (text, name) in [("claude", "claude"), ("claude-code", "claude-code"), ("pi", "pi"), ("codex", "codex"), ("opencode", "opencode")] {
            check(row(AgentPaneCaption(text, agentName: name)).height == words.height, "a \(name) row as tall as one in words: \(row(AgentPaneCaption(text, agentName: name))) and \(words)")
        }
        let text = line(AgentPaneCaption("claude", agentName: nil))
        for name in ["claude", "pi"] {
            let mark = line(AgentPaneCaption(name, agentName: name))
            check(mark.width == AgentLogoMark.side && mark.height == text.height, "\(name)'s mark in a caption line's place: \(mark), words \(text)")
        }
        check(AgentLogoMark.side < text.height, "the mark's box within the line: \(AgentLogoMark.side) in \(text.height)")
    }
}
