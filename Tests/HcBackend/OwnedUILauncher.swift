import AppKit
import Foundation
import Darwin

/// Owns only one private fixture child. An actual LaunchServices app may
/// voluntarily yield activation to that child; it never controls another app.
@MainActor private final class Launcher: NSObject, NSApplicationDelegate {
    let root: URL
    let app: URL
    let profile: URL
    var child: Process?
    var window: NSWindow?
    init(root: URL) {
        precondition(root.path.hasPrefix("/private/tmp/hc-screen-app."))
        self.root = root; app = root.appending(path: "OwnedShepherd.app")
        profile = root.appending(path: "private-unix.sb")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: root.appending(path: "launch-environment.json")))
            precondition(environment["HOME"] == root.appending(path: "home").path)
            var clean = environment
            clean["SHEPHERD_HC_UI_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", profile.path, app.appending(path: "Contents/MacOS/hrdrhrdrhrdr").path]
            process.environment = clean; process.currentDirectoryURL = root
            process.standardOutput = try FileHandle(forWritingTo: root.appending(path: "app.stdout.log"))
            process.standardError = try FileHandle(forWritingTo: root.appending(path: "app.stderr.log"))
            process.terminationHandler = { process in
                let code = process.terminationStatus
                DispatchQueue.main.async { exit(code) }
            }
            child = process; try process.run()
            try JSONSerialization.data(withJSONObject: ["appPID":process.processIdentifier,"helperPID":ProcessInfo.processInfo.processIdentifier]).write(to: root.appending(path: "launched-identities.json"), options: .atomic)
            let human = environment["SHEPHERD_HC_UI_HUMAN_ACTIVATION"] == "1"
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Owned hc UI fixture"
            let label = NSTextField(wrappingLabelWithString: human ? "이 테스트 창을 직접 클릭해 주세요.\n권한이나 계정 승인은 필요하지 않습니다." : "Preparing the private test window…")
            label.frame = NSRect(x: 18, y: 22, width: 360, height: 70)
            window.contentView?.addSubview(label)
            self.window = window; window.makeKeyAndOrderFront(nil); NSApp.activate()
            let pid = process.processIdentifier
            Task {
                let deadline = ContinuousClock.now.advanced(by: .seconds(human ? 240 : 10))
                while ContinuousClock.now < deadline {
                    let target = NSRunningApplication(processIdentifier: pid)
                    try? JSONSerialization.data(withJSONObject: ["helperActive":NSApp.isActive,"targetActive":target?.isActive ?? false,"targetBundle":target?.bundleURL?.path ?? "nil","expectedBundle":app.path,"targetFinished":target?.isFinishedLaunching ?? false,"focusRequested":FileManager.default.fileExists(atPath: root.appending(path: "ui-wants-focus.json").path)]).write(to: root.appending(path: "helper-stage.json"), options: .atomic)
                    if let target, target.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath(),
                       FileManager.default.fileExists(atPath: root.appending(path: "ui-wants-focus.json").path), process.isRunning, NSApp.isActive || target.isActive {
                        // A person may click the actual child rather than this
                        // helper. Observe that genuine activation; never require
                        // borrowing another app's activation or accessibility.
                        let direct = target.isActive
                        if !direct { NSApp.yieldActivation(to: target) }
                        try? JSONSerialization.data(withJSONObject: ["helperPID":ProcessInfo.processInfo.processIdentifier,"appPID":pid,"directChildActivationObserved":direct]).write(to: root.appending(path: "activation-yielded.json"), options: .atomic)
                        window.orderOut(nil)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning { process.terminate() }
            }
        } catch { exit(1) }
    }
}
@main @MainActor private struct OwnedUILauncher {
    static func main() {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHEPHERD_OWNED_UI_LAUNCH_ROOT"] ?? "")
        let delegate = Launcher(root: root)
        let app = NSApplication.shared; app.delegate = delegate
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu(title: "Owned UI fixture")
        menu.addItem(item); item.submenu = submenu
        submenu.addItem(withTitle: "Quit owned fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}
