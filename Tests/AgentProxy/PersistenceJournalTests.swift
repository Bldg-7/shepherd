import Foundation
import Darwin
import AgentProxyCore

@main
struct PersistenceJournalTests {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        do {
            let input = CommandLine.arguments[1]
            guard mkdir(input, 0o700) == 0 || errno == EEXIST else { throw Failure() }
            _ = chmod(input, 0o700)
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(input, &resolved) != nil else { throw Failure() }
            let root = String(cString: resolved) + "/journal"
            guard mkdir(root, 0o700) == 0 else { throw Failure() }
            _ = chmod(root, 0o700)
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: root)
            let clock = Date(timeIntervalSince1970: 1_700_000_000)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let record = ConversationStore.PersistentSnapshot.Record(
                id: "record-id", key: .init(agent: "claude", herdrSession: "session", nativeSession: "native"),
                context: .init(routeID: "route", paneID: "pane", terminalID: "terminal"), updatedOrder: 1,
                items: [.init(id: "item", message: .init(role: "user", blocks: [.init(kind: "text", text: "synthetic", callID: nil, toolName: nil)], truncated: false), origin: .init(kind: "observed"), status: "complete")],
                truncated: false, status: "complete", subagents: .init(observed: 0, withFinalResult: 0, limited: false, linkAvailable: false, ancestryIncomplete: false))
            let saved = try journal.upsert(record, updatedAt: clock)
            let metadata = try journal.metadata()
            guard metadata == [saved] else { throw Failure() }
            let loaded = try journal.load(saved)
            guard loaded.record == record, loaded.metadata.updatedAt == clock else { throw Failure() }

            // Existing malformed commit-point bytes are unavailable, not an
            // empty index. A later upsert must not overwrite them.
            try files.writeIndex(Data("{".utf8))
            do {
                _ = try journal.upsert(record, updatedAt: clock)
                throw Failure()
            } catch ConversationPersistenceJournalError.unavailable {}
            guard try files.readIndex() == Data("{".utf8) else { throw Failure() }
            print("PASS: bounded persistence journal")
        } catch {
            print("FAIL: journal \(error)")
            exit(1)
        }
    }
    private struct Failure: Error {}
}
