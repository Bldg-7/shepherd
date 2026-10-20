import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One herdr the launcher can open a tab on: the host's own, or one of its
/// herdr machines, with the workspaces it has.
struct LaunchTarget: Identifiable, Equatable {
    /// The herdr machine, or nil for the host's own herdr.
    let herdrMachine: HerdrMachine?
    let label: String
    let workspaces: [LaunchWorkspace]
    /// Why no tab can be opened here right now — the machine can't be
    /// reached, hasn't been heard from yet, or runs a herdr too old to list
    /// its workspaces — or nil when one can.
    let unavailableReason: String?

    var id: String { herdrMachine?.id ?? "host" }
}

/// A workspace as the launcher lists it: with how many tabs it has, which
/// tells two workspaces of the same name apart.
struct LaunchWorkspace: Identifiable, Equatable {
    let workspace: WorkspaceSummary
    let tabCount: Int

    var id: String { workspace.id }
}

/// How the launcher is asked to come up.
enum LauncherStart {
    /// With nothing picked but what there is no choice of.
    case blank
    /// With the herdr and the workspace of the selected pane or tab picked
    /// — see `LaunchPreset.current`.
    case currentWorkspace
}

/// What the launcher comes up with already picked: a target and, where
/// there is one to pick, a workspace on it.
struct LaunchPreset: Equatable {
    /// `LaunchTarget.id`.
    let targetID: String
    let workspace: WorkspaceSummary?

    /// The herdr and the workspace `item` — the selected pane or tab — is
    /// in. Nil with nothing selected, or on a herdr no tab can be opened on
    /// right now: the launcher then asks from the start. The workspace is
    /// left to ask for when the target doesn't list the item's any more.
    static func current(for item: BoardItem?, in targets: [LaunchTarget]) -> LaunchPreset? {
        guard let item,
              let target = targets.first(where: { $0.herdrMachine?.id == item.herdrMachine?.id }),
              target.unavailableReason == nil else { return nil }
        let workspace = target.workspaces.first { $0.id == item.workspaceID }?.workspace
        return LaunchPreset(targetID: target.id, workspace: workspace)
    }
}

nonisolated enum LaunchProgram: String, CaseIterable, Sendable {
    case shell, claude, codex, pi
    var agentKind: AgentKind? { AgentKind(rawValue: rawValue) }
    var title: LocalizedStringResource {
        switch self { case .shell: "Shell"; case .claude: "Claude Code"; case .codex: "Codex"; case .pi: "Pi" }
    }
    static var launchableCases: [Self] { allCases.filter { $0 == .shell || $0.agentKind?.supportsManagedBrowserLaunch == true } }
}

nonisolated struct CreatedPaneLaunchError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { String(localized: "The created pane was kept and selected. \(reason)") }
}

/// One Return on the tab name, from the tab being asked for until its
/// launch ends. An agent's launch goes on until the agent is ready, long
/// after the launcher has closed — which it does as soon as the agent's
/// start command is in the new pane (`handOff`). The task running the launch
/// holds this, not the launcher's state, which goes with the launcher.
///
/// Once the launcher has closed — at the hand-off, or by Esc, a click
/// outside it, the app going to the background or from outside — nothing
/// that comes later reaches it: neither a failure to show nor a close, whose
/// `onClose` would close the next launcher instead.
@MainActor final class LaunchAttempt {
    private(set) var isHandedOff = false
    private(set) var isClosed = false
    private let close: () -> Void
    private let fail: (_ error: any Error, _ keepsCreatedPane: Bool) -> Void

    /// `close` closes the launcher, leaving the keyboard to the new tab;
    /// `fail` shows `error` in it, with Show Created Pane when the pane made
    /// was kept.
    init(close: @escaping () -> Void, fail: @escaping (_ error: any Error, _ keepsCreatedPane: Bool) -> Void) {
        self.close = close
        self.fail = fail
    }

    /// What was asked for has started in the new tab, which is selected and
    /// shows it: the launcher closes, once.
    func handOff() {
        guard !isHandedOff, !isClosed else { return }
        isHandedOff = true
        close()
    }

    /// The launcher has closed, whichever way.
    func launcherClosed() {
        isClosed = true
    }

