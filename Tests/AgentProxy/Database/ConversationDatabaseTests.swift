import Foundation
import Darwin
import SQLite3
import CryptoKit
import AgentProxyCore
import AgentProxyProtocol

/// Synthetic records only, in a fresh private folder given on the command line.
@main
@MainActor
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
            let base = String(decoding:resolved.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
            try hcNamespacesAndMigration(base)
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

    static func hcNamespacesAndMigration(_ base: String) throws {
        let root = try makeRoot(base,"origin-v1-migration")
        let folder = root + "/Conversations"; guard mkdir(folder,0o700) == 0 else { throw Failure(description:"v1 folder") }
        let path = folder + "/conversations.sqlite3"
        var raw: OpaquePointer?; guard sqlite3_open(path,&raw) == SQLITE_OK, let raw else { throw Failure(description:"v1 open") }
        func sql(_ text: String) throws { guard sqlite3_exec(raw,text,nil,nil,nil) == SQLITE_OK else { throw Failure(description:"v1 fixture schema") } }
        let legacy = record("legacy-c",native:"shared-native",session:"core-A",items:[item("legacy-item","exact legacy bytes é 한글")])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let body = try encoder.encode(legacy.items[0]), children = try encoder.encode(legacy.subagents)
        do {
            try sql("CREATE TABLE conversations(id BLOB PRIMARY KEY NOT NULL,agent BLOB NOT NULL,herdr_session BLOB NOT NULL,native_session BLOB NOT NULL,route_id BLOB NOT NULL,pane_id BLOB NOT NULL,terminal_id BLOB NOT NULL,updated_order INTEGER NOT NULL,truncated INTEGER NOT NULL,status BLOB NOT NULL,subagents BLOB NOT NULL,updated_ms INTEGER NOT NULL,bytes INTEGER NOT NULL)")
            try sql("CREATE INDEX conversations_key ON conversations(agent,herdr_session,native_session,updated_ms)")
            try sql("CREATE INDEX conversations_updated ON conversations(updated_ms)")
            try sql("CREATE TABLE items(conversation BLOB NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,item_id BLOB NOT NULL,ordinal INTEGER NOT NULL,digest BLOB NOT NULL,body BLOB NOT NULL,PRIMARY KEY(conversation,item_id)) WITHOUT ROWID")
            try sql("CREATE UNIQUE INDEX items_order ON items(conversation,ordinal)")
            let hex: (Data)->String = { $0.map { String(format:"%02x",$0) }.joined() }
            let blob: (String)->String = { "X'" + hex(Data($0.utf8)) + "'" }
            try sql("INSERT INTO conversations VALUES(\(blob(legacy.id)),\(blob("claude")),\(blob("core-A")),\(blob("shared-native")),\(blob("route")),\(blob("pane")),\(blob("terminal")),1,0,\(blob("complete")),X'\(hex(children))',1800000000000,\(body.count+children.count+512))")
            try sql("INSERT INTO items VALUES(\(blob(legacy.id)),\(blob("legacy-item")),0,X'\(hex(Data(SHA256.hash(data:body))))',X'\(hex(body))')")
            try sql("PRAGMA user_version = 1")
        } catch { sqlite3_close(raw); throw error }
        sqlite3_close(raw); guard chmod(path,0o600) == 0 else { throw Failure(description:"v1 mode") }
        let badRoot = try makeRoot(base,"origin-v1-rollback")
        guard mkdir(badRoot+"/Conversations",0o700) == 0 else { throw Failure(description:"rollback folder") }
        let badPath = badRoot+"/Conversations/conversations.sqlite3"
        try FileManager.default.copyItem(atPath:path,toPath:badPath)
        var broken: OpaquePointer?
        guard sqlite3_open(badPath,&broken) == SQLITE_OK, let broken else { throw Failure(description:"rollback open") }
        guard sqlite3_exec(broken,"INSERT INTO items VALUES(X'6d697373696e67',X'6f727068616e',0,X'00',X'00')",nil,nil,nil) == SQLITE_OK else { sqlite3_close(broken);throw Failure(description:"orphan fixture") }
        sqlite3_close(broken)
        rejects(.unsafe,"v1 orphan FK aborts the whole migration") { _ = try ConversationDatabase(stateDirectory:badRoot) }
        var inspected: OpaquePointer?
        guard sqlite3_open(badPath,&inspected) == SQLITE_OK, let inspected else { throw Failure(description:"rollback inspection") }
        func scalar(_ command: String) throws -> Int64 {
            var s: OpaquePointer?;guard sqlite3_prepare_v2(inspected,command,-1,&s,nil) == SQLITE_OK, let s else { throw Failure(description:"rollback query") }
            defer { sqlite3_finalize(s) };guard sqlite3_step(s) == SQLITE_ROW else { throw Failure(description:"rollback row") };return sqlite3_column_int64(s,0)
        }
        check(try scalar("PRAGMA user_version") == 1 && scalar("SELECT count(*) FROM sqlite_schema WHERE name='conversations_v2'") == 0 && scalar("SELECT count(*) FROM items") == 2,"failed migration leaves v1 schema/version/items intact without staged tables")
        guard sqlite3_exec(inspected,"DELETE FROM items WHERE conversation=X'6d697373696e67'",nil,nil,nil) == SQLITE_OK else { sqlite3_close(inspected);throw Failure(description:"fixture repair") }
        sqlite3_close(inspected)
        let clock = Date(timeIntervalSince1970:1_800_000_000)
        do {
            let repaired = try ConversationDatabase(stateDirectory:badRoot,now:{ clock })
            check(try repaired.load(legacy.key) == legacy,"explicitly repaired fixture reopens with original exact legacy archive after rollback")
        }
        var database: ConversationDatabase? = try ConversationDatabase(stateDirectory:root,now:{ clock })
        var db: ConversationDatabase { database! }
        check(try db.load(legacy.key) == legacy,"v1 migration preserves exact key, ID, body and item foreign keys")
        func hc(_ core: String, _ id: String, bound: Bool) throws -> Record {
            let intent = try AgentProxyHcCaptureIntent(originCoreID:core,launchID:UUID(),paneID:UUID())
            var route = try AgentProxyHcRouteState(kind:.claude,intent:intent,cliVersion:"fixture")
            if bound { try route.bind(AgentProxyHcCaptureBinding(intent:intent,receiptOriginCoreID:core,terminalID:"t1")) }
            return .init(id:id,key:.init(agent:"claude",origin:ConversationOrigin(hcCoreID:core)!,nativeSession:"shared-native"),
                context:.init(routeID:"hc-route-"+id,paneID:intent.paneID.uuidString,terminalID:route.binding?.terminalID,hc:route),
                updatedOrder:1,items:[item("hc-item",core)],truncated:false,status:"complete",subagents:legacy.subagents)
        }
        let a = try hc("core-A","hc-a",bound:false), b = try hc("core-B","hc-b",bound:true)
        try db.save(a,updatedAt:clock);try db.save(b,updatedAt:clock)
        check(try db.load(a.key) == a,"hc pending origin persists without a fabricated terminal/legacy session")
        check(try db.load(b.key) == b,"hc bound origin persists explicit known terminal context")
        check(try db.load(legacy.key) == legacy && db.conversationCount == 3,"same native ID in legacy/coreA/coreB remains three SQL identities")
        let foreign = Record(id:a.id,key:b.key,context:b.context,updatedOrder:2,items:b.items,truncated:false,status:"complete",subagents:b.subagents)
        rejects(.invalidRecord,"persistent ID cannot move to another hc origin") { try db.save(foreign,updatedAt:clock) }
        check(try db.load(a.key) == a,"rejected cross-origin save leaves pending record untouched")
        let badContext = Record(id:"wrong-terminal",key:b.key,context:.init(routeID:b.context.routeID,paneID:b.context.paneID,terminalID:"t9",hc:b.context.hc),updatedOrder:2,items:b.items,truncated:false,status:"complete",subagents:b.subagents)
        rejects(.invalidRecord,"hc context cannot contradict its known binding terminal") { try db.save(badContext,updatedAt:clock) }
        let badAgent = Record(id:"wrong-agent",key:.init(agent:"pi",origin:ConversationOrigin(hcCoreID:"core-B")!,nativeSession:"shared-native"),context:b.context,updatedOrder:2,items:b.items,truncated:false,status:"complete",subagents:b.subagents)
        rejects(.invalidRecord,"hc context kind cannot move to another agent") { try db.save(badAgent,updatedAt:clock) }
        check(db.conversationCount == 3,"failed hc admission never inserts a partial SQL record")
        database = nil // exercise normal deinit/close, not a test-only close API
        let reopened = try ConversationDatabase(stateDirectory:root,now:{ clock })
        check(try reopened.load(legacy.key) == legacy && reopened.load(a.key) == a && reopened.load(b.key) == b,"migrated legacy and pending/bound hc records survive close/reopen without namespace adoption")
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
        guard sqlite3_open(path, &handle) == SQLITE_OK, sqlite3_exec(handle, "PRAGMA user_version = 3", nil, nil, nil) == SQLITE_OK else {
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
