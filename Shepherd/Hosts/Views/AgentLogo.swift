import SwiftUI

/// The mark of an agent herdr reports running in a pane, which the pane's
/// row in the sidebar shows in place of the agent's name (see
/// `AgentPaneCaption`). Only Claude and Pi have one here: Codex has no mark
/// of its own, and every other agent herdr knows keeps its name in words.
/// The iOS app shows the name.
///
/// Each mark is drawn from its maker's SVG: the path data as it is there,
/// in the colors it has there, never tinted — their makers allow no change
/// of color, proportion or shape — with room around it (`clearSpace`) and
/// no trademark symbol beside it.
nonisolated enum AgentLogo: CaseIterable, Sendable {
    /// Claude's spark: "Claude Spark - Clay.svg" from Anthropic's press kit,
    /// https://www.anthropic.com/press-kit (in its archive under "Anthropic media resources/Anthropic logos/
    /// Claude logos/3 Claude Spark/SVG/"), downloaded on 2026-10-21; the SVG
    /// file's sha256 is
    /// 6d53db4be375e899c937c26cf16684a80d6e869b1928d72b37748bef2560e219, the
    /// archive's c68ac92df86c825f95177e24016fcc9a8863a3fd4ca344fe6f0700b2c1e07151.
    /// One path in a 94 × 94 viewBox, filled #D97757.
    case claude
    /// Pi's compact badge: https://pi.dev/favicon.svg, as
    /// https://pi.dev/press-kit gives it, downloaded on 2026-10-21; sha256
    /// d266b2c1d2c7bf169ca30d438963b176fba16fea6263b9ac30c8302f34ad7ce7.
    /// Three paths in a 560 × 560 viewBox, filled #111111, or #F6F6F6 in
    /// dark mode.
    case pi

    /// The mark of the agent herdr calls `herdrName`, going by `AgentKind`'s
    /// reading of herdr's names; nil for an agent without one.
    init?(herdrName: String) {
        switch AgentKind(herdrName: herdrName) {
        case .claude: self = .claude
        case .pi: self = .pi
        case .codex, nil: return nil
        }
    }

    /// The agent, whose name the mark is read as and hovering shows.
    var kind: AgentKind {
        switch self {
        case .claude: .claude
        case .pi: .pi
        }
    }

    /// The side of the SVG's viewBox, which is square and starts at 0, 0.
    var viewBox: CGFloat {
        switch self {
        case .claude: 94
        case .pi: 560
        }
    }

    /// The `d` of each of the SVG's paths, in order and as it is there.
    var pathData: [String] {
        switch self {
        case .claude:
            [
                """
                M18.7657 62.4437L37.1822 52.1167L37.4857 51.2122L37.1822 50.7085H36.2715L33.1852 \
                50.5208L22.6615 50.2391L13.5545 49.8636L4.70044 49.3942L2.47428 48.9248L0.399902 \
                46.1553L0.602281 44.794L2.47428 43.5266L5.15579 43.7613L11.0754 44.1837L19.98 \
                44.794L26.4055 45.1695L35.9679 46.1553H37.4857L37.6881 45.545L37.1822 45.1695L36.7774 \
                44.794L27.5692 38.5508L17.6021 31.9791L12.3908 28.1769L9.60812 26.2524L8.19147 \
                24.4686L7.58433 20.5256L10.1141 17.7091L13.5545 17.9438L14.4146 18.1785L17.9056 \
                20.8542L25.343 26.6279L35.0572 33.7629L36.4739 34.9364L37.0443 34.5514L37.1316 \
                34.2792L36.4739 33.1996L31.212 23.6706L25.596 13.9539L23.0663 9.91695L22.4086 \
                7.52296C22.1538 6.51831 22.0038 5.68714 22.0038 4.65957L24.8877 0.716544L26.5067 \
                0.200195L30.4025 0.716544L32.0215 2.12477L34.4501 7.66379L38.3458 16.3478L44.4172 \
                28.1769L46.188 31.6975L47.1493 34.9364L47.5035 35.9222H48.1106V35.3589L48.6166 \
                28.6933L49.5273 20.5256L50.438 10.0108L50.7415 7.05356L52.2088 3.48605L55.1433 \
                1.56148L57.42 2.64112L59.292 5.31674L59.039 7.05356L57.926 14.2824L55.7504 25.5952L54.3337 \
                33.1996H55.1433L56.1046 32.2138L59.9497 27.1442L66.3752 19.0704L69.2085 15.8784L72.5478 \
                12.3579L74.6728 10.668H78.7203L81.6548 15.0804L80.3394 19.6337L76.1906 24.8911L72.7502 \
                29.3504L67.8172 35.9595L64.7562 41.2734L65.0307 41.7118L65.7681 41.6489L76.8989 \
                39.255L82.9197 38.1753L90.1041 36.9549L93.3422 38.457L93.6963 40.006L92.4315 43.151L84.7411 \
                45.0287L75.7353 46.8594L62.3244 50.0164L62.1759 50.1358L62.3512 50.3958L68.399 \
                50.9432L70.9794 51.084H77.3037L89.0922 51.9759L92.1785 53.9944L93.9999 56.4822L93.6963 \
                58.4068L88.9404 60.8008L82.5655 59.2987L67.6401 55.7312L62.5301 \
                54.4638H61.8217V54.8862L66.0717 59.064L73.9139 66.1051L83.6786 75.2116L84.1845 \
                77.4648L82.9197 79.2485L81.6042 79.0608L73.0032 72.5829L69.6639 69.6726L62.1759 \
                63.3356H61.67V63.9928L63.3902 66.5276L72.5478 80.2812L73.0032 84.5059L72.3454 \
                85.8672L69.9675 86.7121L67.3871 86.2427L61.9735 78.6852L56.4587 70.2359L52.0064 \
                62.6315L51.4687 62.971L48.8189 91.2654L47.6047 92.7206L44.7714 93.8002L42.3934 \
                92.0164L41.1286 89.1061L42.3934 83.3324L43.9113 75.8219L45.1255 69.8604L46.2386 \
                62.4437L46.9184 59.9661L46.8583 59.8003L46.3153 59.8916L40.7238 67.5603L32.2239 \
                79.0608L25.4948 86.2427L23.8758 86.8999L21.0931 85.4447L21.3461 82.863L22.9145 \
                80.5629L32.2239 68.7338L37.8399 61.3641L41.4594 57.1337L41.4242 56.5218L41.2244 \
                56.5048L16.489 72.6299L12.0873 73.1932L10.1647 71.4094L10.4176 68.4991L11.3283 \
                67.5603L18.7657 62.4437Z
                """
            ]
        case .pi:
            [
                "M420 280H280V140H0V0H420V280Z",
                "M560 560H420V280H560V560Z",
                "M140 560H0V140H140V280H280V420H140V560Z"
            ]
        }
    }

    /// The SVG's fill, sRGB `0xRRGGBB`, in light or dark mode.
    func fill(in colorScheme: ColorScheme) -> UInt32 {
        switch self {
        case .claude: 0xD97757
        case .pi: colorScheme == .dark ? 0xF6F6F6 : 0x111111
        }
    }

    /// `fill(in:)`, to fill the mark with.
    func color(in colorScheme: ColorScheme) -> Color {
        let rgb = fill(in: colorScheme)
        return Color(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// The mark's paths as one outline, parsed once — nil only if they
    /// don't parse, which the agent logo runner rules out, and then the row
    /// shows the name.
    var outline: AgentLogoOutline? {
        switch self {
        case .claude: Self.claudeOutline
        case .pi: Self.piOutline
        }
    }

    private static let claudeOutline = AgentLogoOutline(svgPathData: AgentLogo.claude.pathData)
    private static let piOutline = AgentLogoOutline(svgPathData: AgentLogo.pi.pathData)

    /// The room left empty on each side of a mark, as a part of its box's
    /// side: a point of a 12-point box.
    static let clearSpace: CGFloat = 1.0 / 12
}

/// An outline from SVG path data, in the SVG's coordinates, for the
/// commands the marks use and no others: absolute moveto, lineto,
/// horizontal and vertical lineto, cubic Bézier curveto and closepath (M, L,
/// H, V, C and Z), each taking as many numbers as follow it — after M, as
/// linetos — with numbers set apart by spaces, commas or their own signs
/// and decimal points. Anything else, such as a relative or another
/// command, an exponent or a number missing, fails the whole outline
/// rather than drawing part of a mark.
nonisolated struct AgentLogoOutline: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    let segments: [Segment]

    /// Every path of `pathData` in turn, each from its own moveto, as one
    /// outline. Filled together, nonzero as an SVG fills each by default,
    /// paths that only meet at their edges — as the Pi badge's three do —
    /// fill as they do apart, without seams between them. Nil if any path
    /// doesn't parse, or there is none.
    init?(svgPathData pathData: [String]) {
        var segments: [Segment] = []
        for data in pathData {
            guard let parsed = Self.segments(of: data) else { return nil }
            segments += parsed
        }
        guard !segments.isEmpty else { return nil }
        self.segments = segments
    }

    /// The box around every point the outline names, control points too.
    var bounds: CGRect {
        let points = segments.flatMap { segment -> [CGPoint] in
            switch segment {
            case .move(let point), .line(let point): [point]
            case .curve(let point, let control1, let control2): [point, control1, control2]
            case .close: []
            }
        }
        guard let first = points.first else { return .null }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// The outline drawn in `rect`: its square `viewBox` scaled to the
    /// largest square there, in the middle, so the mark keeps its
    /// proportions in a frame of any shape.
    func path(in rect: CGRect, viewBox: CGFloat) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let originX = rect.midX - viewBox * scale / 2, originY = rect.midY - viewBox * scale / 2
        func place(_ point: CGPoint) -> CGPoint { CGPoint(x: originX + point.x * scale, y: originY + point.y * scale) }
        var path = Path()
        for segment in segments {
            switch segment {
            case .move(let point): path.move(to: place(point))
            case .line(let point): path.addLine(to: place(point))
            case .curve(let point, let control1, let control2): path.addCurve(to: place(point), control1: place(control1), control2: place(control2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    /// One path's data as segments, or nil if any of it is more than this
    /// reads, or it doesn't start with a moveto.
    private static func segments(of data: String) -> [Segment]? {
        let bytes = Array(data.utf8)
        var index = 0
        func skipSeparators() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[index]) { index += 1 }
        }
        func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
        func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = 0
            while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { return nil }
            return CGFloat(value)
        }
        func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        var segments: [Segment] = []
        var current = CGPoint.zero, subpathStart = CGPoint.zero
        var command: UInt8?
        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) {
                command = byte
                index += 1
            } else if command == nil || command == UInt8(ascii: "Z") {
                // A number with no command to take it.
                return nil
            }
            switch command {
            case UInt8(ascii: "M"):
                guard let to = point() else { return nil }
                segments.append(.move(to))
                current = to; subpathStart = to
                // Points after a moveto's first are linetos.
                command = UInt8(ascii: "L")
            case UInt8(ascii: "L"):
                guard let to = point() else { return nil }
                segments.append(.line(to))
                current = to
            case UInt8(ascii: "H"):
                guard let x = number() else { return nil }
                current = CGPoint(x: x, y: current.y)
                segments.append(.line(current))
            case UInt8(ascii: "V"):
                guard let y = number() else { return nil }
                current = CGPoint(x: current.x, y: y)
                segments.append(.line(current))
            case UInt8(ascii: "C"):
                guard let control1 = point(), let control2 = point(), let to = point() else { return nil }
                segments.append(.curve(to: to, control1: control1, control2: control2))
                current = to
            case UInt8(ascii: "Z"):
                segments.append(.close)
                current = subpathStart
            default:
                return nil
            }
        }
        guard case .move = segments.first else { return nil }
        return segments
    }
}

/// A mark's outline as a shape, in the largest square of its frame.
nonisolated struct AgentLogoShape: Shape {
    let outline: AgentLogoOutline
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        outline.path(in: rect, viewBox: viewBox)
    }
}

