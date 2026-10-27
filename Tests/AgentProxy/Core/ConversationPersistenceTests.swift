import Foundation
import AgentProxyCore

struct ConversationPersistenceTests {
    static func run(check: (Bool, String) -> Void) throws {
        func key(_ native: String) -> ConversationKey {
            ConversationKey(agent: "claude", herdrSession: "session", nativeSession: native)!
        }
        let context = ConversationContext(routeID: "route", paneID: "pane", terminalID: "terminal")!
        func messages() throws -> (CapturedMessage, CapturedMessage) {
            let object: [String: Any] = ["messages": [
                ["role": "assistant", "content": [
                    ["type": "text", "text": "assistant text"],
                    ["type": "tool_use", "id": "call", "name": "tool", "input": ["value": "x"]]
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "call", "content": "result"],
                    ["type": "image"],
                    ["type": "text", "text": "user text"]
                ]]
            ]]
            let data = try JSONSerialization.data(withJSONObject: object)
            let projected = try RequestProjection.project(data, provider: .anthropic).messages
            return (projected[0], projected[1])
        }
        func encoded(_ snapshot: ConversationStore.PersistentSnapshot,
                     mutate: (inout [String: Any]) -> Void) throws -> Data {
            var root = try JSONSerialization.jsonObject(with: snapshot.encoded()) as! [String: Any]
            mutate(&root)
            return try JSONSerialization.data(withJSONObject: root)
        }
        func decoded(_ data: Data) throws -> ConversationStore.PersistentSnapshot {
            try ConversationStore.PersistentSnapshot.decode(data)
        }
        func persistentItem(_ id: String, text: String = "value") -> ConversationStore.PersistentSnapshot.Item {
            .init(id: id, message: .init(role: "user", blocks: [.init(kind: "text", text: text, callID: nil, toolName: nil)], truncated: false),
                  origin: .init(kind: "observed"), status: "complete")
        }
        func persistentRecord(_ id: String, native: String, updatedOrder: UInt64,
                              items: [ConversationStore.PersistentSnapshot.Item]) -> ConversationStore.PersistentSnapshot.Record {
            .init(id: id, key: .init(agent: "claude", herdrSession: "session", nativeSession: native),
                  context: .init(routeID: "route", paneID: "pane", terminalID: "terminal"), updatedOrder: updatedOrder,
                  items: items, truncated: false, status: "complete",
                  subagents: .init(observed: 0, withFinalResult: 0, limited: false, linkAvailable: false, ancestryIncomplete: false))
        }

