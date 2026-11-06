#if DEBUG && os(macOS)
import AppKit
import Foundation

/// Passive diagnostics for an explicitly owned manual session. No mouse warp,
/// events, activation, model mutations or automatic GUI qualification. Samples
/// only this process's window and native views, not another application's AX.
@MainActor final class HcManualLayoutObservation {
    private let file: URL
    private var count = 0
    private var bytes = 0
    private var previous: Data?
    private var lastWrite: TimeInterval = 0
    private var truncated = false
    private(set) var error: String?
    init(root: URL) { file = root.appending(path:"manual-layout-events.jsonl") }

    private func append(_ value: [String:Any]) throws {
        let data = try JSONSerialization.data(withJSONObject:value,options:.sortedKeys) + Data([10])
        guard bytes + data.count <= 8 << 20 else { throw HcWorkspaceModel.Failure.unavailable }
        if !FileManager.default.fileExists(atPath:file.path) {
            guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else {
                throw HcWorkspaceModel.Failure.unavailable
            }
        }
        let handle = try FileHandle(forWritingTo:file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf:data); bytes += data.count
    }
    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !truncated, error == nil, now - lastWrite >= 0.2,
              let window = NSApp.windows.first(where: {
                  $0.contentView.map { $0.bounds.width > 500 && $0.bounds.height > 200 } == true
              }), let content = window.contentView,
              let split = HcWorkspaceLayoutAudit.split(content), let sidebar = split.splitViewItems.first else { return }
        let terminals = HcWorkspaceLayoutAudit.terminals(content)
        var facts: [String:Any] = [
            "window":window.windowNumber,"active":NSApp.isActive,"key":window.isKeyWindow,
            "fullscreen":window.styleMask.contains(.fullScreen),"liveResize":window.inLiveResize,
            "windowFrame":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],
            "sidebarCollapsed":sidebar.isCollapsed,"sidebarWidth":sidebar.viewController.view.bounds.width,
            "lastReportedPinIntent":WorkspaceSidebarDiagnostics.events.last?["pinned"] ?? NSNull(),
            "terminals":terminals.map { terminal -> [String:Any] in
                let frame = HcWorkspaceLayoutAudit.frame(terminal,in:content)
                return ["identity":String(describing:ObjectIdentifier(terminal)),
                    "frame":[frame.minX,frame.minY,frame.width,frame.height],
                    "grid":HcWorkspaceLayoutAudit.grid(terminal)]
            }
        ]
        do {
            let encoded = try JSONSerialization.data(withJSONObject:facts,options:.sortedKeys)
            guard encoded != previous || now - lastWrite >= 1 else { return }
            if count == 0 {
                try append(["type":"header","automatedGUIQualified":false,"passiveOnly":true,
                    "globalEventInjection":false,"pointerWarp":false,"physicalInputSourceVerified":false])
            }
            // Stop explicitly when full; never silently overwrite observations.
            if count >= 4096 { truncated = true; try append(["type":"limit","truncated":true]); return }
            let pointer = NSEvent.mouseLocation
            facts["pointer"] = [pointer.x,pointer.y]; facts["uptime"] = now
            try append(facts)
            previous = encoded; lastWrite = now; count += 1
        } catch { self.error = String(describing:error) }
    }
}
#endif
