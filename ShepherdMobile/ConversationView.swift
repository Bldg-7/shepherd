import SwiftUI
import ShepherdKit

/// One pane, as a conversation (docs/mobile-design.md, section 3): what its
/// terminal last printed above, and below it a field to prompt the agent
/// with. The output is a snapshot of the terminal, not a transcript, and
/// is read again whenever the agent's status settles or the person pulls
/// down. Nothing here attaches to the pane: whoever has it keeps it.
///
/// While the agent waits at a question or an approval (herdr's `blocked`),
/// the field gives way to the keys such a dialog takes, and to a field
/// that writes words without Enter — herdr refuses a prompt to a blocked
/// agent, and the person, not the app, decides what the dialog is asking.
struct ConversationView: View {
    let destination: PaneDestination
    @State private var model: ConversationModel
    @Environment(\.scenePhase) private var scenePhase

    init(destination: PaneDestination, machineStore: MachineStore) {
        self.destination = destination
        _model = State(initialValue: ConversationModel(destination: destination, machineStore: machineStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.captured.hasConversation {
                Picker("Conversation display", selection: Binding(get: { model.captured.prefersScreen }, set: { model.captured.prefersScreen = $0 })) {
                    Text("Conversation").tag(false)
                    Text("Screen").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if let notice = model.captured.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if model.captured.showsConversation {
                CapturedConversationView(model: model.captured, blocked: model.agentState == .blocked)
            } else { output }
        }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Liquid Glass over the output, which scrolls on beneath it.
                if destination.agentName != nil {
                    if model.agentState == .blocked {
                        ResponseBar(model: model)
                    } else {
                        Composer(model: model)
                    }
                }
            }
            .navigationTitle(destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let state = model.agentState {
                    // A status, not a control: without the glass background
                    // the toolbar would give it, which reads as a button.
                    ToolbarItem(placement: .topBarTrailing) {
                        StateBadge(state: state)
                            .accessibilityAddTraits(.isStaticText)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .task { await model.run() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.cameBack() } }
                else { model.captured.pause() }
            }
            .onChange(of: model.captured.hasConversation) { old, new in
                if old && !new { Task { await model.reload(lines: nil) } }
            }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.truncated {
                        Text("Older output can't be read from this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let failure = model.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    if let text = model.output {
                        Text(verbatim: text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.failure == nil {
                        ProgressView()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .refreshable { await model.reload(lines: 1000) }
            .onChange(of: model.outputVersion) {
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

/// The field a prompt is typed into, and what became of the last one.
private struct Composer: View {
    @Bindable var model: ConversationModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let note = model.submissionNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(model.submission == .stalled ? .orange : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Prompt", text: $model.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .frame(minHeight: GlassBar.height)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: GlassBar.height / 2))
                        .disabled(model.isSending)
                    Button {
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(GlassBar.ProminentCircle())
                    .disabled(!model.canSend)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// What a waiting agent's dialog takes: a key, or words without Enter.
private struct ResponseBar: View {
    @Bindable var model: ConversationModel

    private static let keys: [(label: String, key: String)] = [
        ("Enter", "enter"), ("Esc", "esc"), ("↑", "up"), ("↓", "down"), ("Tab", "tab"), ("Ctrl+C", "ctrl+c")
    ]

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The agent is waiting for an answer. Read the screen above, then answer it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["y", "n"], id: \.self) { letter in
                            Button(letter) { Task { await model.respond(text: letter) } }
                                .buttonBorderShape(.circle)
                        }
                        ForEach(Self.keys, id: \.key) { item in
                            Button(item.label) { Task { await model.respond(keys: [item.key]) } }
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(.horizontal, 2)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Answer in words", text: $model.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .frame(minHeight: GlassBar.height)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: GlassBar.height / 2))
                    Button("Type") { Task { await model.respondWithDraft() } }
                        .buttonStyle(GlassBar.ProminentCapsule())
                        .disabled(model.draft.isEmpty || model.isSending)
                }
            }
            .disabled(model.isSending)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// What the input bars are built from: one height for a one-line field
/// and the button beside it, so that the two line up, and the button
/// styles that keep to it. `.glassProminent` sets its own padding, which
/// made the button taller than the field.
private enum GlassBar {
    static let height: CGFloat = 46

    struct ProminentCircle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white)
                .frame(width: height, height: height)
                .glassEffect(.regular.tint(isEnabled ? .accentColor : .gray).interactive(), in: .circle)
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }

    struct ProminentCapsule: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: height)
                .glassEffect(.regular.tint(isEnabled ? .accentColor : .gray).interactive(), in: .capsule)
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

private struct StateBadge: View {
    let state: AgentState

    var body: some View {
        PaneStatusBadge(title: state.title,
            reservedTitles: [AgentState.idle, .working, .blocked, .done, .unknown].map(\.title),
            color: color)
    }

    private var color: Color {
        switch state {
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }
}

/// The conversation's state and its one connection to the machine, held
/// for as long as the view is on screen.
@MainActor @Observable
final class ConversationModel {
    /// What became of the prompt last sent.
    enum Submission: Equatable {
        /// Being written to the pane.
        case sending
        /// Written, the agent not yet seen to take it up.
        case sent
        /// The agent went to work on it.
        case inProgress
        /// Written, and the agent did nothing for five seconds.
        case stalled
    }

    let captured = CapturedConversationModel()
    private let destination: PaneDestination
    private let machineStore: MachineStore
    private(set) var output: String?
    private(set) var truncated = false
    private(set) var failure: String?
    private(set) var agentState: AgentState?
    private(set) var submission: Submission?
    /// Goes up each time `output` is read again, for the view to scroll.
    private(set) var outputVersion = 0
    var draft = ""

    @ObservationIgnored private var client: HerdrClient?
    @ObservationIgnored private var captureTransport: (any HerdrTransport)?
    /// When the last prompt was written, for telling a stall.
    @ObservationIgnored private var sentAt: Date?

    /// How long an agent has to be seen working or waiting after a prompt
    /// before the prompt is taken for lost on it — herdr's own figure.
    private static let stallAllowance: TimeInterval = 5
    /// How long one wait for a change of status is held open.
    private static let watchTimeoutMs = 25_000

    init(destination: PaneDestination, machineStore: MachineStore) {
        self.destination = destination
        self.machineStore = machineStore
    }

    var isSending: Bool { submission == .sending }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && client != nil && agentState != .blocked
    }

    var submissionNote: String? {
        switch submission {
        case .sending: String(localized: "Sending…")
        case .sent: String(localized: "Sent. Waiting for the agent to take it up…")
        case .inProgress: String(localized: "The agent is working on it.")
        case .stalled: String(localized: "The agent didn't react to the prompt. Check the screen above before sending it again.")
        case nil: nil
        }
    }

    // MARK: Connection and watching

    /// Connects, reads the pane, and then follows the agent's status for as
    /// long as the task runs — the view's `.task`, cancelled when it leaves
    /// the screen, which also closes the connection.
    func run() async {
        do {
            let transport = try machineStore.makeHerdrTransport(for: destination.machine)
            let client = HerdrClient(transport: transport)
            try await client.connect()
            self.client = client
            // Only this paired Mac's own herdr, never a nested herdr machine
            // or an arbitrary manually-configured SSH host.
            if destination.herdrMachine == nil && destination.machine.authMethod == .secureEnclaveKey {
                captureTransport = transport
                refreshCaptureIdentity(nil)
            }
        } catch {
            failure = connectionFailureDescription(error)
            return
        }
        await reload(lines: nil)
        await refreshAgent()
        await watch()
        captured.stop(); captureTransport = nil
        let client = self.client
        self.client = nil
        await client?.disconnect()
    }

    /// Back in the foreground: the connection may have been cut meanwhile,
    /// and the pane has moved on either way.
    func cameBack() async {
        guard client != nil else { return }
        await refreshAgent()
        captured.resume()
        await reload(lines: nil)
    }

    private func watch() async {
        guard destination.agentName != nil else { return }
        while !Task.isCancelled, let client {
            let current = agentState
            let others: [AgentState] = [.idle, .working, .blocked, .done, .unknown].filter { $0 != current }
            do {
                let agent = try await client.agentWait(paneID: destination.paneID, until: others, timeoutMs: Self.watchTimeoutMs, on: destination.herdrMachine)
                guard !Task.isCancelled else { return }
                refreshCaptureIdentity(agent)
                await note(agent.state)
            } catch let error as HerdrErrorPayload where error.code == "timeout" {
                checkForStall()
                await refreshAgent()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = connectionFailureDescription(error)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// A change of the agent's status, from wherever it was seen.
    private func note(_ state: AgentState) async {
        let previous = agentState
        agentState = state
        failure = nil
        switch (submission, state) {
        case (.sent, .working), (.sent, .blocked), (.stalled, .working), (.stalled, .blocked):
            submission = .inProgress
        case (.inProgress, .idle), (.inProgress, .done):
            submission = nil
        default:
            break
        }
        if state != previous {
            await reload(lines: nil)
        }
    }

    private func checkForStall() {
        guard submission == .sent, let sentAt, Date().timeIntervalSince(sentAt) > Self.stallAllowance else { return }
        submission = .stalled
    }

    private func refreshAgent() async {
        guard destination.agentName != nil, let client else { return }
        do {
            let agent = try await client.agentGet(paneID: destination.paneID, on: destination.herdrMachine)
            refreshCaptureIdentity(agent)
            await note(agent.state)
        } catch {
            failure = connectionFailureDescription(error)
        }
    }

    private func refreshCaptureIdentity(_ agent: AgentSummary?) {
        guard let transport = captureTransport else { return }
        let name = agent == nil ? destination.agentName : agent?.agentName
        guard let name, let kind = AgentKind(herdrName: name) else { captured.stop(); return }
        let native: String?
        if let agent {
            native = agent.sessionReference?.conversationID(for: kind)
        } else { native = destination.nativeSessionID }
        captured.connect(transport: transport, selection: ConversationSelection(
            terminalID: agent?.terminalID ?? destination.terminalID,
            herdrSession: destination.machine.sessionName, agent: kind.rawValue, nativeSession: native))
    }

    // MARK: Reading

    func reload(lines: Int?) async {
        guard let client else { return }
        do {
            let read = try await client.readPane(destination.paneID, source: .recentUnwrapped, lines: lines, on: destination.herdrMachine)
            output = Self.trimmed(read.text)
            truncated = read.truncated
            outputVersion += 1
        } catch {
            failure = connectionFailureDescription(error)
        }
    }

    /// Without the blank rows a terminal keeps below its last line.
    private static func trimmed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Prompting

    /// Sends the draft. The draft is cleared only once herdr says it was
    /// written; a failure that leaves that unknown keeps it, and reads the
    /// screen instead, so that the person can see whether it arrived before
    /// sending it again — never twice by the app's own doing.
    func send() async {
        guard canSend, let client else { return }
        let text = draft
        submission = .sending
        do {
            let agent = try await client.agentGet(paneID: destination.paneID, on: destination.herdrMachine)
            if agent.state == .blocked {
                submission = nil
                await note(.blocked)
                return
            }
            try await client.agentPrompt(paneID: destination.paneID, text: text, on: destination.herdrMachine)
            draft = ""
            sentAt = Date()
            submission = .sent
            failure = nil
            // Something shows up on the screen at once; the status follows.
            await reload(lines: nil)
        } catch let error as HerdrErrorPayload where error.code == "agent_blocked" {
            submission = nil
            await note(.blocked)
        } catch {
            submission = nil
            failure = String(localized: "The prompt may or may not have reached the agent: \(connectionFailureDescription(error)) Check the screen before sending it again.")
            await reload(lines: nil)
        }
    }

    // MARK: Answering a waiting agent

    func respond(keys: [String]) async {
        guard let client else { return }
        submission = .sending
        defer { submission = nil }
        do {
            try await client.agentSendKeys(paneID: destination.paneID, keys: keys, on: destination.herdrMachine)
            await settleAfterAnswer()
        } catch {
            failure = connectionFailureDescription(error)
        }
    }

    func respond(text: String) async {
        guard let client else { return }
        submission = .sending
        defer { submission = nil }
        do {
            try await client.paneSendText(paneID: destination.paneID, text: text, on: destination.herdrMachine)
            await settleAfterAnswer()
        } catch {
            failure = connectionFailureDescription(error)
        }
    }

    func respondWithDraft() async {
        let text = draft
        guard !text.isEmpty else { return }
        await respond(text: text)
        if failure == nil { draft = "" }
    }

    /// Gives the dialog a moment to take the answer, then reads what it made
    /// of it; the watch sees the status change if there is one.
    private func settleAfterAnswer() async {
        try? await Task.sleep(for: .milliseconds(700))
        await reload(lines: nil)
    }
}
