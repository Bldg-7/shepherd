#if !os(macOS)
import UIKit

/// Unlike a tap recognizer that decides at .ended, this claims a file touch
/// at .began. Native taps/pans/long-presses wait for its failure, so they cannot
/// send press, motion or release to the remote TUI for the same file gesture.
final class TerminalFileGestureRecognizer: UIGestureRecognizer {
    var resolveLink: ((CGPoint) -> String?)?
    var onOpenFile: ((String) -> Void)?
    private(set) var capturedOpenFile: ((String) -> Void)?
    private var gesture = TerminalFileGesture()
    private(set) var activatedLink: String?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, touches.count == 1, let touch = touches.first, let view else {
            if gesture.ownsPointer { gesture.cancel(); state = .cancelled }
            else { state = .failed }
            return
        }
        let point = touch.location(in: view)
        guard gesture.begin(link: resolveLink?(point), at: point) else { state = .failed; return }
        capturedOpenFile = onOpenFile
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard gesture.ownsPointer, let touch = touches.first, let view else { return }
        gesture.move(to: touch.location(in: view))
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard gesture.ownsPointer, let touch = touches.first, let view else { return }
        activatedLink = gesture.end(at: touch.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        gesture.cancel(); activatedLink = nil; state = .cancelled
    }

    override func reset() {
        super.reset()
        gesture.cancel(); activatedLink = nil; capturedOpenFile = nil
    }
}
#endif