/// A pane row's second line in the sidebar: the mark of the agent herdr
/// reports in the pane, for an agent with one, or else `text` in words,
/// as the line was before marks.
struct AgentPaneCaption: View {
    let text: String
    let logo: AgentLogo?

    init(_ text: String, agentName: String?) {
        self.text = text
        self.logo = agentName.flatMap(AgentLogo.init(herdrName:))
    }

    var body: some View {
        if let logo, let outline = logo.outline {
            AgentLogoMark(logo: logo, outline: outline)
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A mark in a box `side` points square, in the place of a line of caption
/// text, read as the agent's name.
struct AgentLogoMark: View {
    let logo: AgentLogo
    let outline: AgentLogoOutline
    @Environment(\.colorScheme) private var colorScheme

    /// About as tall as a line of caption text, which is 13 points.
    static let side: CGFloat = 12

    var body: some View {
        // An empty line of caption text holds the mark's place, so that the
        // row is as tall as with the name in words: the list leaves less
        // room above a line of text than above a view of another kind.
        Text(verbatim: " ")
            .font(.caption)
            .hidden()
            .frame(width: Self.side, alignment: .leading)
            .overlay {
                // Its own colors whatever is around it, a selected row's
                // accent included.
                AgentLogoShape(outline: outline, viewBox: logo.viewBox)
                    .fill(logo.color(in: colorScheme))
                    .padding(Self.side * AgentLogo.clearSpace)
                    .frame(width: Self.side, height: Self.side)
            }
            // Read as the name was, as text rather than an image.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(logo.kind.title))
            .accessibilityAddTraits(.isStaticText)
            .help(Text(logo.kind.title))
    }
}
