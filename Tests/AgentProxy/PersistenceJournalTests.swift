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
            print("PASS: bounded persistence journal")
        } catch {
            print("FAIL: journal \(error)")
            exit(1)
        }
    }
    private struct Failure: Error {}
}
