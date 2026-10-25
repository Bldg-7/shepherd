import SwiftUI
import UIKit

/// The additional space a bottom bar needs above a docked software keyboard.
///
/// `UIKeyboardLayoutGuide` intentionally does not follow undocked keyboards:
/// its top stays at this view's safe-area bottom while a keyboard floats or is
/// offscreen. Comparing that top with the same safe area therefore adds only
/// the part of a docked keyboard that is not already covered by SwiftUI's
/// normal container safe area.
@MainActor @Observable
final class KeyboardAvoidanceState {
    var bottomInset: CGFloat = 0
}

/// Installs an own-view keyboard guide and publishes its docked obstruction.
/// The guide belongs to this representable's view, never an application-wide
/// window lookup, so separate scenes keep their keyboard layouts independent.
struct KeyboardAvoidanceGuide: UIViewRepresentable {
    let state: KeyboardAvoidanceState

    func makeUIView(context: Context) -> KeyboardAvoidanceView {
        KeyboardAvoidanceView(state: state)
    }

    func updateUIView(_ view: KeyboardAvoidanceView, context: Context) {
        view.state = state
        view.updateBottomInset()
    }

    static func dismantleUIView(_ view: KeyboardAvoidanceView, coordinator: ()) {
        view.state?.bottomInset = 0
        view.state = nil
    }
}

@MainActor
final class KeyboardAvoidanceView: UIView {
    weak var state: KeyboardAvoidanceState?
    private(set) lazy var dockedKeyboardGuide: UIKeyboardLayoutGuide = keyboardLayoutGuide
    private let guideProbe = UIView()

    init(state: KeyboardAvoidanceState) {
        self.state = state
        super.init(frame: .zero)

        configureKeyboardGuide()

        guideProbe.translatesAutoresizingMaskIntoConstraints = false
        guideProbe.isUserInteractionEnabled = false
        addSubview(guideProbe)
        NSLayoutConstraint.activate([
            guideProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
            guideProbe.topAnchor.constraint(equalTo: dockedKeyboardGuide.topAnchor),
            guideProbe.heightAnchor.constraint(equalToConstant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // UIKit creates and attaches its keyboard guide with the view. Apply
        // its docked-only configuration again at that lifecycle boundary.
        configureKeyboardGuide()
        updateBottomInset()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBottomInset()
    }

    private func configureKeyboardGuide() {
        // This is the documented docked-only behavior. In particular, a
        // floating keyboard dragged to the bottom still leaves this guide at
        // the safe-area bottom instead of moving the composer.
        dockedKeyboardGuide.followsUndockedKeyboard = false
        // Both the guide's offscreen position and the SwiftUI bottom inset use
        // this view's ordinary safe area. It is deliberately not added again.
        dockedKeyboardGuide.usesBottomSafeArea = true
    }

    func updateBottomInset() {
        let inset = KeyboardAvoidanceGeometry.dockedBottomInset(
            safeAreaBottom: safeAreaLayoutGuide.layoutFrame.maxY,
            keyboardTop: dockedKeyboardGuide.layoutFrame.minY)
        if state?.bottomInset != inset {
            state?.bottomInset = inset
        }
    }
}

enum KeyboardAvoidanceGeometry {
    /// Both values are in the owning view's coordinate space. A docked guide
    /// rises above the safe-area bottom; an offscreen or undocked guide does
    /// not, which produces zero additional inset.
    static func dockedBottomInset(safeAreaBottom: CGFloat, keyboardTop: CGFloat) -> CGFloat {
        max(0, safeAreaBottom - keyboardTop)
    }
}
