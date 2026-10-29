import Foundation
import Darwin
import CryptoKit
import SQLite3
import AgentProxyCore

/// Normalized conversations in one private SQLite database. A conversation is
/// one metadata row plus one row per item, so a save writes only the items
/// that changed since the last commit. Items are binary property lists: unlike
/// JSON, they store text without escaping, so an item takes at most about
/// twice its UTF-8 size. Each save, expiry and retention pass is
/// one transaction. Route authorization is never stored: a loaded record must
/// be gated again by the caller before it becomes visible. Use one instance
/// from one thread.
final class ConversationDatabase {
    enum Failure: Error, Equatable {
        /// Ownership, permissions, symlinks, a newer schema or corruption.
        /// Clearing history removes the files.
        case unsafe
        /// I/O, a full disk, memory or a busy lock. A later retry may succeed.
        case unavailable
        case capacity
        case invalidRecord
    }

    struct SaveReport: Equatable {
        let itemsWritten: Int
        let itemsDeleted: Int
        let rewroteAllItems: Bool
        let retiredConversations: Int
    }

    static let directoryName = "Conversations"
    static let fileName = "conversations.sqlite3"
    static let schemaVersion: Int32 = 1
    static let maximumRecords = 256
    static let maximumDiskBytes = 256 << 20
    static let retentionMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
    /// Encoded bounds: twice the 4 MiB normalized conversation limit, as text
    /// with any non-ASCII character is stored as UTF-16, plus structure. They
    /// also bound what one load or save holds at once.
    static let maximumItemBodyBytes = 10 << 20
    static let maximumConversationBodyBytes = 10 << 20
    /// Page cache plus statement workspace a connection may hold.
    static let connectionWorkspaceBytes = 4 << 20
    private static let rowOverheadBytes = 256

    private let rootFD: Int32
    private let directoryFD: Int32
    private let fileFD: Int32
    private let stateDirectory: String
    private var db: OpaquePointer?
    private var closed = false
    private let now: () -> Date
    private let recordLimit: Int
    private let diskLimit: Int

    init(stateDirectory: String, now: @escaping () -> Date = Date.init,
         testingRecordLimit: Int = ConversationDatabase.maximumRecords,
         testingDiskLimit: Int = ConversationDatabase.maximumDiskBytes) throws {
        self.stateDirectory = stateDirectory
        self.now = now
        recordLimit = max(1, min(testingRecordLimit, Self.maximumRecords))
        diskLimit = max(1, min(testingDiskLimit, Self.maximumDiskBytes))
        var root: Int32 = -1, directory: Int32 = -1, file: Int32 = -1
        do {
            root = try ConversationStateRoot.openVerified(stateDirectory)
            directory = try ConversationStateRoot.openOrCreateDirectory(named: Self.directoryName, in: root)
            // SQLite names its WAL and shared-memory files itself. Refuse a
            // planted link or foreign file before it can open one.
            for name in [Self.fileName + "-wal", Self.fileName + "-shm"] { try Self.verifyIfPresent(name, in: directory) }
            file = try ConversationStateRoot.openOrCreateFile(named: Self.fileName, in: directory, maximumBytes: Int.max)
        } catch {
            for fd in [file, directory, root] where fd >= 0 { Darwin.close(fd) }
            throw Self.map(error)
        }
        rootFD = root; directoryFD = directory; fileFD = file
        do {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE
            let code = sqlite3_open_v2(path, &handle, flags, nil)
            db = handle
            guard code == SQLITE_OK else { throw Self.map(code) }
            // The pathname SQLite opened must still be the verified inode.
            try verifyBinding()
            try configure()
        } catch {
            close()
            throw Self.map(error)
        }
    }

    deinit { close() }

    private var path: String { stateDirectory + "/" + Self.directoryName + "/" + Self.fileName }

    private func close() {
        guard !closed else { return }
        closed = true
        if let db { sqlite3_close_v2(db) }
        db = nil
        for fd in [fileFD, directoryFD, rootFD] where fd >= 0 { Darwin.close(fd) }
    }

