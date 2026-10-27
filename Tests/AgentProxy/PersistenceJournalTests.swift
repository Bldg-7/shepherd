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
            let clock = Date(timeIntervalSince1970: 1_700_000_000.1234)
            let record = ConversationStore.PersistentSnapshot.Record(
                id: "record-id", key: .init(agent: "claude", herdrSession: "session", nativeSession: "native"),
                context: .init(routeID: "route", paneID: "pane", terminalID: "terminal"), updatedOrder: 1,
                items: [.init(id: "item", message: .init(role: "user", blocks: [.init(kind: "text", text: "synthetic", callID: nil, toolName: nil)], truncated: false), origin: .init(kind: "observed"), status: "complete")],
                truncated: false, status: "complete", subagents: .init(observed: 0, withFinalResult: 0, limited: false, linkAvailable: false, ancestryIncomplete: false))
            let indexPath = root + "/Conversations/index-v1.json"
            var saved: ConversationPersistenceJournalMetadata!
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: root)
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                saved = try journal.upsert(record, updatedAt: clock)
                guard abs(saved.updatedAt.timeIntervalSince1970 - 1_700_000_000.123) < 0.000001 else { throw Failure() }
                guard try journal.metadata() == [saved], try journal.load(saved).record == record else { throw Failure() }
                let originalIndex = try files.readIndex()!
                let originalRecord = try files.readRecord(saved.generation)
                let recordPath = root + "/Conversations/records/" + saved.generation.value + ".json"
                func unchanged() throws {
                    guard try files.readIndex() == originalIndex, try files.readRecord(saved.generation) == originalRecord else { throw Failure() }
                }
                func reject(_ operation: () throws -> Void) throws {
                    do { try operation(); throw Failure() } catch is Failure { throw Failure() } catch {}
                }
                var rootObject = try JSONSerialization.jsonObject(with: originalIndex) as! [String: Any]
                rootObject["futureMetadata"] = ["keep": true]
                let unknownRoot = try JSONSerialization.data(withJSONObject: rootObject)
                try files.writeIndex(unknownRoot)
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
                guard try files.readIndex() == unknownRoot else { throw Failure() }
                rootObject.removeValue(forKey: "futureMetadata")
                var entries = rootObject["records"] as! [[String: Any]]
                entries[0]["futureField"] = "preserve"
                rootObject["records"] = entries
                let unknownEntry = try JSONSerialization.data(withJSONObject: rootObject)
                try files.writeIndex(unknownEntry)
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
                guard try files.readIndex() == unknownEntry else { throw Failure() }
                entries[0].removeValue(forKey: "futureField")
                entries[0]["updatedMilliseconds"] = Int64.max
                rootObject["records"] = entries
                try files.writeIndex(JSONSerialization.data(withJSONObject: rootObject))
                try reject { _ = try journal.metadata() }
                try files.writeIndex(originalIndex)
                let invalid = ConversationStore.PersistentSnapshot.Record(id: record.id, key: record.key, context: record.context,
                    updatedOrder: 0, items: record.items, truncated: record.truncated, status: record.status, subagents: record.subagents)
                do { _ = try journal.upsert(invalid, updatedAt: clock); throw Failure() }
                catch ConversationPersistenceJournalError.invalidRecord {}
                try unchanged()
                let encodedRecord = try JSONEncoder().encode(record)
                let object = try JSONSerialization.jsonObject(with: encodedRecord) as! [String: Any]
                var variants: [[String: Any]] = []
                var badID = object; badID["id"] = ""; variants.append(badID)
                var badContext = object; badContext["context"] = ["routeID": "", "paneID": "pane", "terminalID": "terminal"]; variants.append(badContext)
                var duplicate = object; let items = object["items"] as! [[String: Any]]; duplicate["items"] = [items[0], items[0]]; variants.append(duplicate)
                var badBlock = object; var changedItems = items; var message = changedItems[0]["message"] as! [String: Any]
                message["blocks"] = [["kind": "unknown", "text": "synthetic"]]; changedItems[0]["message"] = message; badBlock["items"] = changedItems; variants.append(badBlock)
                var badStats = object; badStats["subagents"] = ["observed": -1, "withFinalResult": 0, "limited": false, "linkAvailable": false, "ancestryIncomplete": false]; variants.append(badStats)
                for variant in variants {
                    let candidate = try JSONDecoder().decode(ConversationStore.PersistentSnapshot.Record.self, from: JSONSerialization.data(withJSONObject: variant))
                    do { _ = try journal.upsert(candidate, updatedAt: clock); throw Failure() }
                    catch ConversationPersistenceJournalError.invalidRecord {}
                    try unchanged()
                }
                for time in [Double.nan, Double.infinity, -Double.infinity, -1.0, 9_223_372_036_854_775.808, Double.greatestFiniteMagnitude] {
                    try reject { _ = try journal.upsert(record, updatedAt: Date(timeIntervalSince1970: time)) }
                    let badClock = ConversationPersistenceJournal(files: files, now: { Date(timeIntervalSince1970: time) })
                    try reject { _ = try badClock.metadata() }
                    try unchanged()
                }
                for name in [".tmp-test", "index-v2.json"] {
                    let path = root + "/Conversations/" + name
                    guard FileManager.default.createFile(atPath: path, contents: Data("future".utf8), attributes: [.posixPermissions: 0o600]) else { throw Failure() }
                    try reject { _ = try journal.upsert(record, updatedAt: clock) }
                    try unchanged()
                    try FileManager.default.removeItem(atPath: path)
                }
                // Zero and 256 records are rejected by the envelope count
                // before decoding any Record models; this is not an RSS test.
                let recordObject = (try JSONSerialization.jsonObject(with: originalRecord) as! [String: Any])["records"] as! [Any]
                for count in [0, 256] {
                    let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": Array(repeating: recordObject[0], count: count)])
                    var modified = try JSONSerialization.jsonObject(with: originalIndex) as! [String: Any]
                    var values = modified["records"] as! [[String: Any]]
                    values[0]["encodedBytes"] = payload.count
                    modified["records"] = values
                    try payload.write(to: URL(fileURLWithPath: recordPath))
                    try files.writeIndex(JSONSerialization.data(withJSONObject: modified))
                    let current = try journal.metadata()[0]
                    try reject { _ = try journal.load(current) }
                    try reject { _ = try journal.upsert(record, updatedAt: clock) }
                }
                try originalRecord.write(to: URL(fileURLWithPath: recordPath))
                try files.writeIndex(originalIndex)
                try unchanged()
                // Actual file sizes, rather than declared index sizes, control admission.
                var mismatch = try JSONSerialization.jsonObject(with: originalIndex) as! [String: Any]
                var mismatchEntries = mismatch["records"] as! [[String: Any]]
                mismatchEntries[0]["encodedBytes"] = originalRecord.count + 1
                mismatch["records"] = mismatchEntries
                let mismatchIndex = try JSONSerialization.data(withJSONObject: mismatch)
                try files.writeIndex(mismatchIndex)
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
                guard try files.readIndex() == mismatchIndex else { throw Failure() }
                try files.writeIndex(originalIndex)
                // Replace the record with a same-length future schema. Failed
                // load and same-ID upsert must preserve both reference and bytes.
                let future = Data(String(decoding: originalRecord, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
                guard future.count == originalRecord.count, future != originalRecord else { throw Failure() }
                try future.write(to: URL(fileURLWithPath: recordPath))
                try reject { _ = try journal.load(saved) }
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
                guard try files.readIndex() == originalIndex, try files.readRecord(saved.generation) == future else { throw Failure() }
            }
            // The lease and journal above are out of scope; reacquire them.
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: root)
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                let beforeIndex = try Data(contentsOf: URL(fileURLWithPath: indexPath))
                let beforeRecord = try files.readRecord(saved.generation)
                do { _ = try journal.upsert(record, updatedAt: clock); throw Failure() }
                catch ConversationPersistenceJournalError.unavailable {}
                guard try files.readIndex() == beforeIndex, try files.readRecord(saved.generation) == beforeRecord else { throw Failure() }
            }
            let futureRoot = String(cString: resolved) + "/future-root"
            guard mkdir(futureRoot, 0o700) == 0 else { throw Failure() }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: futureRoot)
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                let path = futureRoot + "/Conversations/index-v2.json"
                guard FileManager.default.createFile(atPath: path, contents: Data("future".utf8), attributes: [.posixPermissions: 0o600]) else { throw Failure() }
                do { _ = try journal.upsert(record, updatedAt: clock); throw Failure() }
                catch ConversationPersistenceJournalError.unavailable {}
                guard try files.readIndex() == nil, try Data(contentsOf: URL(fileURLWithPath: path)) == Data("future".utf8) else { throw Failure() }
            }
            try safetyFixtures(base: String(cString: resolved), record: record, clock: clock)
            print("PASS: bounded persistence journal")
        } catch {
            print("FAIL: journal \(error)")
            exit(1)
        }
    }
    private static func safetyFixtures(base: String, record: ConversationStore.PersistentSnapshot.Record, clock: Date) throws {
        func root(_ name: String) throws -> String {
            let path = base + "/" + name
            guard mkdir(path, 0o700) == 0 else { throw Failure() }
            return path
        }
        func reject(_ operation: () throws -> Void, expected: ConversationPersistenceJournalError = .unavailable) throws {
            do { try operation(); throw Failure() }
            catch let error as ConversationPersistenceJournalError { guard error == expected else { throw Failure() } }
        }
        func names(_ path: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        }
        func copyRecord(_ id: String, items: [ConversationStore.PersistentSnapshot.Item]? = nil) -> ConversationStore.PersistentSnapshot.Record {
            .init(id: id, key: record.key, context: record.context, updatedOrder: record.updatedOrder,
                  items: items ?? record.items, truncated: record.truncated, status: record.status, subagents: record.subagents)
        }
        // No opposing FIFO endpoints exist: the runner's original deadline
        // bounds any regression to a blocking open.
        for indexFIFO in [true, false] {
            let path = try root(indexFIFO ? "fifo-index" : "fifo-record")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let object = indexFIFO ? path + "/Conversations/index-v1.json" :
                path + "/Conversations/records/00000000-0000-0000-0000-000000000001.json"
            guard mkfifo(object, 0o600) == 0 else { throw Failure() }
            try reject { _ = try journal.metadata() }
            try reject { _ = try journal.upsert(record, updatedAt: clock) }
            var info = stat()
            guard lstat(object, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { throw Failure() }
        }
        // Index-specific faults occur only after successful record publication.
        for post in [false, true] {
            let path = try root(post ? "index-post" : "index-pre")
            var oldIndex = Data()
            var oldMetadata: ConversationPersistenceJournalMetadata!
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                oldMetadata = try journal.upsert(record, updatedAt: clock)
                oldIndex = try files.readIndex()!
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: .init(indexFault: post ? .afterRenameBeforeDirectorySync : .beforeRename))
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                try reject({ _ = try journal.upsert(record, updatedAt: clock) }, expected: post ? .indexCommittedButDurabilityUncertain : .unavailable)
                let index = try files.readIndex()!
                let entries = try journal.metadata()
                guard entries.count == 1, try journal.load(entries[0]).record == record else { throw Failure() }
                if post { guard index != oldIndex, entries[0].generation != oldMetadata.generation else { throw Failure() } }
                else { guard index == oldIndex, entries[0] == oldMetadata else { throw Failure() } }
                guard try files.readRecord(oldMetadata.generation).count == oldMetadata.encodedBytes else { throw Failure() }
            }
        }
        // Record rename uncertainty does not imply the index commit occurred.
        do {
            let path = try root("record-uncertain")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: .init(fault: .afterRenameBeforeDirectorySync))
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            try reject { _ = try journal.upsert(record, updatedAt: clock) }
            guard try files.readIndex() == nil, try files.inventoryRecords().count == 1 else { throw Failure() }
        }
        // Count ceiling and byte ceiling use real verified stat sizes. Sparse
        // files require no physical 256 MiB allocation.
        for countLimit in [true, false] {
            let path = try root(countLimit ? "count-cap" : "byte-cap")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let recordsPath = path + "/Conversations/records"
            for n in 0..<(countLimit ? 256 : 8) {
                let name = String(format: "00000000-0000-0000-0000-%012x.json", n + 1)
                let fd = open(recordsPath + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw Failure() }
                guard fchmod(fd, 0o600) == 0, ftruncate(fd, countLimit ? 0 : off_t(32 << 20)) == 0 else { close(fd); throw Failure() }
                close(fd)
            }
            let before = try names(recordsPath)
            try reject({ _ = try journal.upsert(record, updatedAt: clock) }, expected: .capacity)
            guard try files.readIndex() == nil, try names(recordsPath) == before else { throw Failure() }
        }
        // Isolate reserved index headroom: a separate empty-store probe
        // measures the actual record and index encoding for this input. UUID
        // generations have fixed-length canonical spellings in both stores.
        do {
            let probePath = try root("headroom-probe")
            let probeFiles = try ConversationPersistenceFiles(verifiedStateRootPath: probePath)
            let probe = ConversationPersistenceJournal(files: probeFiles, now: { clock })
            let saved = try probe.upsert(record, updatedAt: clock)
            let proposedRecordBytes = try probeFiles.readRecord(saved.generation).count
            guard let probeIndex = try probeFiles.readIndex() else { throw Failure() }
            let proposedIndexBytes = probeIndex.count

            let path = try root("headroom-cap")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let recordsPath = path + "/Conversations/records"
            for n in 0..<8 {
                let name = String(format: "00000000-0000-0000-0000-%012x.json", n + 1)
                let fd = open(recordsPath + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw Failure() }
                let size = (32 << 20) - (n == 0 ? (512 << 10) : 0)
                guard fchmod(fd, 0o600) == 0, ftruncate(fd, off_t(size)) == 0 else { close(fd); throw Failure() }
                close(fd)
            }
            let beforeNames = try names(recordsPath)
            let beforeInventory = try files.inventoryRecords().sorted { $0.generation.value < $1.generation.value }
            let existingBytes = beforeInventory.reduce(0) { $0 + $1.bytes }
            let withoutHeadroom = existingBytes + proposedRecordBytes + proposedIndexBytes
            guard try files.readIndex() == nil,
                  beforeInventory.count == 8, beforeInventory.count < ConversationPersistenceJournal.maximumRecords,
                  existingBytes == ConversationPersistenceJournal.maximumDiskBytes - (512 << 10),
                  beforeInventory.allSatisfy({ $0.bytes >= 0 && $0.bytes <= ConversationPersistenceFiles.maximumRecordBytes }),
                  proposedRecordBytes > 0, proposedIndexBytes > 0,
                  withoutHeadroom < ConversationPersistenceJournal.maximumDiskBytes,
                  withoutHeadroom + ConversationPersistenceFiles.maximumIndexBytes > ConversationPersistenceJournal.maximumDiskBytes else { throw Failure() }
            try reject({ _ = try journal.upsert(record, updatedAt: clock) }, expected: .capacity)
            let afterInventory = try files.inventoryRecords().sorted { $0.generation.value < $1.generation.value }
            guard try files.readIndex() == nil, try names(recordsPath) == beforeNames,
                  afterInventory == beforeInventory else { throw Failure() }
        }
        // Duplicate IDs, duplicate generations, and the 257th entry preserve
        // the exact index and referenced file across the failed upsert.
        do {
            let path = try root("invalid-index")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let saved = try journal.upsert(record, updatedAt: clock)
            let original = try files.readIndex()!
            let body = try files.readRecord(saved.generation)
            let index = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            let entry = (index["records"] as! [[String: Any]])[0]
            let other = ConversationPersistenceGeneration.make()
            _ = try files.writeRecord(body, generation: other)
            for mode in 0..<3 {
                var second = entry
                if mode == 0 { second["generation"] = other.value }
                if mode == 1 { second["recordID"] = Data("different".utf8).base64EncodedString() }
                let entries = mode == 2 ? Array(repeating: entry, count: 257) : [entry, second]
                let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "records": entries])
                try files.writeIndex(bytes)
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
                guard try files.readIndex() == bytes, try files.readRecord(saved.generation) == body else { throw Failure() }
            }
        }
        // A corrupt body remains protected after a real lease release/reopen.
        do {
            let path = try root("corrupt-reopen")
            var saved: ConversationPersistenceJournalMetadata!
            var index = Data(); var corrupt = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                saved = try journal.upsert(record, updatedAt: clock)
                index = try files.readIndex()!
                let original = try files.readRecord(saved.generation)
                corrupt = Data(repeating: 0x78, count: original.count)
                try corrupt.write(to: URL(fileURLWithPath: path + "/Conversations/records/" + saved.generation.value + ".json"))
                try reject { _ = try journal.load(saved) }
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { clock })
                try reject { _ = try journal.load(saved) }
                try reject { _ = try journal.upsert(record, updatedAt: clock) }
                guard try files.readIndex() == index, try files.readRecord(saved.generation) == corrupt else { throw Failure() }
            }
        }
        // Distinct UTF-8 spellings remain distinct even though Swift String
        // compares their Unicode-normalized forms as equal.
        do {
            let path = try root("unicode-ids")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let a = copyRecord("\u{e9}"); let b = copyRecord("e\u{301}")
            guard a.id == b.id, Data(a.id.utf8) != Data(b.id.utf8) else { throw Failure() }
            let ma = try journal.upsert(a, updatedAt: clock)
            let mb = try journal.upsert(b, updatedAt: clock)
            guard try journal.metadata().count == 2, Data(try journal.load(ma).record.id.utf8) == Data(a.id.utf8), Data(try journal.load(mb).record.id.utf8) == Data(b.id.utf8) else { throw Failure() }
            let replacement = try journal.upsert(a, updatedAt: clock)
            guard try journal.metadata().count == 2, replacement.generation != ma.generation, Data(try journal.load(mb).record.id.utf8) == Data(b.id.utf8) else { throw Failure() }
        }
        // Read known stored milliseconds, independently compare the returned
        // Date to the expected instant, then feed it back into an upsert and
        // inspect the persisted integer (including the 999 ms precision case).
        do {
            let path = try root("date-matrix")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            _ = try journal.upsert(record, updatedAt: clock)
            for millis: Int64 in [0, 1, 999, 1000, 1_700_000_000_001, 1_700_000_000_123, 1_700_000_000_999] {
                var object = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
                var entries = object["records"] as! [[String: Any]]
                entries[0]["updatedMilliseconds"] = millis
                object["records"] = entries
                try files.writeIndex(JSONSerialization.data(withJSONObject: object))
                let metadata = try journal.metadata()[0]
                guard abs(metadata.updatedAt.timeIntervalSince1970 - Double(millis) / 1000) < 0.000001 else { throw Failure() }
                _ = try journal.upsert(record, updatedAt: metadata.updatedAt)
                let result = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
                let persisted = (result["records"] as! [[String: Any]])[0]["updatedMilliseconds"] as! NSNumber
                guard persisted.int64Value == millis else { throw Failure() }
            }
            for (seconds, expected) in [(1_700_000_000.1234, Int64(1_700_000_000_123)), (1_700_000_000.1238, Int64(1_700_000_000_124))] {
                _ = try journal.upsert(record, updatedAt: Date(timeIntervalSince1970: seconds))
                let object = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
                let stored = ((object["records"] as! [[String: Any]])[0]["updatedMilliseconds"] as! NSNumber).int64Value
                guard stored == expected else { throw Failure() }
            }
        }
        do {
            let path = try root("date-boundary")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let boundary = 9_223_372_036_854_775.808
            let below = boundary.nextDown
            let highClock = Date(timeIntervalSince1970: below)
            let journal = ConversationPersistenceJournal(files: files, now: { highClock })
            _ = try journal.upsert(record, updatedAt: highClock)
            let oldIndex = try files.readIndex()!
            for seconds in [boundary, boundary.nextUp] {
                try reject { _ = try journal.upsert(record, updatedAt: Date(timeIntervalSince1970: seconds)) }
                guard try files.readIndex() == oldIndex else { throw Failure() }
            }
            // Int64.max is in the saturated future window; validate persisted
            // integer directly, without a lossy Date -> integer conversion.
            var object = try JSONSerialization.jsonObject(with: oldIndex) as! [String: Any]
            var entries = object["records"] as! [[String: Any]]
            entries[0]["updatedMilliseconds"] = Int64.max
            object["records"] = entries
            try files.writeIndex(JSONSerialization.data(withJSONObject: object))
            guard try journal.metadata().count == 1 else { throw Failure() }
        }
        // Individually small valid messages, aggregate exceeds 4 MiB.
        do {
            let path = try root("aggregate")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let items = (0..<4096).map { n in
                ConversationStore.PersistentSnapshot.Item(id: "item-\(n)", message: .init(role: "user", blocks: [.init(kind: "text", text: String(repeating: "x", count: 1024), callID: nil, toolName: nil)], truncated: false), origin: .init(kind: "observed"), status: "complete")
            }
            let before = try names(path + "/Conversations/records")
            try reject({ _ = try journal.upsert(copyRecord(record.id, items: items), updatedAt: clock) }, expected: .invalidRecord)
            guard try files.readIndex() == nil, try names(path + "/Conversations/records") == before else { throw Failure() }
        }
    }

    private struct Failure: Error {}
}
