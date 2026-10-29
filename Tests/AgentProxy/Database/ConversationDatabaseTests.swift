import Foundation
import Darwin
import SQLite3
import AgentProxyCore

/// Synthetic records only, in a fresh private folder given on the command line.
@main
struct ConversationDatabaseTests {
    typealias Record = ConversationStore.PersistentSnapshot.Record
    typealias Item = ConversationStore.PersistentSnapshot.Item
    struct Failure: Error, CustomStringConvertible { let description: String }

    static var failures = 0
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition { failures += 1; FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)) }
    }
    static func rejects(_ expected: ConversationDatabase.Failure, _ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name + " (no error)") }
        catch let failure as ConversationDatabase.Failure { check(failure == expected, name + " (\(failure))") }
        catch { check(false, name + " (\(error))") }
    }

    static func item(_ id: String, _ text: String = "synthetic", status: String = "complete") -> Item {
        .init(id: id, message: .init(role: "user", blocks: [.init(kind: "text", text: text, callID: nil, toolName: nil)], truncated: false),
              origin: .init(kind: "observed"), status: status)
    }
    static func record(_ id: String, native: String = "native", session: String = "session", order: UInt64 = 1,
                       items: [Item], status: String = "complete") -> Record {
        .init(id: id, key: .init(agent: "claude", herdrSession: session, nativeSession: native),
              context: .init(routeID: "route", paneID: "pane", terminalID: "terminal"), updatedOrder: order,
              items: items, truncated: false, status: status,
              subagents: .init(observed: 0, withFinalResult: 0, limited: false, linkAvailable: false, ancestryIncomplete: false))
    }
    static func key(_ native: String = "native", session: String = "session") -> ConversationStore.PersistentSnapshot.Key {
        .init(agent: "claude", herdrSession: session, nativeSession: native)
    }

    static func makeRoot(_ base: String, _ name: String) throws -> String {
        let path = base + "/" + name
        guard mkdir(path, 0o700) == 0, chmod(path, 0o700) == 0 else { throw Failure(description: "mkdir \(name)") }
        return path
    }
    static func mode(_ path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
    }
    static func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }

    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        do {
            let input = CommandLine.arguments[1]
            guard mkdir(input, 0o700) == 0 || errno == EEXIST else { throw Failure(description: "work") }
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(input, &resolved) != nil else { throw Failure(description: "realpath") }
            let base = String(cString: resolved)
            try roundTripAndIncremental(base)
            try retentionAndExpiry(base)
            try filesystemSafety(base)
            try corruptionAndClear(base)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1)
        }
        guard failures == 0 else { exit(1) }
        print("PASS: conversation database, \(checks) checks")
    }

    static func roundTripAndIncremental(_ base: String) throws {
        let root = try makeRoot(base, "roundtrip")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let first = record("c1", items: [item("a"), item("b"), item("c", status: "streaming")], status: "streaming")
        do {
            let db = try ConversationDatabase(stateDirectory: root, now: { clock })
            let saved = try db.save(first, updatedAt: clock)
            check(saved.itemsWritten == 3 && !saved.rewroteAllItems, "first save writes every item")
            check(try db.load(key()) == first, "load returns the saved record")
            check(try db.load(key("other")) == nil, "other key is absent")

            check(try db.save(first, updatedAt: clock).itemsWritten == 0, "unchanged save writes nothing")

            // Streaming: the last item grows and a new one is appended.
            let grown = record("c1", order: 2, items: [item("a"), item("b"), item("c", "synthetic and more"), item("d")])
            let report = try db.save(grown, updatedAt: clock)
            check(report.itemsWritten == 2 && report.itemsDeleted == 0 && !report.rewroteAllItems, "only changed and new items are written")
            check(try db.load(key()) == grown, "grown record reads back in order")

            // Front truncation deletes without rewriting the rest.
            let trimmed = record("c1", order: 3, items: [item("b"), item("c", "synthetic and more"), item("d"), item("e")])
            let trim = try db.save(trimmed, updatedAt: clock)
            check(trim.itemsWritten == 1 && trim.itemsDeleted == 1 && !trim.rewroteAllItems, "dropped head item is deleted, tail appended")
            check(try db.load(key()) == trimmed, "trimmed record reads back")

            // An item inserted before retained ones forces a full rewrite.
            let reordered = record("c1", order: 4, items: [item("x"), item("b"), item("d"), item("c", "synthetic and more")])
            let full = try db.save(reordered, updatedAt: clock)
            check(full.rewroteAllItems && full.itemsWritten == 4, "reorder rewrites every item")
            check(try db.load(key()) == reordered, "reordered record reads back in its new order")

            // A persistent ID never moves to another key.
            rejects(.invalidRecord, "same ID under another key") { try db.save(record("c1", native: "moved", items: [item("a")]), updatedAt: clock) }
            rejects(.invalidRecord, "duplicate item IDs") { try db.save(record("c2", native: "dup", items: [item("a"), item("a")]), updatedAt: clock) }
            check(try db.load(key()) == reordered, "rejected saves leave the record unchanged")

            // Keys compare as exact bytes: composed and decomposed é differ.
            let composed = record("c3", native: "caf\u{e9}", items: [item("a", "composed")])
            let decomposed = record("c4", native: "cafe\u{301}", items: [item("a", "decomposed")])
            try db.save(composed, updatedAt: clock)
            try db.save(decomposed, updatedAt: clock)
            check(try db.load(key("caf\u{e9}")) == composed && (try db.load(key("cafe\u{301}")) == decomposed), "byte-exact keys")

            // The most recently updated record for a key wins.
            clock += 60
            let newer = record("c5", items: [item("n")])
            try db.save(newer, updatedAt: clock)
            check(try db.load(key()) == newer, "newest record for a key is loaded")
        }
        // A new connection sees the committed data.
        let reopened = try ConversationDatabase(stateDirectory: root, now: { clock })
        check(try reopened.load(key("caf\u{e9}"))?.id == "c3", "data survives reopening")
        let directory = root + "/Conversations"
        check(mode(directory) == 0o700, "directory is 0700")
        check(mode(directory + "/conversations.sqlite3") == 0o600, "database is 0600")
        if let wal = mode(directory + "/conversations.sqlite3-wal") { check(wal == 0o600, "WAL is 0600") }
    }

    static func retentionAndExpiry(_ base: String) throws {
        let root = try makeRoot(base, "retention")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let db = try ConversationDatabase(stateDirectory: root, now: { clock }, testingRecordLimit: 2)
        for (index, name) in ["old", "middle", "new"].enumerated() {
            clock += 1
            let report = try db.save(record("r\(index)", native: name, items: [item("a")]), updatedAt: clock)
            check(report.retiredConversations == (index == 2 ? 1 : 0), "count limit retires only when exceeded")
        }
        check(try db.load(key("old")) == nil && db.conversationCount == 2, "oldest-updated conversation is retired")
        check(try db.load(key("middle")) != nil && (try db.load(key("new")) != nil), "newer conversations stay")

        // Thirty days after its last update a conversation is no longer loaded and is expired.
        clock += Double(ConversationDatabase.retentionMilliseconds / 1_000) + 2
        check(try db.load(key("new")) == nil, "expired conversation is not loaded")
        check(try db.expire() == 2 && db.conversationCount == 0, "expiry removes expired conversations")

        let small = try makeRoot(base, "disk-limit")
        let limited = try ConversationDatabase(stateDirectory: small, now: { clock }, testingDiskLimit: 4_096)
        rejects(.invalidRecord, "an item beyond Core admission never reaches the encoded bound") {
            try limited.save(record("huge", items: [item("a", String(repeating: "\u{e9}", count: ConversationDatabase.maximumItemBodyBytes / 2 + 1))]), updatedAt: clock)
        }
        rejects(.capacity, "a record larger than the disk limit") {
            try limited.save(record("big", items: [item("a", String(repeating: "x", count: 8_192))]), updatedAt: clock)
        }
        try limited.save(record("s1", native: "one", items: [item("a", String(repeating: "x", count: 1_500))]), updatedAt: clock)
        clock += 1
        try limited.save(record("s2", native: "two", items: [item("a", String(repeating: "y", count: 1_500))]), updatedAt: clock)
        check(try limited.load(key("one")) == nil && (try limited.load(key("two")) != nil), "size limit retires oldest first")
    }

    static func filesystemSafety(_ base: String) throws {
        // A symlinked database file is refused.
        let linked = try makeRoot(base, "symlink")
        guard mkdir(linked + "/Conversations", 0o700) == 0, chmod(linked + "/Conversations", 0o700) == 0,
              symlink(base + "/elsewhere.sqlite3", linked + "/Conversations/conversations.sqlite3") == 0 else { throw Failure(description: "symlink") }
        rejects(.unsafe, "symlinked database") { _ = try ConversationDatabase(stateDirectory: linked) }
        check(!exists(base + "/elsewhere.sqlite3"), "symlink target is not created")

        // A planted WAL link is refused before SQLite can open it.
        let wal = try makeRoot(base, "wal-link")
        guard mkdir(wal + "/Conversations", 0o700) == 0, chmod(wal + "/Conversations", 0o700) == 0,
              symlink(base + "/elsewhere-wal", wal + "/Conversations/conversations.sqlite3-wal") == 0 else { throw Failure(description: "wal link") }
        rejects(.unsafe, "symlinked WAL") { _ = try ConversationDatabase(stateDirectory: wal) }

        // A group-readable state root is refused.
        let shared = base + "/shared"
        guard mkdir(shared, 0o700) == 0, chmod(shared, 0o750) == 0 else { throw Failure(description: "shared root") }
        rejects(.unsafe, "group-readable root") { _ = try ConversationDatabase(stateDirectory: shared) }

        // A world-readable existing database is refused, not repaired.
        let loose = try makeRoot(base, "loose")
        _ = try ConversationDatabase(stateDirectory: loose)
        guard chmod(loose + "/Conversations/conversations.sqlite3", 0o644) == 0 else { throw Failure(description: "chmod") }
        rejects(.unsafe, "0644 database") { _ = try ConversationDatabase(stateDirectory: loose) }

        // Replacing the database after opening is detected on the next operation.
        let swapped = try makeRoot(base, "swapped")
        let db = try ConversationDatabase(stateDirectory: swapped)
        let path = swapped + "/Conversations/conversations.sqlite3"
        guard rename(path, path + ".moved") == 0 else { throw Failure(description: "rename") }
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600); close(fd)
        rejects(.unsafe, "replaced database file") { try db.save(record("x", items: [item("a")]), updatedAt: Date()) }
    }

    static func corruptionAndClear(_ base: String) throws {
        // A newer schema is refused.
        let newer = try makeRoot(base, "newer")
        _ = try ConversationDatabase(stateDirectory: newer)
        let path = newer + "/Conversations/conversations.sqlite3"
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, sqlite3_exec(handle, "PRAGMA user_version = 2", nil, nil, nil) == SQLITE_OK else {
            throw Failure(description: "user_version")
        }
        sqlite3_close(handle)
        rejects(.unsafe, "newer schema") { _ = try ConversationDatabase(stateDirectory: newer) }

        // Garbage is refused, then clearing removes it and a fresh database opens.
        let corrupt = try makeRoot(base, "corrupt")
        _ = try ConversationDatabase(stateDirectory: corrupt)
        let file = corrupt + "/Conversations/conversations.sqlite3"
        let fd = open(file, O_WRONLY | O_TRUNC)
        let garbage = [UInt8](repeating: 0x5a, count: 8_192)
        guard fd >= 0, write(fd, garbage, garbage.count) == garbage.count else { throw Failure(description: "garbage") }
        close(fd)
        rejects(.unsafe, "corrupt database") { _ = try ConversationDatabase(stateDirectory: corrupt) }
        try ConversationDatabase.removeAll(stateDirectory: corrupt)
        check(!exists(file) && !exists(file + "-wal") && !exists(file + "-shm"), "clear removes database files")
        let fresh = try ConversationDatabase(stateDirectory: corrupt)
        check(fresh.conversationCount == 0, "fresh database after clear")

        // Clearing a populated database removes its content.
        let full = try makeRoot(base, "clear")
        do {
            let db = try ConversationDatabase(stateDirectory: full)
            try db.save(record("c", items: [item("a", "SYNTHETIC_CLEAR_MARKER")]), updatedAt: Date())
        }
        try ConversationDatabase.removeAll(stateDirectory: full)
        let after = try ConversationDatabase(stateDirectory: full)
        check(try after.load(key()) == nil, "cleared history is gone")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: full + "/Conversations")) ?? []
        for name in leftovers {
            let data = FileManager.default.contents(atPath: full + "/Conversations/" + name) ?? Data()
            check(data.range(of: Data("SYNTHETIC_CLEAR_MARKER".utf8)) == nil, "no cleared text remains in \(name)")
        }
    }
}