    /// The launch ended, with `error` or without. Before a hand-off, a
    /// failure shows in the launcher and a success closes it.
    func finish(_ error: (any Error)?) {
        guard !isHandedOff, !isClosed else { return }
        if let error {
            fail(error, error is CreatedPaneLaunchError)
        } else {
            close()
        }
    }
}

/// What the launcher asks for once every step is done.
struct LaunchRequest {
    enum Workspace {
        case existing(WorkspaceSummary)
        /// A workspace to make first, with the name it is to have — or nil
        /// to let herdr name it.
        case new(name: String?)
    }

    let herdrMachine: HerdrMachine?
    let workspace: Workspace
    /// Nil to let herdr number the tab.
    let tabName: String?
    var program: LaunchProgram = .shell
}

/// Opens a new tab — with a new pane in it — in a few keystrokes, in the
/// manner of Spotlight: a field over the window that asks for the machine,
/// then the workspace, then the tab's name, each picked from a list that
/// what is typed narrows down, or typed in. Each answer becomes a chip in the
/// field; Backspace in an empty field takes the last one back and asks again.
/// Esc, a click anywhere else and the app going to the background close it.
///
/// With one machine only, that one is picked from the start; its chip can be
/// taken back only to get to the machine list's last row, which adds a herdr
/// machine to the host (`AddHerdrMachineOffer`) — the way to the first one.
/// The workspace list always ends with a way to make a new workspace — the
/// only way forward on a herdr that has none.
///
/// Given a `preset`, it comes up with that machine and workspace picked, as
/// if they had been answered here: their chips are in the field, and can be
/// taken back the same way.
struct NewTabLauncher: View {
    let targets: [LaunchTarget]
    let allowsBrowserAgents: Bool
    /// The machine list's row that adds a herdr machine, or nil for none.
    let addHerdrMachine: AddHerdrMachineOffer?
    /// Closes the launcher and starts adding a herdr machine.
    let onAddHerdrMachine: () -> Void
    /// Makes the tab. Throws what went wrong, which is shown in place —
    /// unless the tab was handed off first (`handOff`), as an agent's is once
    /// the agent's start command is in the new pane. The launcher closes at
    /// the hand-off; what comes after it shows in the sidebar.
    let create: (LaunchRequest, _ handOff: @escaping @MainActor () -> Void) async throws -> Void
    let onClose: () -> Void

    private enum Step {
        case machine
        case workspace
        case newWorkspaceName
        case tabName
    }

    /// What a list step offers.
    private enum Option: Identifiable {
        case machine(LauncherMachineStep.Entry)
        case workspace(LaunchWorkspace)
        /// Makes a new workspace, named after what is typed, if anything.
        case newWorkspace

        var id: String {
            switch self {
            case .machine(let entry): entry.id
            case .workspace(let workspace): "workspace/\(workspace.id)"
            case .newWorkspace: "new"
            }
        }
    }

    @State private var targetID: String?
    @State private var workspace: LaunchRequest.Workspace?
    @State private var isNamingNewWorkspace = false
    @State private var text = ""
    @State private var highlighted = 0
    @State private var isCreating = false
    @State private var program: LaunchProgram = .shell
    @State private var createdPaneRetained = false
    @State private var failure: String?
    /// Whether closing hands the keyboard back to whatever had it before.
    /// Not after a tab was opened: the new tab is selected and takes it.
    @State private var restoresFocusOnClose = true
    /// The latest Return on the tab name, told when the launcher closes.
    @State private var attempt: LaunchAttempt?
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var outsideClicks = OutsideClickWatcher()

    init(targets: [LaunchTarget], preset: LaunchPreset? = nil, allowsBrowserAgents: Bool = false,
         addHerdrMachine: AddHerdrMachineOffer? = nil, onAddHerdrMachine: @escaping () -> Void = {},
         create: @escaping (LaunchRequest, _ handOff: @escaping @MainActor () -> Void) async throws -> Void, onClose: @escaping () -> Void) {
        self.targets = targets
        self.allowsBrowserAgents = allowsBrowserAgents
        self.addHerdrMachine = addHerdrMachine
        self.onAddHerdrMachine = onAddHerdrMachine
        self.create = create
        self.onClose = onClose
        _targetID = State(initialValue: preset?.targetID ?? (targets.count == 1 ? targets.first?.id : nil))
        _workspace = State(initialValue: preset?.workspace.map { LaunchRequest.Workspace.existing($0) })
    }

