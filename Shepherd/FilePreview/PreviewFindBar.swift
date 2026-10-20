#if os(macOS)
import SwiftUI
import AppKit

/// A preview's find bar, over its text on a capsule of Liquid Glass like the
/// sidebar's Filter: what is looked for, which match of how many it is at —
/// "No Results" when there are none — and buttons for the previous and the
/// next match and to close it.
struct PreviewFindBar: View {
    let query: String
    /// The match the bar is at, among `count`; nil while it is at none.
    let current: Int?
    let count: Int
    let keyboard: PreviewKeyboard
    let onQuery: (String) -> Void
    /// Goes to the next match, 1, or the previous one, -1.
    let onStep: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            PreviewFindField(text: query, keyboard: keyboard, onChange: onQuery, onStep: onStep, onClose: onClose)
                .frame(maxWidth: .infinity)
            if !query.isEmpty {
                Group {
                    if count == 0 {
                        Text("No Results")
                    } else {
                        Text(verbatim: "\(current.map { $0 + 1 } ?? 0) / \(count)")
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("preview.find.count")
            }
            Button { onStep(-1) } label: {
                Label("Find Previous", systemImage: "chevron.up").labelStyle(.iconOnly)
            }
            .disabled(count == 0)
            .help("Find Previous (⇧⌘G)")
            .accessibilityIdentifier("preview.find.previous")
            Button { onStep(1) } label: {
                Label("Find Next", systemImage: "chevron.down").labelStyle(.iconOnly)
            }
            .disabled(count == 0)
            .help("Find Next (⌘G)")
            .accessibilityIdentifier("preview.find.next")
            Button(action: onClose) {
                Label("Close Find Bar", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .help("Close Find Bar")
            .accessibilityIdentifier("preview.find.close")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preview.find")
    }
}

/// The find bar's field, in AppKit, for the keys it acts on: Return goes to
/// the next match, ⇧Return to the previous one, and Esc closes the bar —
/// but none of them while an input method is still composing, as in the
/// middle of a Korean or Japanese word, where they belong to it. What is
/// typed is looked for as it is typed. The keyboard is put in it by
/// `PreviewKeyboard`.
struct PreviewFindField: NSViewRepresentable {
    let text: String
    let keyboard: PreviewKeyboard
    let onChange: (String) -> Void
    let onStep: (Int) -> Void
    let onClose: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PreviewFindField
        /// The text last given to the field or reported by it. The field's
        /// own `stringValue` also has a syllable still being composed: set
        /// back over it, that would be thrown away.
        var text: String?
        /// Set while SwiftUI updates the field: what AppKit reports then
        /// isn't typing, and the preview's state can't change mid-update.
        var isUpdating = false

        init(_ parent: PreviewFindField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let field = notification.object as? NSTextField else { return }
            text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onStep(PreviewFindField.step(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true))
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onClose()
            default:
                return false
            }
            return true
        }
    }

    /// Where Return goes: to the previous match with ⇧, else to the next.
    static func step(shift: Bool) -> Int { shift ? -1 : 1 }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PreviewFindTextField {
        let field = PreviewFindTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = String(localized: "Find")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("preview.find.field")
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: PreviewFindTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        keyboard.field = field
        field.keyboard = keyboard
        // Only what the preview changed is put in the field, not what was
        // typed into it: that would wipe out a syllable being composed.
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        if coordinator.text != text {
            coordinator.text = text
            field.stringValue = text
        }
    }
}

/// The find bar's text field. Asked for the keyboard before it was in its
/// window (⌘F opening the bar), it takes it once it is: on the next turn of
/// the run loop, after SwiftUI's update that put it there.
final class PreviewFindTextField: NSTextField {
    weak var keyboard: PreviewKeyboard?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, keyboard?.fieldWanted == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let keyboard = self?.keyboard, keyboard.fieldWanted, keyboard.field === self else { return }
            keyboard.focusFindField()
        }
    }
}
#endif
