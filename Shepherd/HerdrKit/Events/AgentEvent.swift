import Foundation

/// Something that happened to an agent in a herdr pane that is worth telling
/// a person about — or, for `agent.resumed`, worth taking back what they
/// were told. One event is one change of one agent's status, as the one who
/// made the event (its producer) saw it.
///
/// The JSON is the contract, not this type. Shepherd on a Mac is the only
/// producer for now, but one on another device, or a herdr plugin on a
/// remote machine, has to write the same JSON, and the examples in
/// Tests/Notifications/agent-events are what every implementation is
/// tested against. So:
/// - keys are snake_case, and times ISO-8601 in UTC;
/// - a reader takes kinds, urgencies, scopes and fields it doesn't know in
///   its stride, and fields are only ever added — never renamed, retyped or
///   given another meaning;
/// - an event, encoded, stays within `maximumEncodedSize`, well inside the
///   4 KB a remote notification's payload can have;
/// - nothing in it is meant to be read by a person as it is: `display`
///   holds what such text is made of, and whoever shows the event puts it
///   together, in its own language;
/// - nothing a terminal printed is in it, and no working directory;
/// - nothing that only means something on one device is in it, except
///   `subject.herdr.instance_id` for as long as its `scope` says so.
nonisolated struct AgentEvent: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// In bytes, encoded. `fittedToSizeLimit()` shortens what it can to
    /// stay within it.
    static let maximumEncodedSize = 2048
    /// In bytes.
    static let maximumCollapseKeySize = 64

    /// Of the event's JSON, so that a reader can tell what it is reading
    /// when producers of different versions are about.
    var schemaVersion: Int
    /// This one occurrence (see `identifier`): the same change of status,
    /// seen twice, has the same ID, and is told about once.
    var id: String
    var kind: Kind
    /// How much it needs the person, so that a reader can show even a kind
    /// it doesn't know about as it should be shown.
    var urgency: Urgency
    /// When the change was seen. Whole seconds.
    var observedAt: Date
    /// After this it is old news, and is dropped rather than shown.
    var expiresAt: Date?
    var subject: Subject
    var transition: Transition
    var display: Display
    var producer: Producer

    /// What happened. A string rather than an enum, so that one a reader
    /// doesn't know decodes all the same.
    struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        /// The agent waits for the person: an answer, or an approval to go
        /// on. Its status went to `blocked`.
        static let needsInput = Kind(rawValue: "agent.needs_input")
        /// The agent has done what it was doing: from `working` or
        /// `blocked` to `idle` or `done`.
        static let finished = Kind(rawValue: "agent.finished")
        /// The agent is working again. Not shown: it takes back what was
        /// shown about the pane before.
        static let resumed = Kind(rawValue: "agent.resumed")
        /// The agent went away while it was working. Not made yet.
        static let exited = Kind(rawValue: "agent.exited")

        /// The urgency the kind has, for a kind this reader knows.
        var urgency: Urgency? {
            switch self {
            case .needsInput: .attention
            case .finished, .exited: .info
            case .resumed: .silent
            default: nil
            }
        }
    }

    struct Urgency: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        /// The person is held up until they act.
        static let attention = Urgency(rawValue: "attention")
        /// Worth knowing, nothing waits on it.
        static let info = Urgency(rawValue: "info")
        /// Not to be shown at all.
        static let silent = Urgency(rawValue: "silent")
    }

    /// Whether an instance ID means the same herdr on every device.
    struct Scope: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        /// Only on the device that made the event: Shepherd's own ID for
        /// the machine, which another device doesn't know.
        static let deviceLocal = Scope(rawValue: "device_local")
        /// The same on every device.
        static let global = Scope(rawValue: "global")
    }

    /// The herdr server the pane is in. Pane IDs mean something only
    /// within one, and are used again once a pane has closed.
    struct HerdrInstance: Codable, Equatable, Sendable {
        /// Opaque: which herdr server, as far as `scope` reaches.
        var instanceID: String
        var scope: Scope
        /// herdr's session name, "default" for its default one.
        var session: String?

        enum CodingKeys: String, CodingKey {
            case instanceID = "instance_id"
            case scope
            case session
        }
    }

    /// Where it happened.
    struct Subject: Codable, Equatable, Sendable {
        var herdr: HerdrInstance
        /// The terminal in the pane. Not used again by a herdr server,
        /// unlike pane IDs, so with the instance it is the pane.
        var terminalID: String
        var paneID: String
        var tabID: String?
        var workspaceID: String?
        /// The agent herdr recognises in the pane ("claude", "codex").
        var agent: String?
        /// The same for every event about this pane, so that a new one can
        /// take the place of the one shown before (see `collapseKey`). At
        /// most `maximumCollapseKeySize` bytes.
        var collapseKey: String

        enum CodingKeys: String, CodingKey {
            case herdr
            case terminalID = "terminal_id"
            case paneID = "pane_id"
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
            case agent
            case collapseKey = "collapse_key"
        }
    }

    /// The change of status, in herdr's words (`agent_status`).
    struct Transition: Codable, Equatable, Sendable {
        var from: String
        var to: String
        /// herdr's number for the change, counted across its server.
        var stateChangeSeq: Int?
        /// How long the agent had been working, when it is known.
        var workedSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case from
            case to
            case stateChangeSeq = "state_change_seq"
            case workedSeconds = "worked_seconds"
        }
    }

    /// What the text shown for the event is made of, so that it can be
    /// shown by a device that can't ask herdr.
    struct Display: Codable, Equatable, Sendable {
        var agentName: String?
        var paneTitle: String?
        var tabLabel: String?
        var workspaceLabel: String?
        var machineLabel: String?

        enum CodingKeys: String, CodingKey {
            case agentName = "agent_name"
            case paneTitle = "pane_title"
            case tabLabel = "tab_label"
            case workspaceLabel = "workspace_label"
            case machineLabel = "machine_label"
        }

        /// Each text cut to at most `limit` characters, the last of them an
        /// ellipsis; none at all with a limit of zero.
        func truncated(to limit: Int) -> Display {
            func cut(_ text: String?) -> String? {
                guard let text, limit > 0 else { return nil }
                guard text.count > limit else { return text }
                return String(text.prefix(limit - 1)) + "…"
            }
            return Display(agentName: cut(agentName), paneTitle: cut(paneTitle), tabLabel: cut(tabLabel),
                           workspaceLabel: cut(workspaceLabel), machineLabel: cut(machineLabel))
        }
    }

    /// Who made the event.
    struct Producer: Codable, Equatable, Sendable {
        /// "shepherd-macos", say.
        var kind: String
        var version: String?
        /// This one installation of it.
        var instance: String?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case kind
        case urgency
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
        case subject
        case transition
        case display
        case producer
    }

    init(schemaVersion: Int = AgentEvent.currentSchemaVersion, id: String, kind: Kind, urgency: Urgency,
         observedAt: Date, expiresAt: Date?, subject: Subject, transition: Transition, display: Display, producer: Producer) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.urgency = urgency
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.subject = subject
        self.transition = transition
        self.display = display
        self.producer = producer
    }

    /// `display` and `producer` are taken as empty when they are missing:
    /// an event is still worth reading without them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        urgency = try container.decode(Urgency.self, forKey: .urgency)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        subject = try container.decode(Subject.self, forKey: .subject)
        transition = try container.decode(Transition.self, forKey: .transition)
        display = try container.decodeIfPresent(Display.self, forKey: .display) ?? Display()
        producer = try container.decodeIfPresent(Producer.self, forKey: .producer) ?? Producer(kind: "unknown")
    }

    // MARK: JSON

    /// The event's JSON: keys sorted, times in whole seconds.
    static func encode(_ event: AgentEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return try encoder.encode(event)
    }

    /// An event from its JSON. Times may have fractions of a second.
    static func decode(_ data: Data) throws -> AgentEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 time: \(text)")
        }
        return try decoder.decode(AgentEvent.self, from: data)
    }

    /// "2026-10-14T03:21:07Z".
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// The event, its display texts shortened as far as it takes to stay
    /// within `maximumEncodedSize` — 80 characters each to begin with, then
    /// half that, and so on. Nothing else is cut: the rest identifies the
    /// event, and is short.
    func fittedToSizeLimit() -> AgentEvent {
        var limit = 80
        var event = self
        event.display = display.truncated(to: limit)
        while limit > 0, let size = try? Self.encode(event).count, size > Self.maximumEncodedSize {
            limit /= 2
            event.display = display.truncated(to: limit)
        }
        return event
    }

    // MARK: Identity

    /// `collapse_key`: the first 32 hex digits of the SHA-256 of the UTF-8
    /// of `<instance_id>\n<terminal_id>`.
    static func collapseKey(instanceID: String, terminalID: String) -> String {
        String(AgentEventDigest.sha256Hex("\(instanceID)\n\(terminalID)").prefix(32))
    }

    /// `id`: the first 32 hex digits of the SHA-256 of the UTF-8 of
    /// `<instance_id>\n<terminal_id>\n<seq>\n<kind>`, where `<seq>` is
    /// `state_change_seq` in decimal — or, from a herdr that doesn't give
    /// one, `@` and `observed_at` as the event has it.
    static func identifier(instanceID: String, terminalID: String, stateChangeSeq: Int?, observedAt: Date, kind: Kind) -> String {
        let sequence = stateChangeSeq.map(String.init) ?? "@" + timestamp(observedAt)
        return String(AgentEventDigest.sha256Hex("\(instanceID)\n\(terminalID)\n\(sequence)\n\(kind.rawValue)").prefix(32))
    }
}