    /// The picked target as the board knows it now: it is fetched again
    /// while the launcher is open, and its workspaces with it.
    private var target: LaunchTarget? {
        targets.first { $0.id == targetID }
    }

    private var step: Step {
        if target == nil { return .machine }
        if workspace == nil { return isNamingNewWorkspace ? .newWorkspaceName : .workspace }
        return .tabName
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Everything outside the panel: a click there closes the launcher,
            // and goes no further. (On macOS the clicks that land on AppKit
            // views — the list, the terminals — are caught before they get
            // there; see `OutsideClickWatcher`.)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close(restoringFocus: true) }
            panel
                #if os(macOS)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    outsideClicks.panelFrame = frame
                }
                #endif
                .padding(.top, 72)
                .padding(.horizontal, 24)
        }
        .onChange(of: targetID) { program = .shell }
        // Closed from outside as well — the pane switcher coming up, another
        // machine — a launch still going leaves the launcher alone.
        .onDisappear { attempt?.launcherClosed() }
        #if os(macOS)
        .onChange(of: controlActiveState) { _, state in
            if state != .key {
                close(restoringFocus: false)
            }
        }
        .onAppear {
            outsideClicks.start { close(restoringFocus: true) }
        }
        .onDisappear {
            outsideClicks.stop()
        }
        #endif
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.rectangle")
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
                field
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            #if os(macOS)
            if step == .tabName && allowsBrowserAgents {
                Picker("Launch", selection: $program) {
                    ForEach(LaunchProgram.launchableCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isCreating || createdPaneRetained || !allowsBrowserAgents || target?.herdrMachine != nil)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                if !allowsBrowserAgents || target?.herdrMachine != nil {
                    Text("Browser agent launching is unavailable here. Shell tabs remain available.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            #endif
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if createdPaneRetained {
                Button("Show Created Pane") { close(restoringFocus: false) }
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            switch step {
            case .machine, .workspace:
                Divider()
                optionList
            case .newWorkspaceName:
                hint("Name the new workspace and press Return. Left empty, herdr names it. It starts in the home folder of the machine.")
            case .tabName:
                hint("Name the tab and press Return to open it. Left empty, herdr numbers it.")
            }
        }
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        // The panel's own clicks stay with it rather than reaching the layer
        // behind, whose clicks close the launcher.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
    }

    private var chips: [String] {
        var chips: [String] = []
        if let target {
            chips.append(target.label)
        }
        switch workspace {
        case .existing(let workspace):
            chips.append(workspace.label)
        case .new(let name):
            chips.append(name.map { String(localized: "New Workspace \u{201C}\($0)\u{201D}") } ?? String(localized: "New Workspace"))
        case nil:
            if isNamingNewWorkspace {
                chips.append(String(localized: "New Workspace"))
            }
        }
        return chips
    }

    private var prompt: String {
        switch step {
        case .machine: String(localized: "Machine")
        case .workspace: String(localized: "Workspace")
        case .newWorkspaceName: String(localized: "Workspace Name")
        case .tabName: String(localized: "Tab Name")
        }
    }

    @ViewBuilder
    private var field: some View {
        LauncherField(
            text: $text,
            prompt: prompt,
            isEnabled: !isCreating && !createdPaneRetained,
            restoresFocusOnClose: restoresFocusOnClose,
            onWindow: { outsideClicks.window = $0 },
            onMove: move,
            onSubmit: submit,
            onCancel: { close(restoringFocus: true) },
            onDeleteBackwardInEmptyField: stepBack
        )
        .onChange(of: text) { highlighted = 0 }
    }

    // MARK: - The list steps

    private var machineStep: LauncherMachineStep {
        LauncherMachineStep(targets: targets, addHerdrMachine: addHerdrMachine)
    }

    private var options: [Option] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ label: String) -> Bool {
            terms.allSatisfy { label.localizedStandardContains($0) }
        }
        switch step {
        case .machine:
            return machineStep.entries(matching: text).map(Option.machine)
        case .workspace:
            let workspaces = (target?.workspaces ?? []).filter { matches($0.workspace.label) }.map(Option.workspace)
            return workspaces + [.newWorkspace]
        case .newWorkspaceName, .tabName:
            return []
        }
    }

    private var optionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let options = options
                    if options.isEmpty {
                        Text("No Matches")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        optionRow(option, isHighlighted: index == highlighted)
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
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                let options = options
                if options.indices.contains(index) {
                    proxy.scrollTo(options[index].id)
                }
            }
        }
    }

    private func optionRow(_ option: Option, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            switch option {
            case .machine(.target(let target)):
                Image(systemName: target.herdrMachine == nil ? "laptopcomputer" : "server.rack")
                    .frame(width: 20)
                Text(verbatim: target.label)
                Spacer(minLength: 8)
                if let reason = target.unavailableReason {
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            case .machine(.addHerdrMachine(let offer)):
                Image(systemName: "plus")
                    .frame(width: 20)
                Text("Add herdr Machine…")
                Spacer(minLength: 8)
                if let reason = offer.unavailableReason {
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            case .workspace(let workspace):
                Image(systemName: "rectangle.stack")
                    .frame(width: 20)
                Text(verbatim: workspace.workspace.label)
                Spacer(minLength: 8)
                Text("\(workspace.tabCount) tabs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .newWorkspace:
                Image(systemName: "plus")
                    .frame(width: 20)
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    Text("New Workspace…")
                } else {
                    Text("New Workspace \u{201C}\(name)\u{201D}")
                }
                Spacer(minLength: 8)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(isEnabled(option) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .background(isHighlighted ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
    }

    private func isEnabled(_ option: Option) -> Bool {
        if case .machine(let entry) = option {
            return entry.isEnabled
        }
        return true
    }

    // MARK: - Keys

    private func move(_ delta: Int) {
        let count = options.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    private func submit() {
        guard !isCreating && !createdPaneRetained else { return }
        failure = nil
        switch step {
        case .machine, .workspace:
            let options = options
            guard options.indices.contains(highlighted) else { return }
            choose(options[highlighted])
        case .newWorkspaceName:
            workspace = .new(name: trimmedText)
            isNamingNewWorkspace = false
            text = ""
        case .tabName:
            guard let target, let workspace else { return }
            let request = LaunchRequest(herdrMachine: target.herdrMachine, workspace: workspace, tabName: trimmedText,
                                        program: allowsBrowserAgents && target.herdrMachine == nil ? program : .shell)
            isCreating = true
            let attempt = LaunchAttempt(close: { close(restoringFocus: false) }, fail: { error, keepsCreatedPane in
                failure = connectionFailureDescription(error)
                createdPaneRetained = keepsCreatedPane
                isCreating = false
            })
            self.attempt = attempt
            Task {
                do {
                    try await create(request) { attempt.handOff() }
                    attempt.finish(nil)
                } catch {
                    attempt.finish(error)
                }
            }
        }
    }

    private func choose(_ option: Option) {
        switch option {
        case .machine(.target(let picked)):
            guard picked.unavailableReason == nil else { return }
            targetID = picked.id
        case .machine(.addHerdrMachine(let offer)):
            guard offer.unavailableReason == nil else { return }
            close(restoringFocus: false)
            onAddHerdrMachine()
            return
        case .workspace(let picked):
            workspace = .existing(picked.workspace)
        case .newWorkspace:
            if let name = trimmedText {
                workspace = .new(name: name)
            } else {
                isNamingNewWorkspace = true
            }
        }
        text = ""
        highlighted = 0
    }

    /// Backspace in an empty field: takes the last chip back and asks that
    /// step's question again. The machine is only taken back where there is
    /// another one to pick, or a herdr machine to add
    /// (`LauncherMachineStep.canGoBack`).
    private func stepBack() {
        guard !isCreating else { return }
        failure = nil
        switch step {
        case .tabName:
            workspace = nil
            isNamingNewWorkspace = false
        case .newWorkspaceName:
            isNamingNewWorkspace = false
        case .workspace:
            if machineStep.canGoBack {
                targetID = nil
            }
        case .machine:
            break
        }
        highlighted = 0
    }

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func close(restoringFocus: Bool) {
        attempt?.launcherClosed()
        restoresFocusOnClose = restoringFocus
        onClose()
    }
}

#if os(macOS)
/// Closes the launcher on a click anywhere in its window outside the panel.
/// A SwiftUI gesture behind the panel can't do that alone: the sidebar's
/// list and the terminals are AppKit views, and AppKit hands them a click
/// on them before SwiftUI sees it. A local event monitor sees every click
/// first; one outside the panel closes the launcher and goes no further.
/// The herdr machine setup overlay (`HerdrMachineSetupView`) uses it the
/// same way.
@MainActor
final class OutsideClickWatcher {
    /// The panel's frame in the window's top-left-origin coordinates.
    var panelFrame: CGRect = .zero
    /// The launcher's window, once its field is in it. Clicks in other
    /// windows are theirs: one of those taking the keyboard closes the
    /// launcher anyway.
    weak var window: NSWindow?
    private var monitor: Any?

    func start(onOutsideClick: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Local monitors run on the main thread; only what the decision
            // needs is handed over to it, not the event.
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            let isOutside = MainActor.assumeIsolated {
                self?.isOutsidePanel(windowNumber: windowNumber, location: location) ?? false
            }
            guard isOutside else { return event }
            MainActor.assumeIsolated { onOutsideClick() }
            return nil
        }
    }

    /// Whether a click at `location` in the window numbered `windowNumber`
    /// lands in the launcher's window, outside its panel.
    private func isOutsidePanel(windowNumber: Int, location: NSPoint) -> Bool {
        guard let window, window.windowNumber == windowNumber, let contentView = window.contentView else { return false }
        var point = contentView.convert(location, from: nil)
        if !contentView.isFlipped {
            point.y = contentView.bounds.height - point.y
        }
        return !panelFrame.contains(point)
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// The launcher's text field, in AppKit, for what SwiftUI's doesn't say:
/// whether the input method is still composing. In the middle of a Korean
/// or Japanese word, Return and Backspace belong to the input method —
/// Return ends the composition, Backspace takes a jamo back — and acting on
/// them here as well would open the tab without its last syllable, or take
/// back a chip mid-word. So the keys are only acted on with nothing marked.
/// The herdr machine setup overlay (`HerdrMachineSetupView`) has one too.
///
/// The field takes the keyboard when it comes up, and on its way out, when
/// asked to, gives it back to whatever had it.
struct LauncherField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let isEnabled: Bool
    let restoresFocusOnClose: Bool
    /// Told the window the field has landed in.
    let onWindow: (NSWindow) -> Void
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onDeleteBackwardInEmptyField: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherField
        weak var window: NSWindow?
        weak var previousResponder: NSResponder?
        /// The text last given to the field or reported by it. The field's
        /// own `stringValue` also has the syllable the input method is still
        /// composing, which AppKit doesn't report until it is committed: set
        /// back over it, that syllable would be thrown away.
        var text: String?
        /// Set while SwiftUI updates the field. What AppKit reports then —
        /// the composition committed as the field's value is replaced — isn't
        /// typing, and the launcher's state can't be changed in the middle of
        /// an update.
        var isUpdating = false

        init(_ parent: LauncherField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let field = notification.object as? NSTextField else { return }
            text = field.stringValue
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onDeleteBackwardInEmptyField()
            default:
                return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        update(field, context.coordinator)
        // Once the field is in its window: the keyboard is taken on the next
        // turn of the run loop, after SwiftUI's update that put it there.
        DispatchQueue.main.async { [weak field, coordinator = context.coordinator] in
            guard let field, let window = field.window else { return }
            coordinator.window = window
            coordinator.previousResponder = window.firstResponder
            window.makeFirstResponder(field)
            coordinator.parent.onWindow(window)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        update(field, context.coordinator)
    }

    /// Puts `text` in the field only when the launcher changed it — not on
    /// every update, where it would wipe out a syllable being composed.
    private func update(_ field: NSTextField, _ coordinator: Coordinator) {
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        if coordinator.text != text {
            coordinator.text = text
            field.stringValue = text
        }
        field.placeholderString = prompt
        field.isEditable = isEnabled
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        guard coordinator.parent.restoresFocusOnClose,
              let window = coordinator.window,
              let previous = coordinator.previousResponder,
              previous !== field.currentEditor() else { return }
        window.makeFirstResponder(previous)
    }
}
#endif
