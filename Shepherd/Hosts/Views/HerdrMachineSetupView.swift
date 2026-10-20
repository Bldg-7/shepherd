import SwiftUI
#if os(macOS)
import AppKit

/// Adding a herdr machine to the host's herdr, or checking a failing one
/// again (`HerdrMachineSetup`), in a panel over the window like the new tab
/// launcher's, worked from the keyboard alone: the SSH target — picked from
/// the host's Host aliases, which what is typed narrows down, or typed in —
/// then the name, then the checks, one row each, with what to do when they
/// stop as a list to pick from. ↑ and ↓ move in a list, Return picks,
/// Backspace in an empty field goes back a step, and Esc closes it — or,
/// while herdr saves the machine, stops herdr. A click outside the panel is
/// an Esc. Unlike the launcher it stays up when the app goes to the
/// background: the checks may still be running, and the person may have
/// gone to look something up.
struct HerdrMachineSetupView: View {
    let setup: HerdrMachineSetup

    @State private var text = ""
    @State private var highlighted = 0
    @State private var outsideClicks = OutsideClickWatcher()

    /// What the target step lists.
    private enum TargetOption: Identifiable, Equatable {
        case alias(String)
        /// What is typed, as it is.
        case typed(String)

        var id: String {
            switch self {
            case .alias(let alias): "alias/\(alias)"
            case .typed(let target): "typed/\(target)"
            }
        }

