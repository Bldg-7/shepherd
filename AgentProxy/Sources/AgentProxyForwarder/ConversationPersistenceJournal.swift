import Foundation
import AgentProxyCore

/// A bounded journal for already-admitted Core records. The index is metadata
/// only and is never route authorization; its caller must gate a loaded record
/// again before making it visible.
enum ConversationPersistenceJournalError: Error, Equatable {
    case unavailable
    case capacity
    case invalidRecord
    /// Index rename crossed the commit point, but its durability is uncertain.
    case recordCommittedButDurabilityUncertain
    case indexCommittedButDurabilityUncertain
    /// A retention index was durable, but one or more physical removals failed.
    case retentionCommittedCleanupFailed
}

enum ConversationPersistenceJournalMaintenance: Equatable {
    case none
    case indexDurabilityUncertain
    case committed(removed: Int, cleanupCompleted: Int, cleanupDurabilityUncertain: Bool)
    case recovered(completed: Int, cleanupDurabilityUncertain: Bool)
}

enum ConversationPersistenceJournalHealth: Equatable {
    case healthy
    /// Uptime-based deadline; process-local, never persisted.
    case degraded(retryAfter: TimeInterval)
}

struct ConversationPersistenceJournalMetadata: Equatable {
    let generation: ConversationPersistenceGeneration
    /// Byte-exact persistent record identity. It is not a filesystem name.
    let recordID: Data
    let updatedAt: Date
    let encodedBytes: Int
}

struct ConversationPersistenceJournalLoadedRecord: Equatable {
    let record: ConversationStore.PersistentSnapshot.Record
    let metadata: ConversationPersistenceJournalMetadata
}

final class ConversationPersistenceJournal {
    static let maximumDiskBytes = 256 << 20
    static let maximumRecords = 256
    private static let maximumFutureMilliseconds: Int64 = 5 * 60 * 1_000
    private static let retentionMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000

    /// A bounded raw structural pass, before Codable can collapse duplicate keys.
    /// Decoded key bytes are compared within each object, not across objects.
    private struct RawJSON {
        private let bytes: [UInt8]
        private var offset = 0
        private var values = 0
        private static let maxDepth = 64
        private static let maxMembers = 512
        private static let maxArrayElements = 4_096
        private static let maxValues = 2_000_000
        private static let maxKeyTokenBytes = 4_096
        private static let maxKeyBytes = 1_024

        init(_ data: Data, maximumBytes: Int) throws {
            guard data.count <= maximumBytes else { throw ConversationPersistenceJournalError.unavailable }
            bytes = Array(data)
        }

        mutating func check() throws {
            guard String(bytes: bytes, encoding: .utf8) != nil else { throw ConversationPersistenceJournalError.unavailable }
            try value(depth: 0)
            whitespace()
            guard offset == bytes.count else { throw ConversationPersistenceJournalError.unavailable }
        }

        private mutating func whitespace() {
            while offset < bytes.count && (bytes[offset] == 0x20 || bytes[offset] == 0x09 || bytes[offset] == 0x0a || bytes[offset] == 0x0d) { offset += 1 }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            if offset < bytes.count && bytes[offset] == byte { offset += 1; return true }
            return false
        }

        private mutating func value(depth: Int) throws {
            whitespace()
            values += 1
            guard depth <= Self.maxDepth, values <= Self.maxValues, offset < bytes.count else { throw ConversationPersistenceJournalError.unavailable }
            switch bytes[offset] {
            case 0x7b: try object(depth: depth)
            case 0x5b: try array(depth: depth)
            case 0x22: _ = try stringToken(isKey: false)
            case 0x74: try literal([0x74, 0x72, 0x75, 0x65])
            case 0x66: try literal([0x66, 0x61, 0x6c, 0x73, 0x65])
            case 0x6e: try literal([0x6e, 0x75, 0x6c, 0x6c])
            case 0x2d, 0x30...0x39: try number()
            default: throw ConversationPersistenceJournalError.unavailable
            }
        }

        private mutating func object(depth: Int) throws {
            offset += 1
            whitespace()
            if consume(0x7d) { return }
            var keys = Set<Data>()
            while true {
                guard keys.count < Self.maxMembers else { throw ConversationPersistenceJournalError.unavailable }
                whitespace()
                let token = try stringToken(isKey: true)
                let decoded: String
                do { decoded = try JSONDecoder().decode(String.self, from: Data(bytes[token])) }
                catch { throw ConversationPersistenceJournalError.unavailable }
                guard decoded.utf8.count <= Self.maxKeyBytes else { throw ConversationPersistenceJournalError.unavailable }
                let key = Data(decoded.utf8)
                guard keys.insert(key).inserted else { throw ConversationPersistenceJournalError.unavailable }
                whitespace()
                guard consume(0x3a) else { throw ConversationPersistenceJournalError.unavailable }
                try value(depth: depth + 1)
                whitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else { throw ConversationPersistenceJournalError.unavailable }
            }
        }

