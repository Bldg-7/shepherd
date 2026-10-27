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
        // Physical generation namespace and byte ceilings use real verified
        // stat sizes. This is not the logical referenced-record limit.
        for countLimit in [true, false] {
            let path = try root(countLimit ? "count-cap" : "byte-cap")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let recordsPath = path + "/Conversations/records"
            for n in 0..<(countLimit ? ConversationPersistenceFiles.maximumPhysicalRecords : 8) {
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
            var dateClock = clock
            let journal = ConversationPersistenceJournal(files: files, now: { dateClock })
            _ = try journal.upsert(record, updatedAt: clock)
            for millis: Int64 in [0, 1, 999, 1000, 1_700_000_000_001, 1_700_000_000_123, 1_700_000_000_999] {
                dateClock = Date(timeIntervalSince1970: Double(millis) / 1000)
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
            dateClock = clock
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
        try ageSweepFixtures(base: base, record: record)
        try duplicateJSONFixtures(base: base, record: record)
        try pressureFixtures(base: base, record: record, clock: clock)
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

    private static func pressureFixtures(base: String, record: ConversationStore.PersistentSnapshot.Record, clock: Date) throws {
        func copy(_ id: String) -> ConversationStore.PersistentSnapshot.Record {
            .init(id: id, key: record.key, context: record.context, updatedOrder: record.updatedOrder,
                  items: record.items, truncated: record.truncated, status: record.status, subagents: record.subagents)
        }
        func root(_ name: String) throws -> String {
            let path = base + "/pressure-" + name
            guard mkdir(path, 0o700) == 0 else { throw Failure() }
            return path
        }
        // Real references, not physical orphans: reads do not refresh age;
        // equal timestamps are ordered by raw ID bytes, not String equality.
        do {
            let path = try root("order")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingRecordLimit: 2)
            let a = try journal.upsert(copy("é"), updatedAt: clock.addingTimeInterval(-2))
            let b = try journal.upsert(copy("e\u{301}"), updatedAt: clock.addingTimeInterval(-2))
            _ = try journal.load(b)
            let before = try files.readIndex()!
            do { _ = try journal.upsert(copy("older"), updatedAt: clock.addingTimeInterval(-3)); throw Failure() }
            catch ConversationPersistenceJournalError.capacity {}
            guard try files.readIndex() == before else { throw Failure() }
            _ = try journal.upsert(copy("fresh"), updatedAt: clock)
            let remaining = try journal.metadata()
            guard remaining.count == 2, remaining.contains(where: { $0.generation == a.generation }),
                  !remaining.contains(where: { $0.generation == b.generation }),
                  !(try files.inventoryRecords()).contains(where: { $0.generation == b.generation }) else { throw Failure() }
        }
        // A real update changes ordering; loading the other row does not.
        do {
            let path = try root("update-order")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingRecordLimit: 2)
            _ = try journal.upsert(copy("first"), updatedAt: clock.addingTimeInterval(-3))
            let second = try journal.upsert(copy("second"), updatedAt: clock.addingTimeInterval(-2))
            let firstUpdated = try journal.upsert(copy("first"), updatedAt: clock.addingTimeInterval(-1))
            _ = try journal.load(second)
            _ = try journal.upsert(copy("third"), updatedAt: clock)
            let remaining = try journal.metadata()
            guard remaining.contains(where: { $0.generation == firstUpdated.generation }),
                  !remaining.contains(where: { $0.generation == second.generation }) else { throw Failure() }
        }
        // Independently measure actual encoded inputs in a separate store;
        // place the limit one byte below the complete two-record reservation.
        do {
            let probePath = try root("bytes-probe")
            let probeFiles = try ConversationPersistenceFiles(verifiedStateRootPath: probePath)
            let probe = ConversationPersistenceJournal(files: probeFiles, now: { clock })
            _ = try probe.upsert(record, updatedAt: clock.addingTimeInterval(-1))
            let second = try probe.upsert(copy("new"), updatedAt: clock)
            let secondBytes = try probeFiles.readRecord(second.generation).count
            let proposedIndexBytes = try probeFiles.readIndex()!.count

            let path = try root("bytes")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let setup = ConversationPersistenceJournal(files: files, now: { clock })
            let old = try setup.upsert(record, updatedAt: clock.addingTimeInterval(-1))
            let currentIndexBytes = try files.readIndex()!.count
            let existingBytes = try files.inventoryRecords().reduce(0) { $0 + $1.bytes }
            let limit = existingBytes + currentIndexBytes + secondBytes + proposedIndexBytes + ConversationPersistenceFiles.maximumIndexBytes - 1
            guard existingBytes == old.encodedBytes, secondBytes > 1, proposedIndexBytes > currentIndexBytes,
                  limit < ConversationPersistenceJournal.maximumDiskBytes else { throw Failure() }
            let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingDiskLimit: limit)
            _ = try journal.upsert(copy("new"), updatedAt: clock)
            guard journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 1, cleanupDurabilityUncertain: false),
                  !(try files.inventoryRecords()).contains(where: { $0.generation == old.generation }) else { throw Failure() }
        }
        // Pressure recovery only removes supported, validated orphan bodies
        // and strictly owned empty temporaries. Unknown orphan bytes remain.
        do {
            let path = try root("orphan-recovery")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let setup = ConversationPersistenceJournal(files: files, now: { clock })
            let old = try setup.upsert(record, updatedAt: clock.addingTimeInterval(-1))
            let body = try files.readRecord(old.generation)
            let orphan = try files.writeRecord(body)
            let protected = try files.writeRecord(Data("future".utf8))
            let temporary = path + "/Conversations/records/.tmp-00000000-0000-0000-0000-000000000001"
            guard FileManager.default.createFile(atPath: temporary, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw Failure() }
            let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingRecordLimit: 1)
            _ = try journal.upsert(copy("new"), updatedAt: clock)
            guard journal.maintenanceTransactions == [.recovered(completed: 2, cleanupDurabilityUncertain: false),
                  .committed(removed: 1, cleanupCompleted: 1, cleanupDurabilityUncertain: false)],
                  !(try files.inventoryRecords()).contains(where: { $0.generation == orphan }),
                  try files.readRecord(protected) == Data("future".utf8),
                  !FileManager.default.fileExists(atPath: temporary) else { throw Failure() }
        }
        // Nonempty temporary content blocks all mutation rather than being
        // treated as an empty reclaimable temporary.
        do {
            let path = try root("protected-temp")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock })
            let saved = try journal.upsert(record, updatedAt: clock)
            let index = try files.readIndex()!
            let temporary = path + "/Conversations/.tmp-00000000-0000-0000-0000-000000000001"
            let protected = Data("unknown".utf8)
            guard FileManager.default.createFile(atPath: temporary, contents: protected, attributes: [.posixPermissions: 0o600]) else { throw Failure() }
            do { _ = try journal.upsert(copy("new"), updatedAt: clock); throw Failure() }
            catch ConversationPersistenceJournalError.unavailable {}
            guard try files.readIndex() == index, try files.readRecord(saved.generation).count == saved.encodedBytes,
                  try Data(contentsOf: URL(fileURLWithPath: temporary)) == protected else { throw Failure() }
        }
        // Pressure index failures must never unlink the old generation; a
        // failed cleanup after a durable index must not resurrect it.
        for mode in 0..<3 {
            let path = try root("fault-\(mode)")
            var saved: ConversationPersistenceJournalMetadata!
            var oldIndex = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingRecordLimit: 1)
                saved = try journal.upsert(record, updatedAt: clock.addingTimeInterval(-1))
                oldIndex = try files.readIndex()!
            }
            do {
                let control = ConversationPersistenceFilesTestControl(
                    fault: mode == 2 ? .recordUnlink : nil,
                    indexFault: mode == 0 ? .beforeRename : (mode == 1 ? .afterRenameBeforeDirectorySync : nil))
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: control)
                let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingRecordLimit: 1)
                do { _ = try journal.upsert(copy("new"), updatedAt: clock); throw Failure() }
                catch let error as ConversationPersistenceJournalError {
                    let expected: ConversationPersistenceJournalError = mode == 0 ? .unavailable :
                        (mode == 1 ? .indexCommittedButDurabilityUncertain : .retentionCommittedCleanupFailed)
                    guard error == expected else { throw Failure() }
                }
                guard try files.readRecord(saved.generation).count == saved.encodedBytes else { throw Failure() }
                if mode == 0 { guard try files.readIndex() == oldIndex else { throw Failure() } }
                if mode == 2 {
                    guard journal.maintenanceTransactions == [.committed(removed: 1, cleanupCompleted: 0, cleanupDurabilityUncertain: false)],
                          try journal.metadata().isEmpty else { throw Failure() }
                }
            }
        }
        // Malformed raw UTF-8 in either index or victim is preserved before
        // any index-first retirement, independent of Foundation decoder policy.
        for indexCase in [false, true] {
            let path = try root(indexCase ? "utf8-index" : "utf8-victim")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let journal = ConversationPersistenceJournal(files: files, now: { clock }, testingRecordLimit: 1)
            let saved = try journal.upsert(record, updatedAt: clock.addingTimeInterval(-1))
            let body = try files.readRecord(saved.generation)
            var index = try files.readIndex()!
            var badBody = body
            if indexCase {
                index = Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d])
                try files.writeIndex(index)
            } else {
                guard let range = badBody.range(of: Data("synthetic".utf8)) else { throw Failure() }
                badBody[range.lowerBound] = 0xff
                try badBody.write(to: URL(fileURLWithPath: path + "/Conversations/records/" + saved.generation.value + ".json"))
            }
            do { _ = try journal.upsert(copy("new"), updatedAt: clock); throw Failure() }
            catch ConversationPersistenceJournalError.unavailable {}
            guard try files.readIndex() == index, try files.readRecord(saved.generation) == badBody else { throw Failure() }
        }
    }

    private static func duplicateJSONFixtures(base: String, record: ConversationStore.PersistentSnapshot.Record) throws {
        func check(_ source: String, valid: Bool) throws {
            do {
                try ConversationPersistenceJournal.validateRawJSONForTesting(Data(source.utf8))
                if !valid { throw Failure() }
            } catch is Failure { throw Failure() }
            catch { if valid { throw Failure() } }
        }
        try check(#"{"outer":{"k":1},"other":{"k":2},"text":"{\"a\":1,\"a\":2} \\ \" \uD83D\uDE00"}"#, valid: true)
        try check(#"{"version":1,"\u0076ersion":2}"#, valid: false)
        try check(#"{"\uD83D\uDE00":1,"😀":2}"#, valid: false)
        try check(#"{"a\"b":1,"a\u0022b":2}"#, valid: false)
        try check(#"{"a\\b":1,"a\u005cb":2}"#, valid: false)
        try check(#"{"a":1,"nested":{"a":1,"a":2}}"#, valid: false)
        try check(#"{"a":1,}"#, valid: false)
        try check(#"{"a":"\uD800"}"#, valid: false)
        try check("[01]", valid: false)
        try check(String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66), valid: false)
        try check("{\"" + String(repeating: "x", count: 4097) + "\":1}", valid: false)
        try check("{" + (0..<513).map { "\"k\($0)\":0" }.joined(separator: ",") + "}", valid: false)
        try check("[" + Array(repeating: "0", count: 4097).joined(separator: ",") + "]", valid: false)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = start.addingTimeInterval(30 * 24 * 60 * 60)
        func root(_ name: String) throws -> String {
            let path = base + "/duplicate-" + name
            guard mkdir(path, 0o700) == 0 else { throw Failure() }
            return path
        }
        func copy(_ id: String) -> ConversationStore.PersistentSnapshot.Record {
            .init(id: id, key: record.key, context: record.context, updatedOrder: record.updatedOrder,
                  items: record.items, truncated: record.truncated, status: record.status, subagents: record.subagents)
        }
        func reject(_ operation: () throws -> Void) throws {
            do { try operation(); throw Failure() }
            catch ConversationPersistenceJournalError.unavailable {}
        }
        func injected(_ text: String, member: String, before: Bool) -> String {
            if before { return "{" + member + "," + String(text.dropFirst()) }
            return String(text.dropLast()) + "," + member + "}"
        }
        // Raw insertion, not JSONSerialization: conflicting members in both
        // orders, including an escape-equivalent spelling of a known key.
        for (number, member) in [#""\u0076ersion":2"#, #""records":[]"#].enumerated() {
            for before in [false, true] {
                let path = try root("index-\(number)-\(before)")
                var saved: ConversationPersistenceJournalMetadata!
                var body = Data(); var bad = Data()
                do {
                    let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                    let journal = ConversationPersistenceJournal(files: files, now: { start })
                    saved = try journal.upsert(record, updatedAt: start)
                    body = try files.readRecord(saved.generation)
                    let original = try files.readIndex()!
                    bad = Data(injected(String(decoding: original, as: UTF8.self), member: member, before: before).utf8)
                    try files.writeIndex(bad)
                    let later = ConversationPersistenceJournal(files: files, now: { expired })
                    try reject { _ = try later.metadata() }
                    try reject { _ = try later.upsert(record, updatedAt: expired) }
                    guard try files.readIndex() == bad, try files.readRecord(saved.generation) == body else { throw Failure() }
                }
                do {
                    let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                    let journal = ConversationPersistenceJournal(files: files, now: { expired })
                    try reject { try journal.activate() }
                    guard try files.readIndex() == bad, try files.readRecord(saved.generation) == body else { throw Failure() }
                }
            }
        }
        // A valid first expired victim must remain protected when a later raw
        // victim has conflicting duplicate envelope or nested message members.
        for number in 0..<3 {
            for before in [false, true] {
                let path = try root("record-\(number)-\(before)")
                var good: ConversationPersistenceJournalMetadata!; var bad: ConversationPersistenceJournalMetadata!
                var goodBody = Data(); var badBody = Data(); var indexBytes = Data()
                do {
                    let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                    let journal = ConversationPersistenceJournal(files: files, now: { start })
                    good = try journal.upsert(record, updatedAt: start)
                    bad = try journal.upsert(copy("duplicate-bad"), updatedAt: start)
                    goodBody = try files.readRecord(good.generation)
                    let original = String(decoding: try files.readRecord(bad.generation), as: UTF8.self)
                    let modified: String
                    if number == 0 { modified = injected(original, member: #""\u0073chemaVersion":2"#, before: before) }
                    else if number == 1 { modified = injected(original, member: #""records":[]"#, before: before) }
                    else {
                        let role = #""role":"user""#
                        let extra = #""\u0072ole":"future""#
                        modified = original.replacingOccurrences(of: role, with: before ? extra + "," + role : role + "," + extra)
                    }
                    guard modified != original else { throw Failure() }
                    badBody = Data(modified.utf8)
                    try badBody.write(to: URL(fileURLWithPath: path + "/Conversations/records/" + bad.generation.value + ".json"))
                    var index = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
                    var entries = index["records"] as! [[String: Any]]
                    entries[1]["encodedBytes"] = badBody.count; index["records"] = entries
                    indexBytes = try JSONSerialization.data(withJSONObject: index)
                    try files.writeIndex(indexBytes)
                    try reject { _ = try journal.upsert(copy("duplicate-bad"), updatedAt: start) }
                    let later = ConversationPersistenceJournal(files: files, now: { expired })
                    try reject { try later.activate() }
                    guard later.lastMaintenance == .none, try files.readIndex() == indexBytes,
                          try files.readRecord(good.generation) == goodBody, try files.readRecord(bad.generation) == badBody else { throw Failure() }
                }
                do {
                    let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                    let journal = ConversationPersistenceJournal(files: files, now: { expired })
                    try reject { _ = try journal.metadata() }
                    guard try files.readIndex() == indexBytes, try files.readRecord(good.generation) == goodBody,
                          try files.readRecord(bad.generation) == badBody else { throw Failure() }
                }
            }
        }
    }

    private static func ageSweepFixtures(base: String, record: ConversationStore.PersistentSnapshot.Record) throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lifetime: TimeInterval = 30 * 24 * 60 * 60
        func root(_ name: String) throws -> String {
            let path = base + "/age-" + name
            guard mkdir(path, 0o700) == 0 else { throw Failure() }
            return path
        }
        func copy(_ id: String) -> ConversationStore.PersistentSnapshot.Record {
            .init(id: id, key: record.key, context: record.context, updatedOrder: record.updatedOrder,
                  items: record.items, truncated: record.truncated, status: record.status, subagents: record.subagents)
        }
        func reject(_ expected: ConversationPersistenceJournalError, _ operation: () throws -> Void) throws {
            do { try operation(); throw Failure() }
            catch let error as ConversationPersistenceJournalError { guard error == expected else { throw Failure() } }
        }
        // Boundary, fresh survivor, explicit activation and incoming expiry.
        do {
            let path = try root("boundary")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            var now = start
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let old = try journal.upsert(record, updatedAt: start)
            now = start.addingTimeInterval(lifetime - 1)
            let fresh = try journal.upsert(copy("fresh"), updatedAt: now)
            guard try journal.metadata() == [old, fresh], try journal.load(old).record == record else { throw Failure() }
            let oldIndex = try files.readIndex()!
            try reject(.unavailable) { _ = try journal.upsert(copy("expired-input"), updatedAt: start.addingTimeInterval(-1)) }
            guard try files.readIndex() == oldIndex else { throw Failure() }
            now = start.addingTimeInterval(lifetime)
            try journal.activate()
            guard journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 1, cleanupDurabilityUncertain: false),
                  try files.inventoryRecords().map(\.generation) == [fresh.generation],
                  try journal.metadata() == [fresh], try journal.load(fresh).record == copy("fresh") else { throw Failure() }
            try reject(.unavailable) { _ = try journal.load(old) }
            try reject(.unavailable) { _ = try journal.upsert(record, updatedAt: start) }
        }
        // Persisted milliseconds and clock quantization at the exact 30-day boundary.
        do {
            let path = try root("millisecond-boundary")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            let stored: Int64 = 1_700_000_000_123
            let lifeMillis: Int64 = 30 * 24 * 60 * 60 * 1_000
            var now = Date(timeIntervalSince1970: Double(stored) / 1_000)
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let saved = try journal.upsert(record, updatedAt: now)
            let index = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
            let persisted = ((index["records"] as! [[String: Any]])[0]["updatedMilliseconds"] as! NSNumber).int64Value
            guard persisted == stored else { throw Failure() }
            now = Date(timeIntervalSince1970: Double(stored + lifeMillis - 1) / 1_000 + 0.0002)
            guard Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)) == stored + lifeMillis - 1,
                  try journal.metadata() == [saved] else { throw Failure() }
            now = Date(timeIntervalSince1970: Double(stored + lifeMillis) / 1_000 + 0.0002)
            guard Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)) == stored + lifeMillis else { throw Failure() }
            try journal.activate()
            guard journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 1, cleanupDurabilityUncertain: false),
                  try files.inventoryRecords().isEmpty else { throw Failure() }
        }
        // Both metadata and a write independently invoke the sweep without activation.
        for writing in [false, true] {
            let path = try root(writing ? "write" : "metadata")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            var now = start
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let old = try journal.upsert(record, updatedAt: start)
            now = start.addingTimeInterval(lifetime)
            if writing { _ = try journal.upsert(copy("new"), updatedAt: now) }
            else { guard try journal.metadata().isEmpty else { throw Failure() } }
            guard journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 1, cleanupDurabilityUncertain: false),
                  !(try files.inventoryRecords()).contains(where: { $0.generation == old.generation }) else { throw Failure() }
        }
        // Loading an expired record may commit its removal before returning
        // unavailable; the maintenance result makes that intermediate state explicit.
        do {
            let path = try root("load")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            var now = start
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let old = try journal.upsert(record, updatedAt: start)
            now = start.addingTimeInterval(lifetime)
            try reject(.unavailable) { _ = try journal.load(old) }
            guard journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 1, cleanupDurabilityUncertain: false),
                  try files.inventoryRecords().isEmpty else { throw Failure() }
        }
        // All candidates are validated before any index change, even when an
        // earlier candidate is valid and the later candidate is corrupt/future.
        for future in [false, true] {
            let path = try root(future ? "future" : "corrupt")
            var good: ConversationPersistenceJournalMetadata!
            var bad: ConversationPersistenceJournalMetadata!
            var index = Data(); var goodBody = Data(); var damaged = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                var now = start
                let journal = ConversationPersistenceJournal(files: files, now: { now })
                good = try journal.upsert(record, updatedAt: start)
                bad = try journal.upsert(copy("bad"), updatedAt: start)
                index = try files.readIndex()!
                goodBody = try files.readRecord(good.generation)
                let original = try files.readRecord(bad.generation)
                damaged = future ? Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8) : Data(repeating: 0x78, count: original.count)
                guard damaged.count == original.count, damaged != original else { throw Failure() }
                try damaged.write(to: URL(fileURLWithPath: path + "/Conversations/records/" + bad.generation.value + ".json"))
                now = start.addingTimeInterval(lifetime)
                try reject(.unavailable) { _ = try journal.metadata() }
                guard journal.lastMaintenance == .none, try files.readIndex() == index,
                      try files.readRecord(good.generation) == goodBody, try files.readRecord(bad.generation) == damaged else { throw Failure() }
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
                try reject(.unavailable) { try journal.activate() }
                guard try files.readIndex() == index, try files.readRecord(good.generation) == goodBody,
                      try files.readRecord(bad.generation) == damaged else { throw Failure() }
            }
        }
        // Unknown nested record fields are protected even when Core's
        // forward-compatible decoder can otherwise restore known fields.
        do {
            let path = try root("unknown-record-field")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            var now = start
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let saved = try journal.upsert(record, updatedAt: start)
            let original = try files.readRecord(saved.generation)
            var envelope = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var records = envelope["records"] as! [[String: Any]]
            var items = records[0]["items"] as! [[String: Any]]
            items[0]["futureField"] = "preserve"
            records[0]["items"] = items; envelope["records"] = records
            let unknown = try JSONSerialization.data(withJSONObject: envelope)
            try unknown.write(to: URL(fileURLWithPath: path + "/Conversations/records/" + saved.generation.value + ".json"))
            var index = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
            var entries = index["records"] as! [[String: Any]]
            entries[0]["encodedBytes"] = unknown.count; index["records"] = entries
            let indexBytes = try JSONSerialization.data(withJSONObject: index)
            try files.writeIndex(indexBytes)
            now = start.addingTimeInterval(lifetime)
            try reject(.unavailable) { try journal.activate() }
            guard try files.readIndex() == indexBytes, try files.readRecord(saved.generation) == unknown else { throw Failure() }
        }
        // A future index forbids age cleanup, even for a valid old record.
        do {
            let path = try root("future-index")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            var now = start
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let saved = try journal.upsert(record, updatedAt: start)
            let body = try files.readRecord(saved.generation)
            var object = try JSONSerialization.jsonObject(with: files.readIndex()!) as! [String: Any]
            object["version"] = 2
            let future = try JSONSerialization.data(withJSONObject: object)
            try files.writeIndex(future)
            now = start.addingTimeInterval(lifetime)
            try reject(.unavailable) { try journal.activate() }
            guard try files.readIndex() == future, try files.readRecord(saved.generation) == body else { throw Failure() }
        }
        // Reserve the new index before publishing: sparse, measured orphan
        // bytes leave less than the conservative index headroom available.
        do {
            let probePath = try root("index-headroom-probe")
            var oldIndexSize = 0; var nextIndexSize = 0
            do {
                let probeFiles = try ConversationPersistenceFiles(verifiedStateRootPath: probePath)
                var probeNow = start
                let probe = ConversationPersistenceJournal(files: probeFiles, now: { probeNow })
                _ = try probe.upsert(record, updatedAt: start)
                oldIndexSize = try probeFiles.readIndex()!.count
                probeNow = start.addingTimeInterval(lifetime)
                try probe.activate()
                nextIndexSize = try probeFiles.readIndex()!.count
            }
            let path = try root("index-headroom")
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
            var now = start
            let journal = ConversationPersistenceJournal(files: files, now: { now })
            let saved = try journal.upsert(record, updatedAt: start)
            let body = try files.readRecord(saved.generation)
            let index = try files.readIndex()!
            let directory = path + "/Conversations/records"
            for n in 0..<8 {
                let name = String(format: "00000000-0000-0000-0000-%012x.json", n + 1)
                let fd = open(directory + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw Failure() }
                let size = (32 << 20) - (n == 0 ? (512 << 10) : 0)
                guard fchmod(fd, 0o600) == 0, ftruncate(fd, off_t(size)) == 0 else { close(fd); throw Failure() }
                close(fd)
            }
            let before = try files.inventoryRecords().sorted { $0.generation.value < $1.generation.value }
            let inventoryBytes = before.reduce(0) { $0 + $1.bytes }
            let withoutReserve = inventoryBytes + index.count + nextIndexSize
            guard oldIndexSize == index.count, nextIndexSize > 0, before.count == 9,
                  before.count < ConversationPersistenceJournal.maximumRecords,
                  withoutReserve < ConversationPersistenceJournal.maximumDiskBytes,
                  withoutReserve + ConversationPersistenceFiles.maximumIndexBytes > ConversationPersistenceJournal.maximumDiskBytes else { throw Failure() }
            now = start.addingTimeInterval(lifetime)
            try reject(.capacity) { _ = try journal.metadata() }
            let after = try files.inventoryRecords().sorted { $0.generation.value < $1.generation.value }
            guard journal.lastMaintenance == .none, try files.readIndex() == index,
                  try files.readRecord(saved.generation) == body, after == before else { throw Failure() }
        }
        // No removal after a precommit or durability-uncertain index result.
        for post in [false, true] {
            let path = try root(post ? "index-post" : "index-pre")
            var saved: ConversationPersistenceJournalMetadata!
            var oldIndex = Data(); var oldBody = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start })
                saved = try journal.upsert(record, updatedAt: start)
                oldIndex = try files.readIndex()!; oldBody = try files.readRecord(saved.generation)
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: .init(indexFault: post ? .afterRenameBeforeDirectorySync : .beforeRename))
                let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
                try reject(post ? .indexCommittedButDurabilityUncertain : .unavailable) { _ = try journal.metadata() }
                guard journal.lastMaintenance == (post ? .indexDurabilityUncertain : .none),
                      try files.readRecord(saved.generation) == oldBody else { throw Failure() }
                let visible = try files.readIndex()!
                guard (post ? visible != oldIndex : visible == oldIndex) else { throw Failure() }
            }
        }
        // A failed unlink leaves a durable logical removal and accounted bytes;
        // a failed directory sync is reported separately and blocks this call.
        for syncFailure in [false, true] {
            let path = try root(syncFailure ? "unlink-sync" : "unlink")
            var saved: ConversationPersistenceJournalMetadata!
            var body = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start })
                saved = try journal.upsert(record, updatedAt: start)
                body = try files.readRecord(saved.generation)
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: .init(fault: syncFailure ? .recordUnlinkDirectorySync : .recordUnlink))
                let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
                try reject(.retentionCommittedCleanupFailed) { _ = try journal.upsert(copy("not-written"), updatedAt: start.addingTimeInterval(lifetime)) }
                guard journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 0, cleanupDurabilityUncertain: syncFailure) else { throw Failure() }
                if !syncFailure { guard try files.readRecord(saved.generation) == body else { throw Failure() } }
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
                guard try journal.metadata().isEmpty else { throw Failure() }
                let inventory = try files.inventoryRecords()
                if !syncFailure {
                    guard inventory.count == 1, inventory[0].generation == saved.generation, inventory[0].bytes == body.count else { throw Failure() }
                } else { guard inventory.isEmpty else { throw Failure() } }
            }
        }
        // Second deletion fails after the first was unlinked and directory-synced.
        do {
            let path = try root("partial-cleanup")
            var first: ConversationPersistenceJournalMetadata!
            var second: ConversationPersistenceJournalMetadata!
            var secondBody = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start })
                first = try journal.upsert(record, updatedAt: start)
                second = try journal.upsert(copy("second"), updatedAt: start)
                secondBody = try files.readRecord(second.generation)
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: .init(fault: .recordUnlinkForGeneration(second.generation)))
                let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
                try reject(.retentionCommittedCleanupFailed) { try journal.activate() }
                guard journal.lastMaintenance == .committed(removed: 2, cleanupCompleted: 1, cleanupDurabilityUncertain: false) else { throw Failure() }
                let remaining = try files.inventoryRecords()
                guard remaining.count == 1, remaining[0].generation == second.generation,
                      remaining[0].bytes == secondBody.count, try files.readRecord(second.generation) == secondBody else { throw Failure() }
            }
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
                guard try journal.metadata().isEmpty else { throw Failure() }
                let remaining = try files.inventoryRecords()
                guard remaining.count == 1, remaining[0].generation == second.generation,
                      remaining[0].generation != first.generation, remaining[0].bytes == secondBody.count else { throw Failure() }
            }
        }
        // Replacement after validation cannot be deleted using the old ticket.
        do {
            let path = try root("replacement")
            var saved: ConversationPersistenceJournalMetadata!
            var original = Data()
            do {
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: path)
                let journal = ConversationPersistenceJournal(files: files, now: { start })
                saved = try journal.upsert(record, updatedAt: start)
                original = try files.readRecord(saved.generation)
            }
            let destination = path + "/Conversations/records/" + saved.generation.value + ".json"
            let replacement = Data(repeating: 0x78, count: original.count)
            var substituted = false
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: path, testControl: .init(event: { event in
                if case .beforeRecordRemoval = event {
                    guard rename(destination, path + "/displaced") == 0,
                          FileManager.default.createFile(atPath: destination, contents: replacement, attributes: [.posixPermissions: 0o600]) else { return }
                    substituted = true
                }
            }))
            let journal = ConversationPersistenceJournal(files: files, now: { start.addingTimeInterval(lifetime) })
            try reject(.retentionCommittedCleanupFailed) { _ = try journal.metadata() }
            var oldInfo = stat(); var newInfo = stat()
            guard substituted, lstat(path + "/displaced", &oldInfo) == 0, lstat(destination, &newInfo) == 0,
                  oldInfo.st_ino != newInfo.st_ino, oldInfo.st_size == newInfo.st_size,
                  try Data(contentsOf: URL(fileURLWithPath: path + "/displaced")) == original,
                  try Data(contentsOf: URL(fileURLWithPath: destination)) == replacement,
                  journal.lastMaintenance == .committed(removed: 1, cleanupCompleted: 0, cleanupDurabilityUncertain: false),
                  try journal.metadata().isEmpty else { throw Failure() }
        }
    }

    private struct Failure: Error {}
}