        var target: String {
            switch self {
            case .alias(let target), .typed(let target): target
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { escape() }
            panel
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    outsideClicks.panelFrame = frame
                }
                .padding(.top, 72)
                .padding(.horizontal, 24)
        }
        .onAppear {
            outsideClicks.start { escape() }
            setup.begin()
        }
        .onDisappear {
            outsideClicks.stop()
        }
        .onChange(of: setup.stage) {
            text = ""
            highlighted = 0
        }
        .onChange(of: setup.prompt) {
            highlighted = 0
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ForEach(chips, id: \.self) { chip in
                    Text(verbatim: chip)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.2), in: .capsule)
                }
                LauncherField(
                    text: $text,
                    prompt: prompt,
                    isEnabled: true,
                    // Not after handing over to a tab: that is selected,
                    // and its terminal takes the keyboard.
                    restoresFocusOnClose: !setup.didHandOff,
                    onWindow: { outsideClicks.window = $0 },
                    onMove: move,
                    onSubmit: submit,
                    onCancel: escape,
                    onDeleteBackwardInEmptyField: stepBack
                )
                .onChange(of: text) {
                    highlighted = 0
                    // Nothing is typed at the checks: the field is only
                    // there for the keys.
                    if setup.stage == .checks && !text.isEmpty { text = "" }
                }
                if setup.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let error = setup.inputError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            switch setup.stage {
            case .target:
                Divider()
                targetList
                hint("Pick a Host alias from ~/.ssh/config on \(setup.hostName), or type an SSH target — user@host, or ssh://user@host:port — and press Return.")
            case .name:
                hint("Name the machine and press Return. Left empty, it is called “\(setup.suggestedLabel)”.")
            case .checks:
                Divider()
                checkList
                promptView
            }
        }
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var chips: [String] {
        [setup.target, setup.stage == .checks ? setup.label : nil].compactMap { $0 }
    }

    private var prompt: String {
        switch setup.stage {
        case .target: String(localized: "SSH Target")
        case .name: setup.suggestedLabel
        case .checks: ""
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    // MARK: Target

    private var targetOptions: [TargetOption] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let terms = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        let aliases = setup.hostAliases
            .filter { alias in terms.allSatisfy { alias.localizedStandardContains($0) } }
            .map(TargetOption.alias)
        guard !typed.isEmpty, !setup.hostAliases.contains(typed) else { return aliases }
        return aliases + [.typed(typed)]
    }

    private var targetList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let options = targetOptions
                    if options.isEmpty {
                        Text(setup.hostAliases.isEmpty ? "No Host aliases in ~/.ssh/config. Type a target." : "No Matches")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        targetRow(option, isHighlighted: index == highlighted)
                            .id(option.id)
                            .contentShape(Rectangle())
                            .onHover { if $0 { highlighted = index } }
                            .onTapGesture {
                                highlighted = index
                                submit()
                            }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                let options = targetOptions
                if options.indices.contains(index) {
                    proxy.scrollTo(options[index].id)
                }
            }
        }
    }

    private func targetRow(_ option: TargetOption, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            switch option {
            case .alias(let alias):
                Image(systemName: "network")
                    .frame(width: 20)
                Text(verbatim: alias)
            case .typed(let target):
                Image(systemName: "arrow.right")
                    .frame(width: 20)
                Text("Use “\(target)”")
            }
            Spacer(minLength: 8)
            if let label = setup.savedLabel(forTarget: option.target) {
                Text("Saved as “\(label)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHighlighted ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
    }

    // MARK: Checks

    private var checkList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(setup.checks.enumerated()), id: \.element.id) { index, check in
                checkRow(check, number: index + 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func checkRow(_ check: HerdrMachineSetup.Check, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            checkMark(check.state)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(number)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(title(check.kind))
                    if case .running(let since) = check.state {
                        // How long the step has been running, a second at a
                        // time: some take most of a minute.
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("\(max(0, Int(context.date.timeIntervalSince(since)))) s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if let detail = check.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func checkMark(_ state: HerdrMachineSetup.CheckState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        }
    }

    private func title(_ kind: HerdrMachineSetup.CheckKind) -> LocalizedStringKey {
        switch kind {
        case .resolve: "Resolve the SSH target"
        case .signIn: "Sign in the way herdr will"
        case .herdr: "herdr on the machine"
        case .save: "Save in herdr"
        case .reconnect: "Reach the machine's herdr"
        }
    }

    @ViewBuilder
    private var promptView: some View {
        if let prompt = setup.prompt {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                switch prompt {
                case .trust(let approval):
                    trustView(approval)
                case .problem(let message, _):
                    Label {
                        Text(verbatim: message).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                case .finished(let message, _):
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            actionList(prompt.actions)
        } else if setup.isSaving {
            Divider()
            Text(setup.isStopping ? "Stopping herdr…" : "herdr is saving the machine. Press Esc to stop it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private func trustView(_ approval: HostKeyApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trust the host key of “\(approval.label)”?")
                .font(.headline)
            Text(verbatim: approval.destination)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(approval.key.displayType)  \(approval.key.fingerprint)")
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text("Trusting adds it to \(approval.file) on \(approval.hostName), as OpenSSH does when you answer yes to it. Compare it with the fingerprint the machine's administrator gives you first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func actionList(_ actions: [HerdrMachineSetup.Action]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                HStack(spacing: 10) {
                    Image(systemName: icon(action))
                        .frame(width: 20)
                    Text(actionTitle(action))
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(index == highlighted ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                .contentShape(Rectangle())
                .onHover { if $0 { highlighted = index } }
                .onTapGesture {
                    highlighted = index
                    submit()
                }
            }
        }
        .padding(8)
    }

    private func actionTitle(_ action: HerdrMachineSetup.Action) -> LocalizedStringKey {
        switch action {
        case .trust: "Trust and Continue"
        case .cancel: "Cancel"
        case .tryAgain: "Try Again"
        case .openTerminal: "Open Terminal"
        case .continueInTerminal: "Continue in Terminal"
        case .done: "Done"
        }
    }

    private func icon(_ action: HerdrMachineSetup.Action) -> String {
        switch action {
        case .trust: "checkmark.shield"
        case .cancel: "xmark"
        case .tryAgain: "arrow.clockwise"
        case .openTerminal, .continueInTerminal: "terminal"
        case .done: "checkmark"
        }
    }

    // MARK: Keys

    private func move(_ delta: Int) {
        let count: Int = switch setup.stage {
        case .target: targetOptions.count
        case .name: 0
        case .checks: setup.prompt?.actions.count ?? 0
        }
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    private func submit() {
        switch setup.stage {
        case .target:
            let options = targetOptions
            guard options.indices.contains(highlighted) else { return }
            setup.chooseTarget(options[highlighted].target)
        case .name:
            setup.chooseName(text)
        case .checks:
            guard let actions = setup.prompt?.actions, actions.indices.contains(highlighted) else { return }
            setup.perform(actions[highlighted])
        }
    }

    private func stepBack() {
        setup.stepBack()
    }

    /// Esc, or a click outside the panel: closes it — or, while herdr saves
    /// the machine, stops herdr, and leaves the panel up to say how that
    /// ended.
    private func escape() {
        if setup.isSaving {
            setup.stop()
        } else {
            setup.close()
        }
    }
}
#endif