    private func configure() throws {
        try execute("PRAGMA trusted_schema = OFF")
        try execute("PRAGMA foreign_keys = ON")
        // Deleted rows and pages are overwritten, not left in free pages.
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA cell_size_check = ON")
        try execute("PRAGMA cache_size = -2048")
        sqlite3_busy_timeout(db, 1_000)
        let version = try scalar("PRAGMA user_version")
        if version == 0 {
            guard try scalar("SELECT count(*) FROM sqlite_schema") == 0 else { throw Failure.unsafe }
            // auto_vacuum takes effect only before the first table exists.
            try execute("PRAGMA auto_vacuum = INCREMENTAL")
            try execute("PRAGMA journal_mode = WAL")
            try transaction {
                try execute("""
                    CREATE TABLE conversations(
                      id BLOB PRIMARY KEY NOT NULL,
                      agent BLOB NOT NULL, herdr_session BLOB NOT NULL, native_session BLOB NOT NULL,
                      route_id BLOB NOT NULL, pane_id BLOB NOT NULL, terminal_id BLOB NOT NULL,
                      updated_order INTEGER NOT NULL, truncated INTEGER NOT NULL, status BLOB NOT NULL,
                      subagents BLOB NOT NULL, updated_ms INTEGER NOT NULL, bytes INTEGER NOT NULL)
                    """)
                try execute("CREATE INDEX conversations_key ON conversations(agent, herdr_session, native_session, updated_ms)")
                try execute("CREATE INDEX conversations_updated ON conversations(updated_ms)")
                try execute("""
                    CREATE TABLE items(
                      conversation BLOB NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                      item_id BLOB NOT NULL, ordinal INTEGER NOT NULL, digest BLOB NOT NULL, body BLOB NOT NULL,
                      PRIMARY KEY(conversation, item_id)) WITHOUT ROWID
                    """)
                try execute("CREATE UNIQUE INDEX items_order ON items(conversation, ordinal)")
                try execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        } else if version != Int64(Self.schemaVersion) {
            throw Failure.unsafe
        }
        guard try text("PRAGMA journal_mode = WAL") == "wal" else { throw Failure.unavailable }
        try execute("PRAGMA synchronous = FULL")
        guard try text("PRAGMA quick_check(1)") == "ok" else { throw Failure.unsafe }
    }

    // MARK: Operations

    /// Upserts one admitted record. Only items whose encoded body changed are
    /// written; items keep their order key unless the new order cannot be
    /// expressed by deletes and appends, in which case all items are rewritten.
    /// Expiry and oldest-updated retention run in the same transaction.
    @discardableResult
    func save(_ record: ConversationStore.PersistentSnapshot.Record, updatedAt: Date) throws -> SaveReport {
        try verifyBinding()
        guard Self.admitted(record) else { throw Failure.invalidRecord }
        let id = Data(record.id.utf8)
        guard !id.isEmpty, id.count <= 1_024 else { throw Failure.invalidRecord }
        // First pass: digests and sizes only, so one encoded body is held at a time.
        var incoming: [(id: Data, digest: Data)] = []
        incoming.reserveCapacity(record.items.count)
        var seen = Set<Data>()
        var bodyBytes = 0
        for item in record.items {
            let body = try Self.encode(item)
            let itemID = Data(item.id.utf8)
            guard seen.insert(itemID).inserted else { throw Failure.invalidRecord }
            guard body.count <= Self.maximumItemBodyBytes, body.count <= Self.maximumConversationBodyBytes - bodyBytes else { throw Failure.capacity }
            bodyBytes += body.count
            incoming.append((itemID, Self.digest(body)))
        }
        let subagents = try Self.encode(record.subagents)
        let rowBytes = bodyBytes + subagents.count + Self.rowOverheadBytes * (record.items.count + 1)
        guard rowBytes <= diskLimit else { throw Failure.capacity }
        let current = try milliseconds(now())
        var updated = try milliseconds(updatedAt)

        var report = SaveReport(itemsWritten: 0, itemsDeleted: 0, rewroteAllItems: false, retiredConversations: 0)
        try transaction {
            var retired = try execute("DELETE FROM conversations WHERE updated_ms < ? AND id != ?",
                                      [.int(current - Self.retentionMilliseconds), .blob(id)])
            var existing: [Data: (ordinal: Int64, digest: Data)] = [:]
            var existingOrder: [Data] = []
            var previousKey: [Data]?
            try query("SELECT agent, herdr_session, native_session, updated_ms FROM conversations WHERE id = ?", [.blob(id)]) { row in
                previousKey = [row.blob(0), row.blob(1), row.blob(2)]
                updated = max(updated, row.int(3))
            }
            if let previousKey {
                // A persistent ID never moves to another conversation key.
                guard previousKey == [Data(record.key.agent.utf8), Data(record.key.herdrSession.utf8), Data(record.key.nativeSession.utf8)] else {
                    throw Failure.invalidRecord
                }
                try query("SELECT item_id, ordinal, digest FROM items WHERE conversation = ? ORDER BY ordinal", [.blob(id)]) { row in
                    let itemID = row.blob(0)
                    existing[itemID] = (row.int(1), row.blob(2))
                    existingOrder.append(itemID)
                }
            }
            try execute("""
                INSERT INTO conversations(id, agent, herdr_session, native_session, route_id, pane_id, terminal_id,
                  updated_order, truncated, status, subagents, updated_ms, bytes)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET route_id = excluded.route_id, pane_id = excluded.pane_id,
                  terminal_id = excluded.terminal_id, updated_order = excluded.updated_order, truncated = excluded.truncated,
                  status = excluded.status, subagents = excluded.subagents, updated_ms = excluded.updated_ms, bytes = excluded.bytes
                """, [.blob(id), .text(record.key.agent), .text(record.key.herdrSession), .text(record.key.nativeSession),
                      .text(record.context.routeID), .text(record.context.paneID), .text(record.context.terminalID),
                      .int(Int64(clamping: record.updatedOrder)), .int(record.truncated ? 1 : 0), .text(record.status),
                      .blob(subagents), .int(updated), .int(Int64(rowBytes))])

            let incomingIDs = Set(incoming.map(\.id))
            // Incremental only if retained items keep their relative order and
            // every new item follows all of them.
            var incremental = true
            var lastRetained: Int64 = -1
            var sawNew = false
            for value in incoming {
                if let old = existing[value.id] {
                    if sawNew || old.ordinal <= lastRetained { incremental = false; break }
                    lastRetained = old.ordinal
                } else {
                    sawNew = true
                }
            }
            var written = 0, deleted = 0
            if incremental {
                for itemID in existingOrder where !incomingIDs.contains(itemID) {
                    deleted += try execute("DELETE FROM items WHERE conversation = ? AND item_id = ?", [.blob(id), .blob(itemID)])
                }
                var next = (existingOrder.compactMap { existing[$0]?.ordinal }.max() ?? -1) + 1
                for (index, value) in incoming.enumerated() {
                    if let old = existing[value.id] {
                        guard old.digest != value.digest else { continue }
                        let body = try Self.encode(record.items[index])
                        try execute("UPDATE items SET digest = ?, body = ? WHERE conversation = ? AND item_id = ?",
                                    [.blob(Self.digest(body)), .blob(body), .blob(id), .blob(value.id)])
                    } else {
                        let body = try Self.encode(record.items[index])
                        try execute("INSERT INTO items(conversation, item_id, ordinal, digest, body) VALUES(?, ?, ?, ?, ?)",
                                    [.blob(id), .blob(value.id), .int(next), .blob(Self.digest(body)), .blob(body)])
                        next += 1
                    }
                    written += 1
                }
            } else {
                deleted = try execute("DELETE FROM items WHERE conversation = ?", [.blob(id)])
                for (index, value) in incoming.enumerated() {
                    let body = try Self.encode(record.items[index])
                    try execute("INSERT INTO items(conversation, item_id, ordinal, digest, body) VALUES(?, ?, ?, ?, ?)",
                                [.blob(id), .blob(value.id), .int(Int64(index)), .blob(Self.digest(body)), .blob(body)])
                    written += 1
                }
            }
            retired += try retain(keeping: id)
            report = SaveReport(itemsWritten: written, itemsDeleted: deleted, rewroteAllItems: !incremental, retiredConversations: retired)
        }
        if report.retiredConversations > 0 { _ = try? execute("PRAGMA incremental_vacuum") }
        return report
    }

    /// The most recently updated record for a byte-exact key, or nil. A match
    /// is not authorization: the caller must recheck current owner and route
    /// authority before exposing it.
    func load(_ key: ConversationStore.PersistentSnapshot.Key) throws -> ConversationStore.PersistentSnapshot.Record? {
        try verifyBinding()
        let cutoff = try milliseconds(now()) - Self.retentionMilliseconds
        var header: (id: Data, context: ConversationStore.PersistentSnapshot.Context, order: Int64, truncated: Bool, status: String, subagents: Data)?
        try query("""
            SELECT id, route_id, pane_id, terminal_id, updated_order, truncated, status, subagents FROM conversations
            WHERE agent = ? AND herdr_session = ? AND native_session = ? AND updated_ms >= ?
            ORDER BY updated_ms DESC, id LIMIT 1
            """, [.text(key.agent), .text(key.herdrSession), .text(key.nativeSession), .int(cutoff)]) { row in
            header = (row.blob(0), .init(routeID: row.string(1), paneID: row.string(2), terminalID: row.string(3)),
                      row.int(4), row.int(5) != 0, row.string(6), row.blob(7))
        }
        guard let header else { return nil }
        var items: [ConversationStore.PersistentSnapshot.Item] = []
        var bodyBytes = 0
        try query("SELECT body FROM items WHERE conversation = ? ORDER BY ordinal", [.blob(header.id)]) { row in
            let body = row.blob(0)
            guard items.count < 4_096, body.count <= Self.maximumItemBodyBytes,
                  body.count <= Self.maximumConversationBodyBytes - bodyBytes else { throw Failure.unsafe }
            bodyBytes += body.count
            do { items.append(try PropertyListDecoder().decode(ConversationStore.PersistentSnapshot.Item.self, from: body)) }
            catch { throw Failure.unsafe }
        }
        let subagents: ConversationStore.PersistentSnapshot.Subagents
        do { subagents = try PropertyListDecoder().decode(ConversationStore.PersistentSnapshot.Subagents.self, from: header.subagents) }
        catch { throw Failure.unsafe }
        guard header.order >= 0, let id = String(data: header.id, encoding: .utf8) else { throw Failure.unsafe }
        let record = ConversationStore.PersistentSnapshot.Record(id: id, key: key, context: header.context,
            updatedOrder: UInt64(header.order), items: items, truncated: header.truncated, status: header.status, subagents: subagents)
        guard Self.admitted(record) else { throw Failure.unsafe }
        return record
    }

    /// Removes expired conversations and enforces the count and size limits.
    @discardableResult
    func expire() throws -> Int {
        try verifyBinding()
        let cutoff = try milliseconds(now()) - Self.retentionMilliseconds
        var retired = 0
        try transaction {
            retired = try execute("DELETE FROM conversations WHERE updated_ms < ?", [.int(cutoff)])
            retired += try retain(keeping: nil)
        }
        if retired > 0 { _ = try? execute("PRAGMA incremental_vacuum") }
        return retired
    }

    var conversationCount: Int { (try? scalar("SELECT count(*) FROM conversations")).map(Int.init) ?? 0 }

    /// Delete the database files without opening SQLite, so a corrupt or newer
    /// database can be cleared too. The caller must hold producer admission
    /// and have closed every connection. The WAL goes first: a WAL left beside
    /// a later database must never replay old pages into it.
    static func removeAll(stateDirectory: String) throws {
        do {
            let root = try ConversationStateRoot.openVerified(stateDirectory)
            defer { Darwin.close(root) }
            let directory = try ConversationStateRoot.openOrCreateDirectory(named: directoryName, in: root)
            defer { Darwin.close(directory) }
            for name in [fileName + "-wal", fileName + "-shm", fileName] {
                try ConversationStateRoot.removeFile(named: name, in: directory)
            }
            guard fsync(directory) == 0 else { throw ConversationStateRootError.ioFailure }
        } catch { throw map(error) }
    }

    // MARK: Retention

    /// Oldest-updated conversations go first until the count and logical size
    /// fit. The conversation being saved is never chosen; if it cannot fit on
    /// its own the transaction fails with `capacity`.
    private func retain(keeping id: Data?) throws -> Int {
        var retired = 0
        while true {
            var count: Int64 = 0, bytes: Int64 = 0
            try query("SELECT count(*), coalesce(sum(bytes), 0) FROM conversations") { row in count = row.int(0); bytes = row.int(1) }
            guard count > recordLimit || bytes > diskLimit else { return retired }
            var victim: Data?
            try query("SELECT id FROM conversations WHERE id != ? ORDER BY updated_ms, id LIMIT 1", [.blob(id ?? Data())]) { row in victim = row.blob(0) }
            guard let victim else { throw Failure.capacity }
            retired += try execute("DELETE FROM conversations WHERE id = ?", [.blob(victim)])
        }
    }

    // MARK: Validation

    /// Exactly the Core admission a restore applies, so a record that can be
    /// written can also be read back and imported.
    static func admitted(_ record: ConversationStore.PersistentSnapshot.Record) -> Bool {
        var scratch = ConversationStore()
        guard let report = try? scratch.restore(.init(records: [record])) else { return false }
        return report.rejectedRecordCount == 0 && report.evictedPersistentIDs.isEmpty &&
            report.restoredIDs.count == 1 && report.restoredIDs[Data(record.id.utf8)] != nil
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do { return try encoder.encode(value) } catch { throw Failure.invalidRecord }
    }

    private static func digest(_ body: Data) -> Data { Data(SHA256.hash(data: body)) }

    private func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard value.isFinite, value >= 0, value < 9_000_000_000_000_000 else { throw Failure.unavailable }
        return Int64(value)
    }