        private mutating func array(depth: Int) throws {
            offset += 1
            whitespace()
            if consume(0x5d) { return }
            var count = 0
            while true {
                guard count < Self.maxArrayElements else { throw ConversationPersistenceJournalError.unavailable }
                count += 1
                try value(depth: depth + 1)
                whitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else { throw ConversationPersistenceJournalError.unavailable }
            }
        }

        private mutating func stringToken(isKey: Bool) throws -> Range<Int> {
            let start = offset
            guard consume(0x22) else { throw ConversationPersistenceJournalError.unavailable }
            while offset < bytes.count {
                if isKey && offset - start > Self.maxKeyTokenBytes { throw ConversationPersistenceJournalError.unavailable }
                let byte = bytes[offset]; offset += 1
                if byte == 0x22 {
                    guard !isKey || offset - start <= Self.maxKeyTokenBytes else { throw ConversationPersistenceJournalError.unavailable }
                    return start..<offset
                }
                guard byte >= 0x20 else { throw ConversationPersistenceJournalError.unavailable }
                if byte == 0x5c {
                    guard offset < bytes.count else { throw ConversationPersistenceJournalError.unavailable }
                    let escape = bytes[offset]; offset += 1
                    if escape == 0x75 {
                        let scalar = try unicodeEscape()
                        if (0xd800...0xdbff).contains(scalar) {
                            guard consume(0x5c), consume(0x75) else { throw ConversationPersistenceJournalError.unavailable }
                            let low = try unicodeEscape()
                            guard (0xdc00...0xdfff).contains(low) else { throw ConversationPersistenceJournalError.unavailable }
                        } else if (0xdc00...0xdfff).contains(scalar) {
                            throw ConversationPersistenceJournalError.unavailable
                        }
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escape) {
                        throw ConversationPersistenceJournalError.unavailable
                    }
                }
            }
            throw ConversationPersistenceJournalError.unavailable
        }

