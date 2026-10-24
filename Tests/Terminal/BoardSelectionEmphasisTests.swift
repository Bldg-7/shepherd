import AppKit
import SwiftUI
import Observation

@MainActor @Observable private final class SelectionProbe {
    var selected: String? = "pane"
    var revision = 0
    var rows = ["pane", "tab", "other"]
}
private struct SelectionList: View {
    let probe: SelectionProbe
    var body: some View {
        @Bindable var probe = probe
        List(selection: $probe.selected) {
            ForEach(probe.rows, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading) {
                        Text(id)
                        Text("secondary \(probe.revision)").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .tag(id)
                .boardSelectionEmphasized(probe.selected == id)
            }
        }.listStyle(.sidebar)
    }
}
private final class KeyboardSink: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@main @MainActor enum BoardSelectionEmphasisTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    static func settle(_ view: NSView, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(3)
        repeat {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if condition() { return true }
        } while Date() < end
        return false
    }
    static func table(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table($0) }.first
    }
    static func anchors(_ view: NSView) -> [BoardSelectionAnchor] {
        (view as? BoardSelectionAnchor).map { [$0] } ?? view.subviews.flatMap { anchors($0) }
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // First exercise native row emphasis directly, including restoration
        // and the state AppKit writes when input moves away from the sidebar.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = content
        let sink = KeyboardSink(frame: NSRect(x: 400, y: 0, width: 200, height: 400)); content.addSubview(sink)
        check(window.makeFirstResponder(sink), "terminal stand-in has keyboard")
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
            row.appearance = NSAppearance(named: name)
            row.selectionHighlightStyle = .regular
            row.isSelected = true
            row.isEmphasized = false
            content.addSubview(row)
            let cell = NSTableCellView(frame: row.bounds); row.addSubview(cell)
            let anchor = BoardSelectionAnchor(frame: row.bounds); cell.addSubview(anchor)
            anchor.setSelected(true)
            check(row.isEmphasized, "selected row uses native emphasized appearance in \(name.rawValue)")
            let focusedStyle = row.interiorBackgroundStyle
            row.isEmphasized = false
            check(row.isEmphasized && row.interiorBackgroundStyle == focusedStyle, "inactive write keeps focused native background style")
            check(window.firstResponder === sink && row.isSelected, "appearance never steals keyboard or changes selection")
            check(anchor.hitTest(.zero) == nil && !anchor.acceptsFirstResponder, "anchor cannot take clicks or keyboard")
            anchor.setSelected(false)
            check(!row.isEmphasized, "native inactive value restored after deselection")
            row.isEmphasized = true
            row.isEmphasized = false
            check(!row.isEmphasized, "observer removed after deselection")
            anchor.setSelected(true)
            anchor.removeFromSuperview()
            check(!row.isEmphasized, "removal restores row and releases observation")
            row.removeFromSuperview()
        }

        // Real SwiftUI List row hosting: production modifier must find only
        // its own containing row, survive selection/metadata/reorder updates,
        // and leave group/other rows and first responder alone.
        let probe = SelectionProbe()
        let host = NSHostingView(rootView: SelectionList(probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 440);content.addSubview(host)
        check(settle(host) { table(host)?.numberOfRows == 3 && anchors(host).count >= 3 }, "real sidebar rows and anchors mounted")
        let list = table(host)!
        func row(_ index: Int) -> NSTableRowView { list.rowView(atRow: index, makeIfNecessary: true)! }
        check(settle(host) { row(0).isSelected && row(0).isEmphasized }, "selected pane highlighted in real native List")
        check(window.makeFirstResponder(list), "sidebar can actually own keyboard")
        _ = settle(host) { row(0).isEmphasized }
        func pixels(_ view: NSView) -> Data {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let focusedPixels = pixels(row(0))
        check(!focusedPixels.isEmpty && focusedPixels.contains { $0 != 0 }, "native selected row renders nonempty pixels")
        check(window.makeFirstResponder(sink), "keyboard returns to terminal stand-in")
        row(0).isEmphasized = false
        _ = settle(host) { row(0).isEmphasized }
        check(pixels(row(0)) == focusedPixels, "selected focused/unfocused row pixels are identical")
        check(row(0).isEmphasized, "real selected row stays emphasized after terminal focus")
        row(1).isEmphasized = false
        check(!row(1).isEmphasized, "unselected tab is not forced emphasized")
        probe.selected = "tab"
        check(settle(host) { row(1).isSelected && row(1).isEmphasized }, "tab selection uses same appearance")
        row(1).isEmphasized = false
        check(row(1).isEmphasized, "selected tab also stays emphasized")
        row(0).isEmphasized = false
        check(!row(0).isEmphasized, "previous selection no longer has an emphasis override")
        probe.revision += 1
        check(settle(host) { row(1).isEmphasized }, "metadata refresh preserves selection emphasis")
        probe.rows = ["other", "pane", "tab"]
        check(settle(host) { row(2).isSelected && row(2).isEmphasized }, "reordered selected row rebinds its native host")
        row(2).isEmphasized = false
        check(row(2).isEmphasized && window.firstResponder === sink, "reordering does not move keyboard")
        probe.selected = nil
        check(settle(host) { list.selectedRow == -1 }, "selection can still clear")
        for index in 0..<3 { row(index).isEmphasized = false; check(!row(index).isEmphasized, "cleared rows have no forced emphasis") }
        check(!window.isVisible, "test window was never shown")
        host.removeFromSuperview()
        print("PASS \(count) selected-row emphasis checks; native light/dark/high-contrast style, no keyboard takeover, scoped teardown and real List hosting")
    }
}
