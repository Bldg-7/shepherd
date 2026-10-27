import Foundation
import AgentProxyCore

/// A bounded, unwired journal for already-admitted Core records. The index is
/// metadata only and is never route authorization; its caller must gate a
/// loaded record again before making it visible.
enum ConversationPersistenceJournalError: Error, Equatable {
    case unavailable
    case capacity
    case invalidRecord
    /// Index rename crossed the commit point, but its durability is uncertain.
    case indexCommittedButDurabilityUncertain
    /// A retention index was durable, but one or more physical removals failed.
    case retentionCommittedCleanupFailed
}

enum ConversationPersistenceJournalMaintenance: Equatable {
    case none
    case indexDurabilityUncertain
    case committed(removed: Int, cleanupCompleted: Int, cleanupDurabilityUncertain: Bool)
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

    init(files: ConversationPersistenceFiles, now: @escaping () -> Date = Date.init) {
        self.files = files
        self.now = now
    }

    /// The unwired owner must call this on activation; use methods also sweep.
    func activate() throws {
        lastMaintenance = .none
        _ = try preparedIndex()
    }

    /// Missing storage is distinct from an existing malformed/future index.
    func metadata() throws -> [ConversationPersistenceJournalMetadata] {
        lastMaintenance = .none
        let (index, _) = try preparedIndex()
        return try index.records.map(metadata)
    }

