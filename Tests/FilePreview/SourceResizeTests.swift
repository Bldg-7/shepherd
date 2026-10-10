import SwiftUI
import AppKit

@main @MainActor enum SourceResizeTests {
    static var checks = 0
    static var records: [[String: Double]] = []
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = scrollView(in: child) { return scroll } }
        return nil
    }

    static func settle(_ host: NSView, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return false
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SourceFilePreview(text: "let x = 1\n// owned 한글\nreturn x", selectedLine: nil))
        window.contentView = host
        // The owned window is never ordered, activated or sent GUI input.
        for width in [800, 400, 1200, 600, 900] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 400))
            precondition(settle(host) {
                guard let scroll = scrollView(in: host), let document = scroll.documentView else { return false }
                return abs(host.bounds.width - width) < 1 && abs(document.frame.width - width) < 2
            }, "short source must fill the live viewport after both growth and shrink")
            let scroll = scrollView(in: host)!
            let document = scroll.documentView!
            precondition(document.frame.height < 150, "short source must not wrap into a narrow central column")
            checks += 2
            records.append(["viewport": Double(host.bounds.width), "document": Double(document.frame.width), "height": Double(document.frame.height)])
        }
        let long = String(repeating: "owned_code_", count: 40)
        host.rootView = SourceFilePreview(text: "let source = \"" + long + "\"\nsecond line", selectedLine: nil, language: .swift)
        precondition(settle(host) {
            guard let doc = scrollView(in: host)?.documentView else { return false }
            return abs(doc.frame.width - host.bounds.width) < 2 && doc.frame.height > 75
        }, "source must wrap at the live width instead of overflowing horizontally")
        checks += 1
        var heights: [CGFloat: CGFloat] = [:]
        for width in [400, 1000, 500, 1200, 320] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 400))
            precondition(settle(host) {
                guard let doc = scrollView(in: host)?.documentView else { return false }
                return abs(host.bounds.width - width) < 1 && abs(doc.frame.width - width) < 2 && doc.frame.height > 75
            }, "wrapped source must never grow wider than its viewport")
            checks += 1
            let doc = scrollView(in: host)!.documentView!
            heights[width] = doc.frame.height
            records.append(["viewport": Double(host.bounds.width), "document": Double(doc.frame.width), "height": Double(doc.frame.height)])
        }
        precondition(heights[400]! > heights[1000]! && heights[320]! > heights[1200]!, "narrowing must increase wrapped height and widening must reduce it")
        checks += 1
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        print("PASS \(checks) real SwiftUI/AppKit viewport, auto-wrap and highlighted long-source resize checks; owned, unshown window only")
    }
}
