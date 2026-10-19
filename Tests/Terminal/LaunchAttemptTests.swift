import Foundation

// One Return on the new tab launcher's tab name, through the launcher's real
// LaunchAttempt (extracted from NewTabLauncher.swift by the runner), wired as
// NewTabLauncher wires it: its `close` is the launcher's close, which tells
// the attempt and calls onClose; its `fail` shows the error in the launcher.
// onClose is ContentView's: it takes down whichever launcher is up.

/// ContentView's `launcherStart`: the launcher that is up, if any.
@MainActor final class Window {
    var launcher: Launcher?
    var onCloseCalls = 0

    func open() -> Launcher {
        let launcher = Launcher(window: self)
        self.launcher = launcher
        return launcher
    }
}

/// NewTabLauncher's state, its submit and its close. The attempt's closures
/// hold it strongly, as the view's hold a copy of the view.
@MainActor final class Launcher {
    let window: Window
    var attempt: LaunchAttempt?
    var isCreating = false
    var failure: String?
    var createdPaneRetained = false

    init(window: Window) { self.window = window }

    /// Return on the tab name.
    func submit() -> LaunchAttempt {
        isCreating = true
        let attempt = LaunchAttempt(close: { self.close() }, fail: { error, keepsCreatedPane in
            self.failure = String(describing: error)
            self.createdPaneRetained = keepsCreatedPane
            self.isCreating = false
        })
        self.attempt = attempt
        return attempt
    }

    /// Esc, a click outside, the app going to the background, Show Created
    /// Pane, and the hand-off: `close(restoringFocus:)`.
    func close() {
        attempt?.launcherClosed()
        window.onCloseCalls += 1
        window.launcher = nil
    }

    /// Taken down from outside — the pane switcher coming up, another
    /// machine — without onClose: `onDisappear`.
    func takenDown() {
        window.launcher = nil
        attempt?.launcherClosed()
    }
}

struct Refused: Error {}

@main enum LaunchAttemptTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func main() {
        handOffClosesOnce()
        nothingAfterHandOff()
        nothingAfterClosing()
        failureBeforeHandOff()
        shellClosesOnSuccess()
        print("PASS \(checks) launch attempt hand-off/late success and failure/closed launcher/next launcher/created pane checks; no app, herdr or agent")
    }

    static func handOffClosesOnce() {
        let window = Window()
        let launcher = window.open()
        let attempt = launcher.submit()
        attempt.handOff()
        check(window.launcher == nil && window.onCloseCalls == 1 && attempt.isHandedOff, "the hand-off closes the launcher")
        attempt.handOff()
        check(window.onCloseCalls == 1, "a second hand-off closes nothing")
        attempt.finish(nil)
        check(window.onCloseCalls == 1, "the launch ending after the hand-off closes nothing again")
    }

    static func nothingAfterHandOff() {
        for outcome: (any Error)? in [nil, CreatedPaneLaunchError(reason: "agent-readiness-timeout"), Refused()] {
            let window = Window()
            let launcher = window.open()
            let attempt = launcher.submit()
            attempt.handOff()
            // The agent is still getting ready; the user opens the launcher again.
            let next = window.open()
            attempt.finish(outcome)
            let name = outcome.map { "\(type(of: $0))" } ?? "success"
            check(launcher.failure == nil && !launcher.createdPaneRetained && launcher.isCreating, "\(name) after the hand-off leaves the launcher's state alone")
            check(window.launcher === next && window.onCloseCalls == 1, "\(name) after the hand-off does not close the next launcher")
            check(next.failure == nil && !next.createdPaneRetained, "\(name) after the hand-off shows nothing in the next launcher")
        }
    }

    static func nothingAfterClosing() {
        // Esc, a click outside the panel and the app going to the background
        // all close through close(restoringFocus:); the pane switcher or
        // another machine take the launcher down from outside.
        let ways: [(String, (Launcher) -> Void)] = [("closed", { $0.close() }), ("taken down", { $0.takenDown() })]
        for (way, closeLauncher) in ways {
            for outcome: (any Error)? in [nil, CreatedPaneLaunchError(reason: "rename failed"), Refused()] {
                let window = Window()
                let launcher = window.open()
                let attempt = launcher.submit()
                closeLauncher(launcher)
                let closes = window.onCloseCalls
                check(attempt.isClosed && window.launcher == nil, "\(way) before the hand-off")
                let next = window.open()
                attempt.handOff()
                check(window.launcher === next && window.onCloseCalls == closes, "a hand-off after the launcher was \(way) does not close the next launcher")
                attempt.finish(outcome)
                let name = outcome.map { "\(type(of: $0))" } ?? "success"
                check(window.launcher === next && window.onCloseCalls == closes, "\(name) after the launcher was \(way) does not close the next launcher")
                check(launcher.failure == nil && next.failure == nil && !next.createdPaneRetained, "\(name) after the launcher was \(way) shows nowhere")
            }
        }
    }

    static func failureBeforeHandOff() {
        let window = Window()
        let launcher = window.open()
        let kept = launcher.submit()
        kept.finish(CreatedPaneLaunchError(reason: "rename failed"))
        check(launcher.failure != nil && launcher.createdPaneRetained && !launcher.isCreating, "a failure that kept the created pane shows, with Show Created Pane")
        check(window.launcher === launcher && window.onCloseCalls == 0, "a failure before the hand-off leaves the launcher up")

        launcher.failure = nil; launcher.createdPaneRetained = false
        let refused = launcher.submit()
        refused.finish(Refused())
        check(launcher.failure != nil && !launcher.createdPaneRetained && !launcher.isCreating, "a failure that made no pane shows, without Show Created Pane")
        check(window.launcher === launcher && window.onCloseCalls == 0, "and leaves the launcher up")

        // Tried again, it is handed off as any other.
        launcher.failure = nil
        let again = launcher.submit()
        again.handOff()
        check(window.launcher == nil && window.onCloseCalls == 1, "a second Return after a failure closes at its hand-off")
    }

    static func shellClosesOnSuccess() {
        let window = Window()
        let launcher = window.open()
        let attempt = launcher.submit()
        attempt.finish(nil)
        check(window.launcher == nil && window.onCloseCalls == 1 && !attempt.isHandedOff, "a shell's tab, never handed off, closes the launcher when it is made")
        attempt.finish(nil)
        check(window.onCloseCalls == 1, "and only once")
    }
}