        let (assistant, user) = try messages()
        let origins: [ConversationItem.Origin] = [
            .reconstructed, .observed, .response, .summary, .discontinuity,
            .compaction(.plaintext), .compaction(.opaque), .compaction(.noText), .compaction(.incomplete),
            .subagent(id: "child", depth: 1)
        ]
        var source = ConversationStore()
        let allItems = origins.enumerated().map { offset, origin in
            ConversationItem(id: "item-\(offset)", message: origin == .subagent(id: "child", depth: 1) ? assistant : user,
                             origin: origin, status: offset == 0 ? .streaming : .complete)
        }
        let first = try source.upsert(key: key("native"), context: context, items: allItems, status: .streaming,
                                      subagents: .init(observed: 1, withFinalResult: 1, limited: false,
                                                       linkAvailable: true, ancestryIncomplete: false))
        _ = try source.upsert(key: key("second"), context: context,
                              items: [ConversationItem(id: "second-item", message: assistant, origin: .response, status: .complete)],
                              status: .complete)
        let snapshot = source.persistenceSnapshot()
        check(source.persistenceRecord(id: first.conversationID) == snapshot.records.first,
              "single-record export matches normalized snapshot")
        var incremental = ConversationStore()
        let imported = incremental.restoreOne(snapshot.records[0])
        check(imported != nil && imported != first.conversationID && incremental.read(id: imported!)?.summary.status == .incomplete,
              "incremental restore creates a fresh ID and downgrades streaming")
        check(incremental.restoreOne(snapshot.records[0]) == nil && incremental.count == 1,
              "incremental restore never replaces an existing live key")
        let wire = try snapshot.encoded()
        let decodedSnapshot = try decoded(wire)
        check(decodedSnapshot.schemaVersion == 1 && decodedSnapshot.records.count == 2, "v1 schema exports and decodes bounded resident records")
        check(wire.count <= ConversationStore.PersistentSnapshot.maximumEncodedBytes, "encoded schema respects envelope maximum")
        let oversizedEncodeItems = Array(repeating: persistentItem("encoded-item"), count: 4_097)
        do {
            _ = try ConversationStore.PersistentSnapshot(records: [persistentRecord("encoded-items", native: "encoded-items", updatedOrder: 1,
                                                                                     items: oversizedEncodeItems)]).encoded()
            check(false, "programmatic overlarge item arrays must not encode")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .oversized, "programmatic item array cap matches bounded decoding")
        }
        let oversizedEncodeBlocks = Array(repeating: ConversationStore.PersistentSnapshot.Block(kind: "text", text: "value", callID: nil, toolName: nil), count: 65)
        let oversizedBlockItem = ConversationStore.PersistentSnapshot.Item(id: "encoded-block", message: .init(role: "user", blocks: oversizedEncodeBlocks, truncated: false),
                                                                            origin: .init(kind: "observed"), status: "complete")
        do {
            _ = try ConversationStore.PersistentSnapshot(records: [persistentRecord("encoded-blocks", native: "encoded-blocks", updatedOrder: 1,
                                                                                     items: [oversizedBlockItem])]).encoded()
            check(false, "programmatic overlarge block arrays must not encode")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .oversized, "programmatic block array cap matches bounded decoding")
        }

        var restored = ConversationStore()
        let oldEpoch = source.epoch
        let report = try restored.restore(decodedSnapshot)
        let restoredFirstID = report.restoredIDs[Data(first.conversationID.utf8)]!
        let restoredFirst = restored.read(id: restoredFirstID)!
        check(restored.epoch != oldEpoch && restored.sequence == 2, "restore creates a fresh epoch and fresh cursors")
        check(restoredFirst.summary.status == .incomplete && restoredFirst.items[0].status == .incomplete,
              "streaming summary and item are restored only as incomplete")
        check(restoredFirstID != first.conversationID && report.restoredIDs.count == 2,
              "restore allocates fresh live IDs and returns explicit persistent-to-live mappings")
        check(restoredFirst.items.map(\.origin) == origins, "round trip preserves every allowed item origin")
        check(Set(restoredFirst.items.flatMap { $0.message.blocks.map { $0.kind.rawValue } }) == Set(["text", "toolCall", "toolResult", "image"]),
              "round trip preserves every allowed block kind")
        check(restoredFirst.summary.subagents == ConversationSubagents(observed: 1, withFinalResult: 1, limited: false,
                                                                         linkAvailable: true, ancestryIncomplete: false),
              "round trip preserves bounded subagent statistics only")

        let composed = ConversationKey(agent: "claude", herdrSession: "session", nativeSession: "\u{E9}")!
        let decomposed = ConversationKey(agent: "claude", herdrSession: "session", nativeSession: "e\u{301}")!
        var opaque = ConversationStore()
        _ = try opaque.upsert(key: composed, context: context, items: [], status: .complete)
        _ = try opaque.upsert(key: decomposed, context: context, items: [], status: .complete)
        var opaqueRestored = ConversationStore()
        _ = try opaqueRestored.restore(opaque.persistenceSnapshot())
        check(opaqueRestored.count == 2 && opaqueRestored.read(key: composed) != nil && opaqueRestored.read(key: decomposed) != nil,
              "persistence retains byte-distinct canonically equivalent opaque key IDs")

        let unicodePersistentIDs = try decoded(try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            records[0]["id"] = "\u{E9}"
            records[0]["updatedOrder"] = 1
            var firstKey = records[0]["key"] as! [String: Any]
            firstKey["nativeSession"] = "unicode-precomposed-key"
            records[0]["key"] = firstKey
            records[1]["id"] = "e\u{301}"
            records[1]["updatedOrder"] = 2
            var secondKey = records[1]["key"] as! [String: Any]
            secondKey["nativeSession"] = "unicode-decomposed-key"
            records[1]["key"] = secondKey
            root["records"] = records
        })
        var unicodeRestored = ConversationStore()
        let unicodeReport = try unicodeRestored.restore(unicodePersistentIDs)
        let precomposedID = Data("\u{E9}".utf8)
        let decomposedID = Data("e\u{301}".utf8)
        check(precomposedID != decomposedID && unicodeReport.restoredIDs[precomposedID] != nil && unicodeReport.restoredIDs[decomposedID] != nil
                && unicodeReport.restoredIDs.count == 2 && unicodeRestored.count == 2,
              "canonically equivalent persistent IDs retain distinct byte-exact restore mappings without trapping")

        do {
            _ = try decoded(Data("{".utf8))
            check(false, "malformed schema must reject")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .malformed, "malformed schema rejects without a decode fallback")
        }
        let future = try encoded(snapshot) { $0["schemaVersion"] = 2 }
        do {
            _ = try decoded(future)
            check(false, "future schema must reject")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .unsupportedVersion, "future schema is not accepted as v1")
        }
        do {
            _ = try ConversationStore.PersistentSnapshot.decode(wire, maximumBytes: wire.count - 1)
            check(false, "encoded byte cap must reject before decode")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .oversized, "encoded byte cap is enforced")
        }
        let tooManyRecords = try encoded(snapshot) { root in
            let record = (root["records"] as! [[String: Any]])[0]
            root["records"] = Array(repeating: record, count: 257)
        }
        do {
            _ = try decoded(tooManyRecords)
            check(false, "overlarge record array must reject")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .oversized, "record array bound is enforced")
        }

        let duplicateID = try decoded(try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            records[1]["id"] = records[0]["id"]
            root["records"] = records
        })
        var withDuplicateID = ConversationStore()
        let duplicateReport = try withDuplicateID.restore(duplicateID)
        check(duplicateReport.rejectedRecordCount == 2 && withDuplicateID.count == 0,
              "duplicate persistent IDs reject both conflicting records before restore admission")
        let invalidID = try decoded(try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            records[0]["id"] = "bad\n"
            root["records"] = records
        })
        var withBadID = ConversationStore()
        let badIDReport = try withBadID.restore(invalidID)
        check(badIDReport.rejectedRecordCount == 1 && withBadID.count == 1,
              "bad persistent IDs reject only their record without partially admitting it")
        let badMetadata = try decoded(try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            var recordContext = records[0]["context"] as! [String: Any]
            recordContext["routeID"] = "bad\n"
            records[0]["context"] = recordContext
            root["records"] = records
        })
        var withBadMetadata = ConversationStore()
        check(try withBadMetadata.restore(badMetadata).rejectedRecordCount == 1 && withBadMetadata.count == 1,
              "invalid context metadata cannot mutate an admitted record")
        let badBlocks = try decoded(try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            var items = records[0]["items"] as! [[String: Any]]
            var message = items[0]["message"] as! [String: Any]
            var blocks = message["blocks"] as! [[String: Any]]
            blocks[0]["kind"] = "unknown"
            message["blocks"] = blocks; items[0]["message"] = message; records[0]["items"] = items
            root["records"] = records
        })
        var withBadBlock = ConversationStore()
        check(try withBadBlock.restore(badBlocks).rejectedRecordCount == 1 && withBadBlock.count == 1,
              "unknown block kinds cannot enter the live store")
        let badStats = try decoded(try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            var stats = records[0]["subagents"] as! [String: Any]
            stats["observed"] = 129
            records[0]["subagents"] = stats; root["records"] = records
        })
        var withBadStats = ConversationStore()
        check(try withBadStats.restore(badStats).rejectedRecordCount == 1 && withBadStats.count == 1,
              "invalid subagent statistics cannot enter the live store")
        let tooManyItems = try encoded(snapshot) { root in
            var records = root["records"] as! [[String: Any]]
            let item = (records[0]["items"] as! [[String: Any]])[0]
            records[0]["items"] = Array(repeating: item, count: 4_097)
            root["records"] = records
        }
        do {
            _ = try decoded(tooManyItems)
            check(false, "overlarge item array must reject during bounded decode")
        } catch let error as ConversationStore.PersistenceFailure {
            check(error == .oversized, "per-record item array bound rejects before normal admission")
        }

        let defaultOversized = ConversationStore.PersistentSnapshot(records: [
            persistentRecord("default-oversized", native: "default-oversized", updatedOrder: 1,
                             items: (0..<4_096).map { persistentItem("default-large-\($0)", text: String(repeating: "x", count: 1_100)) })
        ])
        var defaultBounded = ConversationStore()
        let defaultOversizedReport = try defaultBounded.restore(defaultOversized)
        check(defaultOversizedReport.rejectedRecordCount == 1 && defaultBounded.count == 0,
              "valid items above the default 4 MiB record bound reject without a trimmed restore")

        var one = ConversationStore()
        let smallItem = ConversationItem(id: "small-item", message: user, origin: .observed, status: .complete)
        _ = try one.upsert(key: key("a0"), context: context, items: [smallItem], status: .complete)
        let exactCost = one.accountedBytes
        var perRecordSource = ConversationStore(limits: .init(conversationBytes: exactCost * 2, totalBytes: exactCost * 3, conversations: 2))
        _ = try perRecordSource.upsert(key: key("a0"), context: context, items: [smallItem], status: .complete)
        let newerItems = [
            ConversationItem(id: "new-item-1", message: user, origin: .observed, status: .complete),
            ConversationItem(id: "new-item-2", message: user, origin: .observed, status: .complete)
        ]
        _ = try perRecordSource.upsert(key: key("b0"), context: context, items: newerItems, status: .complete)
        var perRecordBounded = ConversationStore(limits: .init(conversationBytes: exactCost, totalBytes: exactCost, conversations: 2))
        let perRecordReport = try perRecordBounded.restore(perRecordSource.persistenceSnapshot())
        check(perRecordReport.rejectedRecordCount == 1 && perRecordReport.evictedPersistentIDs.isEmpty
                && perRecordBounded.count == 1 && perRecordBounded.read(key: key("a0")) != nil,
              "lower per-record limit rejects a trimming newer record without evicting an older valid record")

        var two = ConversationStore(limits: .init(conversationBytes: exactCost, totalBytes: exactCost * 2, conversations: 2))
        _ = try two.upsert(key: key("a0"), context: context, items: [smallItem], status: .complete)
        _ = try two.upsert(key: key("b0"), context: context, items: [smallItem], status: .complete)
        var bounded = ConversationStore(limits: .init(conversationBytes: exactCost, totalBytes: exactCost, conversations: 2))
        let eviction = try bounded.restore(two.persistenceSnapshot())
        check(bounded.count == 1 && bounded.read(key: key("b0")) != nil && bounded.accountedBytes <= exactCost && eviction.evictedPersistentIDs.count == 1,
              "restore retains deterministic newest update under existing capacity/accounting bounds")
    }
}