    /// Decodes one individually bounded record only. A scratch Core store uses
    /// the Core admission/restore contract; no route authority, epoch, cursor,
    /// ticket, or owner is manufactured here.
    func load(_ metadata: ConversationPersistenceJournalMetadata) throws -> ConversationPersistenceJournalLoadedRecord {
        lastMaintenance = .none
        let (index, _) = try preparedIndex()
        guard let entry = index.records.first(where: { entry in
            entry.generation == metadata.generation.value && entry.recordID == metadata.recordID && entry.encodedBytes == metadata.encodedBytes
        }) else { throw ConversationPersistenceJournalError.unavailable }
        let bytes: Data
        do { bytes = try files.readRecord(metadata.generation) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        guard bytes.count == entry.encodedBytes else { throw ConversationPersistenceJournalError.unavailable }
        let record = try decodeOneRecord(bytes, expectedID: entry.recordID)
        return .init(record: record, metadata: try self.metadata(entry))
    }

    /// Writes an immutable opaque generation and then publishes the small index.
    /// Age maintenance runs first; capacity/orphan reclamation still refuses.
    @discardableResult
    func upsert(_ record: ConversationStore.PersistentSnapshot.Record, updatedAt: Date) throws -> ConversationPersistenceJournalMetadata {
        lastMaintenance = .none
        let milliseconds = try checkedMilliseconds(updatedAt)
        guard !isExpired(milliseconds, at: try currentMilliseconds()) else { throw ConversationPersistenceJournalError.unavailable }
        let bytes = try encodeOneRecord(record)
        let (existingIndex, inventory) = try preparedIndex()

        let recordID = Data(record.id.utf8)
        guard !recordID.isEmpty, recordID.count <= 1_024 else { throw ConversationPersistenceJournalError.invalidRecord }
        if let old = existingIndex.records.first(where: { $0.recordID == recordID }) {
            guard let generation = ConversationPersistenceGeneration(serialized: old.generation) else { throw ConversationPersistenceJournalError.unavailable }
            let oldBytes: Data
            do { oldBytes = try files.readRecord(generation) }
            catch { throw ConversationPersistenceJournalError.unavailable }
            guard oldBytes.count == old.encodedBytes else { throw ConversationPersistenceJournalError.unavailable }
            _ = try decodeOneRecord(oldBytes, expectedID: old.recordID)
        }
        var next = existingIndex.records.filter { $0.recordID != recordID }
        guard next.count < Self.maximumRecords, inventory.count < Self.maximumRecords else {
            throw ConversationPersistenceJournalError.capacity
        }
        let generation = ConversationPersistenceGeneration.make()
        next.append(.init(generation: generation.value, recordID: recordID, updatedMilliseconds: milliseconds, encodedBytes: bytes.count))
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
        guard used <= Self.maximumDiskBytes else { throw ConversationPersistenceJournalError.capacity }
        // A record failure, including uncertain record durability, cannot mean
        // the index commit point was crossed. An orphan may remain.
        do { _ = try files.writeRecord(bytes, generation: generation) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        do { try files.writeIndex(nextIndexBytes) }
        catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
            throw ConversationPersistenceJournalError.indexCommittedButDurabilityUncertain
        } catch { throw ConversationPersistenceJournalError.unavailable }
        return result
    }

    /// All candidate bodies are validated before the single index transaction.
    /// Once committed, failures expose the committed maintenance state rather
    /// than implying that the old references remain logically present.
    private func preparedIndex() throws -> (Index, [ConversationPersistenceRecordFile]) {
        let present = try currentMilliseconds()
        let index = try currentIndex()
        var inventory = try recordInventory()
        try validate(index: index, inventory: inventory)
        let expired = index.records.filter { isExpired($0.updatedMilliseconds, at: present) }
        guard !expired.isEmpty else { return (index, inventory) }

        var tickets: [ConversationPersistenceRecordDeletionTicket] = []
        for entry in expired {
            guard let generation = ConversationPersistenceGeneration(serialized: entry.generation) else {
                throw ConversationPersistenceJournalError.unavailable
            }
            let checked: (Data, ConversationPersistenceRecordDeletionTicket)
            do { checked = try files.readRecordForDeletion(generation) }
            catch { throw ConversationPersistenceJournalError.unavailable }
            let (data, ticket) = checked
            guard data.count == entry.encodedBytes else { throw ConversationPersistenceJournalError.unavailable }
            _ = try decodeOneRecord(data, expectedID: entry.recordID)
            do { _ = try JSONDecoder().decode(DeletionSchema.self, from: data) }
            catch { throw ConversationPersistenceJournalError.unavailable }
            tickets.append(ticket)
        }
        let expiredGenerations = Set(expired.map(\.generation))
        let next = Index(records: index.records.filter { !expiredGenerations.contains($0.generation) })
        let nextBytes: Data
        do { nextBytes = try JSONEncoder().encode(next) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        guard nextBytes.count <= ConversationPersistenceFiles.maximumIndexBytes else { throw ConversationPersistenceJournalError.capacity }
        let currentBytes = try existingIndexBytes()
        _ = try checkedSum(inventory.map(\.bytes) + [currentBytes, nextBytes.count, ConversationPersistenceFiles.maximumIndexBytes])
        do { try files.writeIndex(nextBytes) }
        catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
            lastMaintenance = .indexDurabilityUncertain
            throw ConversationPersistenceJournalError.indexCommittedButDurabilityUncertain
        } catch { throw ConversationPersistenceJournalError.unavailable }

        var completed = 0
        lastMaintenance = .committed(removed: tickets.count, cleanupCompleted: completed, cleanupDurabilityUncertain: false)
        for ticket in tickets {
            do { try files.removeValidatedRecord(ticket) }
            catch ConversationPersistenceFilesError.committedButDurabilityUncertain {
                lastMaintenance = .committed(removed: tickets.count, cleanupCompleted: completed, cleanupDurabilityUncertain: true)
                throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed
            } catch {
                throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed
            }
            completed += 1
            lastMaintenance = .committed(removed: tickets.count, cleanupCompleted: completed, cleanupDurabilityUncertain: false)
        }
        // Fresh inventory ensures retained orphan bytes remain in write budgets.
        do {
            inventory = try recordInventory()
            try validate(index: next, inventory: inventory)
        } catch { throw ConversationPersistenceJournalError.retentionCommittedCleanupFailed }
        return (next, inventory)
    }

    private func recordInventory() throws -> [ConversationPersistenceRecordFile] {
        do { return try files.inventoryRecords() }
        catch { throw ConversationPersistenceJournalError.unavailable }
    }

    private func currentIndex() throws -> Index {
        let data: Data?
        do { try files.validateConversationsNamespace(); data = try files.readIndex() }
        catch { throw ConversationPersistenceJournalError.unavailable }
        guard let data else { return Index(records: []) }
        guard data.count <= ConversationPersistenceFiles.maximumIndexBytes else { throw ConversationPersistenceJournalError.unavailable }
        do { return try JSONDecoder().decode(Index.self, from: data) }
        catch { throw ConversationPersistenceJournalError.unavailable }
    }

    private func existingIndexBytes() throws -> Int {
        do { return try files.readIndex()?.count ?? 0 }
        catch { throw ConversationPersistenceJournalError.unavailable }
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
        do { envelope = try JSONDecoder().decode(SingleRecordEnvelope.self, from: bytes) }
        catch { throw ConversationPersistenceJournalError.unavailable }
        let record = envelope.record
        guard Data(record.id.utf8) == expectedID, admitted(record) else { throw ConversationPersistenceJournalError.unavailable }
        return record
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0, total <= Self.maximumDiskBytes - value else { throw ConversationPersistenceJournalError.capacity }
            total += value
        }
        return total
    }
}
