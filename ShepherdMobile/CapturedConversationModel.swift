import Foundation
import Observation
import ShepherdKit
import AgentProxyCore

/// Read-only conversation content. Prompting, keys and agent status stay with
/// herdr in ConversationModel. Never launches a proxy or reads session files.
@MainActor @Observable
final class CapturedConversationModel {
    private(set) var window = ConversationWindow()
    private(set) var notice: String?
    private(set) var isLoadingOlder = false
    var prefersScreen = false
    var hasConversation: Bool { window.summary != nil && !window.items.isEmpty }
    var showsConversation: Bool { hasConversation && !prefersScreen }

    @ObservationIgnored private var client: ConversationClient?
    @ObservationIgnored private var selection: ConversationSelection?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var paused = false

    func connect(transport: any HerdrTransport, selection: ConversationSelection) {
        if client == nil { client = ConversationClient(transport: transport) }
        guard self.selection != selection || task == nil else { return }
        self.selection = selection
        restart()
    }
    func update(selection: ConversationSelection) {
        guard self.selection != selection else { return }
        self.selection = selection; restart()
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        client = nil; selection = nil; window = ConversationWindow(); notice = nil; isLoadingOlder = false
    }
    func pause() { paused = true; generation = UUID(); task?.cancel(); task = nil }
    func resume() { paused = false; restart() }
    func retry() { restart() }

    private func restart() {
        generation = UUID(); task?.cancel(); task = nil
        window = ConversationWindow(); notice = nil; isLoadingOlder = false
        guard !paused, let client, let selection else { return }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.follow(client: client, selection: selection, generation: generation)
        }
    }
    private func follow(client: ConversationClient, selection: ConversationSelection, generation: UUID) async {
        var delay = 2
        while !Task.isCancelled && generation == self.generation {
            do {
                guard let selected = try await client.select(selection) else {
                    window = ConversationWindow()
                    notice = String(localized: "No captured conversation yet. Showing the screen instead.")
                    try await Task.sleep(for: .seconds(3)); continue
                }
                let updates = try await client.subscribe(id: selected.header.id, epoch: selected.epoch)
                defer { updates.close() }
                var initial = true
                for try await page in updates {
                    guard !Task.isCancelled, generation == self.generation else { return }
                    guard let header = page.summary, selection.matches(header) else { throw ConversationClientError.scopeMismatch }
                    if initial { window = ConversationWindow(); initial = false }
                    try window.apply(page)
                    notice = hasConversation ? nil : String(localized: "No captured conversation yet. Showing the screen instead."); delay = 2
                }
                throw HerdrLineStreamError.closed
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                notice = String(localized: "Conversation unavailable. Showing the screen instead.")
                window = ConversationWindow()
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(30, delay * 2)
            }
        }
    }
    func loadOlder() async {
        guard !isLoadingOlder, let client, let summary = window.summary,
              let epoch = window.epoch, let before = window.nextBeforeItemID else { return }
        isLoadingOlder = true; let generation = generation
        defer { if generation == self.generation { isLoadingOlder = false } }
        do {
            let page = try await client.read(id: summary.id, epoch: epoch, before: before)
            guard generation == self.generation, !Task.isCancelled else { return }
            try window.prepend(page, before: before)
        } catch is CancellationError { return }
        catch ConversationClientError.reset { if generation == self.generation { restart() } }
        catch {
            if generation == self.generation { notice = String(localized: "Couldn't load older conversation. Try again.") }
        }
    }
}