    /// The root, directory and database names still bind to the opened inodes.
    private func verifyBinding() throws {
        do {
            let current = try ConversationStateRoot.openVerified(stateDirectory)
            defer { Darwin.close(current) }
            var expected = stat(), actual = stat()
            guard fstat(rootFD, &expected) == 0, fstat(current, &actual) == 0,
                  expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino else { throw Failure.unsafe }
            try ConversationStateRoot.verifyDirectoryBinding(named: Self.directoryName, in: rootFD, descriptor: directoryFD)
            try ConversationStateRoot.verifyFileBinding(named: Self.fileName, in: directoryFD, descriptor: fileFD, maximumBytes: Int.max, exactSize: nil)
        } catch { throw Self.map(error) }
    }

    private static func verifyIfPresent(_ name: String, in directory: Int32) throws {
        let fd = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw ConversationStateRoot.openError(errno, unsafe: .unsafeObject) }
            return
        }
        defer { Darwin.close(fd) }
        try ConversationStateRoot.verifyFileBinding(named: name, in: directory, descriptor: fd, maximumBytes: Int.max, exactSize: nil)
    }

    private static func map(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if let failure = error as? ConversationStateRootError {
            switch failure {
            case .ioFailure, .lockUnavailable, .retryableOpen: return .unavailable
            case .unsafeStateRoot, .unsafeObject: return .unsafe
            }
        }
        return .unavailable
    }

    private static func map(_ code: Int32) -> Failure {
        switch code & 0xff {
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_FORMAT, SQLITE_PERM, SQLITE_AUTH: return .unsafe
        case SQLITE_FULL: return .capacity
        default: return .unavailable
        }
    }

    // MARK: SQLite

    enum Value {
        case int(Int64)
        case text(String)
        case blob(Data)
    }

    struct Row {
        fileprivate let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
        func string(_ column: Int32) -> String { String(decoding: blob(column), as: UTF8.self) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Returns the number of rows changed.
    @discardableResult
    private func execute(_ sql: String, _ values: [Value] = []) throws -> Int {
        try query(sql, values) { _ in }
        return Int(sqlite3_changes(db))
    }

    private func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        guard let db else { throw Failure.unavailable }
        var statement: OpaquePointer?
        var code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw Self.map(code) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number): code = sqlite3_bind_int64(statement, index, number)
            case .text(let string): code = Self.bind(Data(string.utf8), statement, index)
            case .blob(let data): code = Self.bind(data, statement, index)
            }
            guard code == SQLITE_OK else { throw Self.map(code) }
        }
        while true {
            code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw Self.map(code) }
            try row(Row(statement: statement))
        }
    }

    /// Strings are stored as UTF-8 blobs so comparisons stay byte-exact.
    private static func bind(_ data: Data, _ statement: OpaquePointer, _ index: Int32) -> Int32 {
        data.withUnsafeBytes { raw in
            // A zero-length blob still needs a non-null pointer to be non-NULL.
            sqlite3_bind_blob(statement, index, raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(raw.count), transient)
        }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var value: Int64 = 0
        try query(sql) { value = $0.int(0) }
        return value
    }

    private func text(_ sql: String) throws -> String? {
        var value: String?
        try query(sql) { value = $0.string(0) }
        return value
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }
}