        private mutating func unicodeEscape() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard offset < bytes.count else { throw ConversationPersistenceJournalError.unavailable }
                let byte = bytes[offset]; offset += 1
                let digit: Int
                switch byte {
                case 0x30...0x39: digit = Int(byte - 0x30)
                case 0x41...0x46: digit = Int(byte - 0x41) + 10
                case 0x61...0x66: digit = Int(byte - 0x61) + 10
                default: throw ConversationPersistenceJournalError.unavailable
                }
                value = value * 16 + digit
            }
            return value
        }

        private mutating func literal(_ expected: [UInt8]) throws {
            for byte in expected {
                guard consume(byte) else { throw ConversationPersistenceJournalError.unavailable }
            }
        }

        private mutating func digits() -> Int {
            let start = offset
            while offset < bytes.count && (0x30...0x39).contains(bytes[offset]) { offset += 1 }
            return offset - start
        }

        private mutating func number() throws {
            _ = consume(0x2d)
            if !consume(0x30) {
                guard offset < bytes.count, (0x31...0x39).contains(bytes[offset]) else { throw ConversationPersistenceJournalError.unavailable }
                _ = digits()
            }
            if consume(0x2e) { guard digits() > 0 else { throw ConversationPersistenceJournalError.unavailable } }
            if consume(0x65) || consume(0x45) {
                if !consume(0x2b) { _ = consume(0x2d) }
                guard digits() > 0 else { throw ConversationPersistenceJournalError.unavailable }
            }
        }
    }

    // Exposes the same bounded parser to deterministic synthetic fixtures.
    static func validateRawJSONForTesting(_ data: Data) throws {
        var raw = try RawJSON(data, maximumBytes: ConversationPersistenceFiles.maximumRecordBytes)
        try raw.check()
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == expected else { throw ConversationPersistenceJournalError.unavailable }
    }

    private struct SingleRecordEnvelope: Decodable {
        let record: ConversationStore.PersistentSnapshot.Record
        enum CodingKeys: String, CodingKey { case schemaVersion, records }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(Int.self, forKey: .schemaVersion) == ConversationStore.PersistentSnapshot.schemaVersion else {
                throw ConversationPersistenceJournalError.unavailable
            }
            var records = try container.nestedUnkeyedContainer(forKey: .records)
            guard records.count == 1 else { throw ConversationPersistenceJournalError.unavailable }
            record = try records.decode(ConversationStore.PersistentSnapshot.Record.self)
            guard records.isAtEnd else { throw ConversationPersistenceJournalError.unavailable }
        }
    }

    // Core's Codable models tolerate unknown keys. Deletion must not discard
    // such bytes, even when Core can otherwise restore the known fields.
    private struct DeletionSchema: Decodable {
        private static func check(_ container: KeyedDecodingContainer<AnyKey>, _ allowed: Set<String>) throws {
            guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
                throw ConversationPersistenceJournalError.unavailable
            }
        }
        private static func key(_ name: String) -> AnyKey { AnyKey(stringValue: name)! }
        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: AnyKey.self)
            try Self.check(root, ["schemaVersion", "records"])
            var records = try root.nestedUnkeyedContainer(forKey: Self.key("records"))
            guard records.count == 1 else { throw ConversationPersistenceJournalError.unavailable }
            let record = try records.nestedContainer(keyedBy: AnyKey.self)
            try Self.check(record, ["id", "key", "context", "updatedOrder", "items", "truncated", "status", "subagents"])
            try Self.check(record.nestedContainer(keyedBy: AnyKey.self, forKey: Self.key("key")), ["agent", "herdrSession", "nativeSession"])
            try Self.check(record.nestedContainer(keyedBy: AnyKey.self, forKey: Self.key("context")), ["routeID", "paneID", "terminalID"])
            try Self.check(record.nestedContainer(keyedBy: AnyKey.self, forKey: Self.key("subagents")), ["observed", "withFinalResult", "limited", "linkAvailable", "ancestryIncomplete"])
            var items = try record.nestedUnkeyedContainer(forKey: Self.key("items"))
            guard let itemCount = items.count, itemCount <= 4_096 else { throw ConversationPersistenceJournalError.unavailable }
            while !items.isAtEnd {
                let item = try items.nestedContainer(keyedBy: AnyKey.self)
                try Self.check(item, ["id", "message", "origin", "status"])
                try Self.check(item.nestedContainer(keyedBy: AnyKey.self, forKey: Self.key("origin")), ["kind", "compactionAvailability", "subagentID", "subagentDepth"])
                let message = try item.nestedContainer(keyedBy: AnyKey.self, forKey: Self.key("message"))
                try Self.check(message, ["role", "blocks", "truncated"])
                var blocks = try message.nestedUnkeyedContainer(forKey: Self.key("blocks"))
                guard let blockCount = blocks.count, blockCount <= 64 else { throw ConversationPersistenceJournalError.unavailable }
                while !blocks.isAtEnd {
                    let block = try blocks.nestedContainer(keyedBy: AnyKey.self)
                    try Self.check(block, ["kind", "text", "callID", "toolName"])
                }
            }
        }
    }

    private struct Index: Codable {
        static let version = 1
        let version: Int
        let records: [Entry]

        struct Entry: Codable {
            let generation: String
            let recordID: Data
            let updatedMilliseconds: Int64
            let encodedBytes: Int

            enum CodingKeys: String, CodingKey, CaseIterable { case generation, recordID, updatedMilliseconds, encodedBytes }
            init(generation: String, recordID: Data, updatedMilliseconds: Int64, encodedBytes: Int) {
                self.generation = generation; self.recordID = recordID
                self.updatedMilliseconds = updatedMilliseconds; self.encodedBytes = encodedBytes
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try ConversationPersistenceJournal.requireKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
                generation = try container.decode(String.self, forKey: .generation)
                recordID = try container.decode(Data.self, forKey: .recordID)
                updatedMilliseconds = try container.decode(Int64.self, forKey: .updatedMilliseconds)
                encodedBytes = try container.decode(Int.self, forKey: .encodedBytes)
            }
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case version, records }
        init(records: [Entry]) { self.version = Self.version; self.records = records }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try ConversationPersistenceJournal.requireKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
            version = try container.decode(Int.self, forKey: .version)
            guard version == Self.version else { throw ConversationPersistenceJournalError.unavailable }
            var values = try container.nestedUnkeyedContainer(forKey: .records)
            var decoded: [Entry] = []
            decoded.reserveCapacity(ConversationPersistenceJournal.maximumRecords)
            while !values.isAtEnd {
                guard decoded.count < ConversationPersistenceJournal.maximumRecords else { throw ConversationPersistenceJournalError.unavailable }
                decoded.append(try values.decode(Entry.self))
            }
            records = decoded
        }
    }

    private let files: ConversationPersistenceFiles
    private let now: () -> Date
    private(set) var lastMaintenance: ConversationPersistenceJournalMaintenance = .none
    private(set) var maintenanceTransactions: [ConversationPersistenceJournalMaintenance] = []
    private let recordLimit: Int
    private let diskLimit: Int
    private let physicalLimit: Int
    private let monotonicNow: () -> TimeInterval
    private(set) var health: ConversationPersistenceJournalHealth = .healthy

    init(files: ConversationPersistenceFiles, now: @escaping () -> Date = Date.init,
         testingRecordLimit: Int = ConversationPersistenceJournal.maximumRecords,
         testingDiskLimit: Int = ConversationPersistenceJournal.maximumDiskBytes,
         testingPhysicalLimit: Int = ConversationPersistenceFiles.maximumPhysicalRecords,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.files = files
        self.now = now
        self.recordLimit = max(1, min(testingRecordLimit, Self.maximumRecords))
        self.diskLimit = max(1, min(testingDiskLimit, Self.maximumDiskBytes))
        self.physicalLimit = max(1, min(testingPhysicalLimit, ConversationPersistenceFiles.maximumPhysicalRecords))
        self.monotonicNow = monotonicNow
    }

    private func noteIOFailure(_ error: Error) {
        guard let failure = error as? ConversationPersistenceFilesError else { return }
        switch failure {
        case .ioFailure, .retryableBeforeTemporaryCreation, .committedButDurabilityUncertain:
            let time = monotonicNow()
            health = .degraded(retryAfter: time.isFinite && time >= 0 && time <= TimeInterval.greatestFiniteMagnitude - 5 ? time + 5 : TimeInterval.greatestFiniteMagnitude)
        default: break
        }
    }

    private func requireMaintenanceAllowed() throws {
        let uptime = monotonicNow()
        guard uptime.isFinite, uptime >= 0 else { throw ConversationPersistenceJournalError.unavailable }
        if case .degraded(let retryAfter) = health {
            guard uptime >= retryAfter else { throw ConversationPersistenceJournalError.unavailable }
            health = .healthy
        }
    }

    private func resetMaintenance() {
        lastMaintenance = .none
        maintenanceTransactions = []
    }

    private func updateMaintenance(_ value: ConversationPersistenceJournalMaintenance, transaction: Int) {
        lastMaintenance = value
        if transaction == maintenanceTransactions.count { maintenanceTransactions.append(value) }
        else { maintenanceTransactions[transaction] = value }
    }

    /// The unwired owner must call this on activation; use methods also sweep.
    func activate() throws {
        resetMaintenance()
        let (index, inventory) = try preparedIndex()
        _ = try recoverUnreferenced(index: index, inventory: inventory)
    }

    /// Clear only supported, validated owned data. The caller must first fence
    /// capture/read tickets and queued writes; this synchronous primitive is
    /// not an authenticated product clear or a global atomic transaction.
    /// On partial success `maintenanceTransactions` describes durable changes.
    func clearSupported() throws {
        resetMaintenance()
        try requireMaintenanceAllowed()
        let index = try currentIndex()
        var inventory = try recordInventory()
        try validate(index: index, inventory: inventory)
        if try existingIndexBytes() == 0 {
            guard inventory.isEmpty, try temporaryCount() == 0 else { throw ConversationPersistenceJournalError.unavailable }
            return
        }
        var remainingIndex = index
        if !index.records.isEmpty {
            (remainingIndex, inventory) = try retire(index.records, from: index, inventory: inventory)
        }
        inventory = try recoverUnreferenced(index: remainingIndex, inventory: inventory)
        // Unsupported orphan bytes are deliberately preserved, not reported as
        // an entirely successful physical clear.
        guard inventory.isEmpty, try temporaryCount() == 0 else { throw ConversationPersistenceJournalError.unavailable }
    }

    /// Missing storage is distinct from an existing malformed/future index.
    func metadata() throws -> [ConversationPersistenceJournalMetadata] {
        resetMaintenance()
        let (index, _) = try preparedIndex()
        return try index.records.map(metadata)
    }

    /// Decodes one individually bounded record only. A scratch Core store uses
    /// the Core admission/restore contract; no route authority, epoch, cursor,
    /// ticket, or owner is manufactured here.
    func load(_ metadata: ConversationPersistenceJournalMetadata) throws -> ConversationPersistenceJournalLoadedRecord {
        resetMaintenance()
        let (index, _) = try preparedIndex()
        guard let entry = index.records.first(where: { entry in
            entry.generation == metadata.generation.value && entry.recordID == metadata.recordID && entry.encodedBytes == metadata.encodedBytes
        }) else { throw ConversationPersistenceJournalError.unavailable }
        let bytes: Data
        do { bytes = try files.readRecord(metadata.generation) }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        guard bytes.count == entry.encodedBytes else { throw ConversationPersistenceJournalError.unavailable }
        let record = try decodeOneRecord(bytes, expectedID: entry.recordID)
        return .init(record: record, metadata: try self.metadata(entry))
    }

    /// Scan only referenced records, in index order, with one decoded body at
    /// a time. A match is not authorization: the caller must recheck current
    /// owner and route authority after I/O and before exposing the result.
    func firstRecord(matching key: ConversationStore.PersistentSnapshot.Key) throws -> ConversationPersistenceJournalLoadedRecord? {
        for entry in try metadata() {
            let loaded = try load(entry)
            let candidate = loaded.record.key
            if Data(candidate.agent.utf8) == Data(key.agent.utf8),
               Data(candidate.herdrSession.utf8) == Data(key.herdrSession.utf8),
               Data(candidate.nativeSession.utf8) == Data(key.nativeSession.utf8) {
                return loaded
            }
        }
        return nil
    }

    /// Writes an immutable opaque generation and then publishes the small index.
    /// Age maintenance and supported orphan recovery run first.
    @discardableResult
    func upsert(_ record: ConversationStore.PersistentSnapshot.Record, updatedAt: Date) throws -> ConversationPersistenceJournalMetadata {
        resetMaintenance()
        try requireMaintenanceAllowed()
        let milliseconds = try checkedMilliseconds(updatedAt)
        guard !isExpired(milliseconds, at: try currentMilliseconds()) else { throw ConversationPersistenceJournalError.unavailable }
        let bytes = try encodeOneRecord(record)
        let recordID = Data(record.id.utf8)
        guard !recordID.isEmpty, recordID.count <= 1_024 else { throw ConversationPersistenceJournalError.invalidRecord }
        let generation = ConversationPersistenceGeneration.make()
        let incoming = Index.Entry(generation: generation.value, recordID: recordID, updatedMilliseconds: milliseconds, encodedBytes: bytes.count)
        // Measure the incoming proposal before age maintenance can write.
        let beforeMaintenance = try currentIndex()
        if let old = beforeMaintenance.records.first(where: { $0.recordID == recordID }) {
            guard milliseconds >= old.updatedMilliseconds else { throw ConversationPersistenceJournalError.capacity }
            guard let oldGeneration = ConversationPersistenceGeneration(serialized: old.generation) else { throw ConversationPersistenceJournalError.unavailable }
            let oldBytes: Data
            do { oldBytes = try files.readRecord(oldGeneration) }
            catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
            guard oldBytes.count == old.encodedBytes else { throw ConversationPersistenceJournalError.unavailable }
            let oldRecord = try decodeOneRecord(oldBytes, expectedID: old.recordID)
            guard Data(oldRecord.key.agent.utf8) == Data(record.key.agent.utf8),
                  Data(oldRecord.key.herdrSession.utf8) == Data(record.key.herdrSession.utf8),
                  Data(oldRecord.key.nativeSession.utf8) == Data(record.key.nativeSession.utf8) else {
                throw ConversationPersistenceJournalError.invalidRecord
            }
            do { _ = try JSONDecoder().decode(DeletionSchema.self, from: oldBytes) }
            catch { throw ConversationPersistenceJournalError.unavailable }
        }
        let preliminary = Index(records: beforeMaintenance.records.filter { $0.recordID != recordID } + [incoming])
        do { _ = try JSONEncoder().encode(preliminary) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        var (existingIndex, inventory) = try preparedIndex()
        inventory = try recoverUnreferenced(index: existingIndex, inventory: inventory)
        var selected: [Index.Entry] = []
        var attemptedRecovery = false
        let candidates = existingIndex.records.filter { $0.recordID != recordID }.sorted(by: older)
        var next: [Index.Entry] = []
        while true {
            let removed = Set(selected.map(\.generation))
            next = existingIndex.records.filter { $0.recordID != recordID && !removed.contains($0.generation) }
            next.append(incoming)
            let proposed: Data
            do { proposed = try JSONEncoder().encode(Index(records: next)) }
            catch { throw ConversationPersistenceJournalError.unavailable }
            let remainingFiles = inventory.filter { !removed.contains($0.generation.value) }
            let currentBytes = try existingIndexBytes()
            let temporaryCount = try temporaryCount()
            // Record rename preserves object count; the following index temp
            // coexists with that record until its own rename.
            let feasible = next.count <= recordLimit && remainingFiles.count + temporaryCount + 2 <= physicalLimit &&
                proposed.count <= ConversationPersistenceFiles.maximumIndexBytes &&
                (try? checkedSum(remainingFiles.map(\.bytes) + [currentBytes, bytes.count, proposed.count, ConversationPersistenceFiles.maximumIndexBytes])) != nil
            if feasible { break }
            if !attemptedRecovery {
                attemptedRecovery = true
                inventory = try recoverUnreferenced(index: existingIndex, inventory: inventory)
                continue
            }
            guard selected.count < candidates.count else { throw ConversationPersistenceJournalError.capacity }
            let victim = candidates[selected.count]
            guard !older(incoming, victim) else { throw ConversationPersistenceJournalError.capacity }
            selected.append(victim)
        }
        if !selected.isEmpty {
            (existingIndex, inventory) = try retire(selected, from: existingIndex, inventory: inventory)
        }
        let result = try metadata(next.last!)
        let nextIndex = Index(records: next)
        let nextIndexBytes: Data
        do { nextIndexBytes = try JSONEncoder().encode(nextIndex) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        guard nextIndexBytes.count <= ConversationPersistenceFiles.maximumIndexBytes else {
            throw ConversationPersistenceJournalError.capacity
        }

        // Actual verified inventory, current index bytes, the new immutable
        // record, the pending index temp, and one maximum index headroom are
        // all reserved before the first write. This intentionally underfills.
        let currentIndexBytes = try existingIndexBytes()
        let used = try checkedSum(inventory.map(\.bytes) + [currentIndexBytes, bytes.count, nextIndexBytes.count,
                                                           ConversationPersistenceFiles.maximumIndexBytes])
        guard used <= diskLimit else { throw ConversationPersistenceJournalError.capacity }
        do {
            try publishWithOneRetry(pending: nil, recordBytes: bytes.count, indexBytes: nextIndexBytes.count) {
                _ = try files.writeRecord(bytes, generation: generation)
            }
        } catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
            noteIOFailure(ConversationPersistenceFilesError.committedButDurabilityUncertain)
            throw ConversationPersistenceJournalError.recordCommittedButDurabilityUncertain
        } catch let error as ConversationPersistenceJournalError { throw error }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        do {
            try publishWithOneRetry(pending: generation, recordBytes: 0, indexBytes: nextIndexBytes.count) {
                try files.writeIndex(nextIndexBytes)
            }
        } catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
            noteIOFailure(ConversationPersistenceFilesError.committedButDurabilityUncertain)
            throw ConversationPersistenceJournalError.indexCommittedButDurabilityUncertain
        } catch let error as ConversationPersistenceJournalError { throw error }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        return result
    }

    /// Only failure before exclusive temporary creation is retryable. A fresh
    /// validated index/inventory and budget precede the one additional attempt.
    /// The already-published pending record is never classified as an orphan.
    private func publishWithOneRetry(pending: ConversationPersistenceGeneration?, recordBytes: Int,
                                     indexBytes: Int, publish: () throws -> Void) throws {
        do { try publish(); return }
        catch ConversationPersistenceFilesError.retryableBeforeTemporaryCreation(_) { }
        let index = try currentIndex()
        var inventory = try recordInventory()
        try validate(index: index, inventory: inventory)
        if let pending, !inventory.contains(where: { $0.generation == pending }) {
            throw ConversationPersistenceJournalError.unavailable
        }
        inventory = try recoverUnreferenced(index: index, inventory: inventory, protected: pending)
        let currentBytes = try existingIndexBytes()
        _ = try checkedSum(inventory.map(\.bytes) + [currentBytes, recordBytes, indexBytes, ConversationPersistenceFiles.maximumIndexBytes])
        let extra = pending == nil ? 2 : 1
        guard inventory.count + (try temporaryCount()) + extra <= physicalLimit else {
            throw ConversationPersistenceJournalError.capacity
        }
        do { try publish() }
        catch ConversationPersistenceFilesError.retryableBeforeTemporaryCreation(_) {
            let time = monotonicNow()
            if time.isFinite && time >= 0 && time <= TimeInterval.greatestFiniteMagnitude - 5 {
                health = .degraded(retryAfter: time + 5)
            } else {
                health = .degraded(retryAfter: TimeInterval.greatestFiniteMagnitude)
            }
            throw ConversationPersistenceJournalError.unavailable
        }
    }

    /// All candidate bodies are validated before the single index transaction.
    /// Once committed, failures expose the committed maintenance state rather
    /// than implying that the old references remain logically present.
    private func preparedIndex() throws -> (Index, [ConversationPersistenceRecordFile]) {
        let present = try currentMilliseconds()
        let index = try currentIndex()
        // Scan before ignoring temporary names in the record inventory. A
        // nonempty temporary is protected and blocks rather than being free.
        do { _ = try files.emptyTemporaryTickets() }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        var inventory = try recordInventory()
        try validate(index: index, inventory: inventory)
        let expired = index.records.filter { isExpired($0.updatedMilliseconds, at: present) }
        guard !expired.isEmpty else { return (index, inventory) }
        try requireMaintenanceAllowed()
        do { return try retire(expired, from: index, inventory: inventory) }
        catch ConversationPersistenceJournalError.capacity {
            inventory = try recoverUnreferenced(index: index, inventory: inventory)
            return try retire(expired, from: index, inventory: inventory)
        }
    }

    private func older(_ lhs: Index.Entry, _ rhs: Index.Entry) -> Bool {
        if lhs.updatedMilliseconds != rhs.updatedMilliseconds { return lhs.updatedMilliseconds < rhs.updatedMilliseconds }
        if lhs.recordID != rhs.recordID { return lhs.recordID.lexicographicallyPrecedes(rhs.recordID) }
        return lhs.generation.utf8.lexicographicallyPrecedes(rhs.generation.utf8)
    }

    private func retire(_ victims: [Index.Entry], from index: Index,
                        inventory initialInventory: [ConversationPersistenceRecordFile]) throws -> (Index, [ConversationPersistenceRecordFile]) {
        var inventory = initialInventory
        let transaction = maintenanceTransactions.count
        var tickets: [ConversationPersistenceRecordDeletionTicket] = []
        for entry in victims {
            guard let generation = ConversationPersistenceGeneration(serialized: entry.generation) else {
                throw ConversationPersistenceJournalError.unavailable
            }
            let checked: (Data, ConversationPersistenceRecordDeletionTicket)
            do { checked = try files.readRecordForDeletion(generation) }
            catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
            let (data, ticket) = checked
            guard data.count == entry.encodedBytes else { throw ConversationPersistenceJournalError.unavailable }
            _ = try decodeOneRecord(data, expectedID: entry.recordID)
            do { _ = try JSONDecoder().decode(DeletionSchema.self, from: data) }
            catch { throw ConversationPersistenceJournalError.unavailable }
            tickets.append(ticket)
        }
        let victimGenerations = Set(victims.map(\.generation))
        let next = Index(records: index.records.filter { !victimGenerations.contains($0.generation) })
        let nextBytes: Data
        do { nextBytes = try JSONEncoder().encode(next) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        guard nextBytes.count <= ConversationPersistenceFiles.maximumIndexBytes else { throw ConversationPersistenceJournalError.capacity }
        let currentBytes = try existingIndexBytes()
        guard inventory.count + (try temporaryCount()) + 1 <= physicalLimit else {
            throw ConversationPersistenceJournalError.capacity
        }
        _ = try checkedSum(inventory.map(\.bytes) + [currentBytes, nextBytes.count, ConversationPersistenceFiles.maximumIndexBytes])
        do { try files.writeIndex(nextBytes) }
        catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
            noteIOFailure(ConversationPersistenceFilesError.committedButDurabilityUncertain)
            updateMaintenance(.indexDurabilityUncertain, transaction: transaction)
            throw ConversationPersistenceJournalError.indexCommittedButDurabilityUncertain
        } catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }

        var completed = 0
        updateMaintenance(.committed(removed: tickets.count, cleanupCompleted: completed, cleanupDurabilityUncertain: false), transaction: transaction)
        for ticket in tickets {
            do { try files.removeValidatedRecord(ticket) }
            catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
                noteIOFailure(ConversationPersistenceFilesError.committedButDurabilityUncertain)
                updateMaintenance(.committed(removed: tickets.count, cleanupCompleted: completed, cleanupDurabilityUncertain: true), transaction: transaction)
                throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed
            } catch {
                noteIOFailure(error)
                throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed
            }
            completed += 1
            updateMaintenance(.committed(removed: tickets.count, cleanupCompleted: completed, cleanupDurabilityUncertain: false), transaction: transaction)
        }
        // Fresh inventory ensures retained orphan bytes remain in write budgets.
        do {
            inventory = try recordInventory()
            try validate(index: next, inventory: inventory)
        } catch { throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed }
        return (next, inventory)
    }

    /// Recovery is conservative: only an existing supported index authorizes
    /// orphan decisions. Unsupported bodies are preserved and remain budgeted.
    private func recoverUnreferenced(index: Index, inventory: [ConversationPersistenceRecordFile],
                                     protected: ConversationPersistenceGeneration? = nil) throws -> [ConversationPersistenceRecordFile] {
        guard try existingIndexBytes() > 0 else { return inventory }
        let temporary: [ConversationPersistenceEmptyTemporaryTicket]
        do { temporary = try files.emptyTemporaryTickets() }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        let referenced = Set(index.records.map(\.generation))
        var tickets: [ConversationPersistenceRecordDeletionTicket] = []
        for file in inventory where !referenced.contains(file.generation.value) && file.generation != protected {
            let checked: (Data, ConversationPersistenceRecordDeletionTicket)
            do { checked = try files.readRecordForDeletion(file.generation) }
            catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
            do {
                var raw = try RawJSON(checked.0, maximumBytes: ConversationPersistenceFiles.maximumRecordBytes)
                try raw.check()
                let envelope = try JSONDecoder().decode(SingleRecordEnvelope.self, from: checked.0)
                _ = try decodeOneRecord(checked.0, expectedID: Data(envelope.record.id.utf8))
                _ = try JSONDecoder().decode(DeletionSchema.self, from: checked.0)
                tickets.append(checked.1)
            } catch {
                // Corrupt, future and unknown data is retained and counted.
            }
        }
        guard !tickets.isEmpty || !temporary.isEmpty else { return inventory }
        try requireMaintenanceAllowed()
        do { try files.synchronizeIndexDirectory() }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        let transaction = maintenanceTransactions.count
        var completed = 0
        updateMaintenance(.recovered(completed: completed, cleanupDurabilityUncertain: false), transaction: transaction)
        for ticket in tickets {
            do { try files.removeValidatedRecord(ticket) }
            catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
                noteIOFailure(ConversationPersistenceFilesError.committedButDurabilityUncertain)
                updateMaintenance(.recovered(completed: completed, cleanupDurabilityUncertain: true), transaction: transaction)
                throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed
            } catch { noteIOFailure(error); throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed }
            completed += 1
            updateMaintenance(.recovered(completed: completed, cleanupDurabilityUncertain: false), transaction: transaction)
        }
        for ticket in temporary {
            do { try files.removeEmptyTemporary(ticket) }
            catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
                noteIOFailure(ConversationPersistenceFilesError.committedButDurabilityUncertain)
                updateMaintenance(.recovered(completed: completed, cleanupDurabilityUncertain: true), transaction: transaction)
                throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed
            } catch { noteIOFailure(error); throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed }
            completed += 1
            updateMaintenance(.recovered(completed: completed, cleanupDurabilityUncertain: false), transaction: transaction)
        }
        return try recordInventory()
    }

    private func temporaryCount() throws -> Int {
        do { return try files.emptyTemporaryTickets().count }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
    }

    private func recordInventory() throws -> [ConversationPersistenceRecordFile] {
        do { return try files.inventoryRecords() }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
    }

    private func currentIndex() throws -> Index {
        let data: Data?
        do { try files.validateConversationsNamespace(); data = try files.readIndex() }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
        guard let data else { return Index(records: []) }
        guard data.count <= ConversationPersistenceFiles.maximumIndexBytes else { throw ConversationPersistenceJournalError.unavailable }
        do {
            var raw = try RawJSON(data, maximumBytes: ConversationPersistenceFiles.maximumIndexBytes)
            try raw.check()
            return try JSONDecoder().decode(Index.self, from: data)
        }
        catch { throw ConversationPersistenceJournalError.unavailable }
    }

    private func existingIndexBytes() throws -> Int {
        do { return try files.readIndex()?.count ?? 0 }
        catch { noteIOFailure(error); throw ConversationPersistenceJournalError.unavailable }
    }

    private func validate(index: Index, inventory: [ConversationPersistenceRecordFile]) throws {
        var seenIDs = Set<Data>()
        var seenGenerations = Set<ConversationPersistenceGeneration>()
        var actual: [ConversationPersistenceGeneration: Int] = [:]
        for file in inventory {
            guard actual.updateValue(file.bytes, forKey: file.generation) == nil else { throw ConversationPersistenceJournalError.unavailable }
        }
        for entry in index.records {
            guard let generation = ConversationPersistenceGeneration(serialized: entry.generation),
                  entry.recordID.count > 0, entry.recordID.count <= 1_024,
                  entry.encodedBytes >= 0, entry.encodedBytes <= ConversationPersistenceFiles.maximumRecordBytes,
                  actual[generation] == entry.encodedBytes,
                  seenIDs.insert(entry.recordID).inserted,
                  seenGenerations.insert(generation).inserted else { throw ConversationPersistenceJournalError.unavailable }
            _ = try metadata(entry)
        }
    }

    private func metadata(_ entry: Index.Entry) throws -> ConversationPersistenceJournalMetadata {
        guard let generation = ConversationPersistenceGeneration(serialized: entry.generation),
              entry.encodedBytes >= 0, entry.encodedBytes <= ConversationPersistenceFiles.maximumRecordBytes else {
            throw ConversationPersistenceJournalError.unavailable
        }
        let date = Date(timeIntervalSince1970: TimeInterval(entry.updatedMilliseconds) / 1_000)
        try validateMilliseconds(entry.updatedMilliseconds)
        return .init(generation: generation, recordID: entry.recordID, updatedAt: date, encodedBytes: entry.encodedBytes)
    }

    // Round nonnegative caller timestamps to the nearest millisecond; persisted integers
    // are checked directly, avoiding lossy integer -> Date -> integer validation.
    private func checkedMilliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < 9_223_372_036_854_775_808.0 else {
            throw ConversationPersistenceJournalError.unavailable
        }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded < 9_223_372_036_854_775_808.0 else { throw ConversationPersistenceJournalError.unavailable }
        let milliseconds = Int64(rounded)
        try validateMilliseconds(milliseconds)
        return milliseconds
    }

    private func currentMilliseconds() throws -> Int64 {
        let present = now().timeIntervalSince1970 * 1_000
        guard present.isFinite, present >= 0, present < 9_223_372_036_854_775_808.0 else {
            throw ConversationPersistenceJournalError.unavailable
        }
        return Int64(present.rounded(.down))
    }

    private func validateMilliseconds(_ milliseconds: Int64) throws {
        let current = try currentMilliseconds()
        let (limit, overflow) = current.addingReportingOverflow(Self.maximumFutureMilliseconds)
        guard milliseconds >= 0, milliseconds <= (overflow ? Int64.max : limit) else {
            throw ConversationPersistenceJournalError.unavailable
        }
    }

    private func isExpired(_ milliseconds: Int64, at current: Int64) -> Bool {
        current >= milliseconds && current - milliseconds >= Self.retentionMilliseconds
    }

    private func admitted(_ record: ConversationStore.PersistentSnapshot.Record) -> Bool {
        var scratch = ConversationStore()
        guard let report = try? scratch.restore(.init(records: [record])) else { return false }
        return report.rejectedRecordCount == 0 && report.evictedPersistentIDs.isEmpty &&
            report.restoredIDs.count == 1 && report.restoredIDs[Data(record.id.utf8)] != nil
    }

    private func encodeOneRecord(_ record: ConversationStore.PersistentSnapshot.Record) throws -> Data {
        guard admitted(record) else { throw ConversationPersistenceJournalError.invalidRecord }
        do { return try ConversationStore.PersistentSnapshot(records: [record]).encoded(maximumBytes: ConversationPersistenceFiles.maximumRecordBytes) }
        catch { throw ConversationPersistenceJournalError.invalidRecord }
    }

    private func decodeOneRecord(_ bytes: Data, expectedID: Data) throws -> ConversationStore.PersistentSnapshot.Record {
        guard bytes.count <= ConversationPersistenceFiles.maximumRecordBytes else { throw ConversationPersistenceJournalError.unavailable }
        let envelope: SingleRecordEnvelope
        do {
            var raw = try RawJSON(bytes, maximumBytes: ConversationPersistenceFiles.maximumRecordBytes)
            try raw.check()
            envelope = try JSONDecoder().decode(SingleRecordEnvelope.self, from: bytes)
        }
        catch { throw ConversationPersistenceJournalError.unavailable }
        let record = envelope.record
        guard Data(record.id.utf8) == expectedID, admitted(record) else { throw ConversationPersistenceJournalError.unavailable }
        return record
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0, value <= diskLimit, total <= diskLimit - value else { throw ConversationPersistenceJournalError.capacity }
            total += value
        }
        return total
    }
}
