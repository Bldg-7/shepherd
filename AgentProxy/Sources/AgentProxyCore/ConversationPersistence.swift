import Foundation
import AgentProxyProtocol

/// Versioned, filesystem-independent values for already-admitted conversation
/// entries. These values deliberately contain no route authorization decision,
/// reconciler ticket/owner, parser, compaction, or subagent-correlation state.
public extension ConversationStore {
    enum PersistenceFailure: Error, Equatable {
        case malformed
        case unsupportedVersion
        case oversized
    }

    struct PersistentSnapshot: Codable, Equatable, Sendable {
        public static let schemaVersion = 2
        /// This is a schema envelope cap, not an on-disk retention policy.
        /// Filesystem persistence separately accounts for encoded generations.
        public static let maximumEncodedBytes = 256 << 20

        public let schemaVersion: Int
        public let records: [Record]

        public init(records: [Record]) {
            self.schemaVersion = Self.schemaVersion
            self.records = records
        }

        private init(schemaVersion: Int, records: [Record]) {
            self.schemaVersion = schemaVersion
            self.records = records
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, records }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard [1,Self.schemaVersion].contains(schemaVersion) else { throw PersistenceFailure.unsupportedVersion }
            var values = try container.nestedUnkeyedContainer(forKey: .records)
            var decoded: [Record] = []
            decoded.reserveCapacity(256)
            while !values.isAtEnd {
                guard decoded.count < 256 else { throw PersistenceFailure.oversized }
                decoded.append(try values.decode(Record.self))
            }
            if schemaVersion == 1 {
                guard decoded.allSatisfy({ $0.key.origin == nil && $0.context.hc == nil }) else { throw PersistenceFailure.malformed }
            }
            records = decoded
        }

        public struct Record: Codable, Equatable, Sendable {
            /// A prior live ID is retained for deterministic import reporting;
            /// restore creates new live IDs under a new epoch.
            public let id: String
            public let key: Key
            public let context: Context
            /// Monotonic update order only. It is not restored as a live cursor.
            public let updatedOrder: UInt64
            public let items: [Item]
            public let truncated: Bool
            public let status: String
            public let subagents: Subagents

            public init(id: String, key: Key, context: Context, updatedOrder: UInt64,
                        items: [Item], truncated: Bool, status: String, subagents: Subagents) {
                self.id = id; self.key = key; self.context = context; self.updatedOrder = updatedOrder
                self.items = items; self.truncated = truncated; self.status = status; self.subagents = subagents
            }

            private enum CodingKeys: String, CodingKey { case id, key, context, updatedOrder, items, truncated, status, subagents }
            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                key = try container.decode(Key.self, forKey: .key)
                context = try container.decode(Context.self, forKey: .context)
                updatedOrder = try container.decode(UInt64.self, forKey: .updatedOrder)
                var values = try container.nestedUnkeyedContainer(forKey: .items)
                var decoded: [Item] = []
                decoded.reserveCapacity(4_096)
                while !values.isAtEnd {
                    guard decoded.count < 4_096 else { throw PersistenceFailure.oversized }
                    decoded.append(try values.decode(Item.self))
                }
                items = decoded
                truncated = try container.decode(Bool.self, forKey: .truncated)
                status = try container.decode(String.self, forKey: .status)
                subagents = try container.decode(Subagents.self, forKey: .subagents)
            }
        }

        public struct Key: Codable, Equatable, Sendable {
            public let agent: String
            public let herdrSession: String?
            public let origin: ConversationOrigin?
            public let nativeSession: String
            public init(agent: String, herdrSession: String?, nativeSession: String) {
                self.agent = agent; self.herdrSession = herdrSession; origin = nil; self.nativeSession = nativeSession
            }
            public init(agent: String, origin: ConversationOrigin, nativeSession: String) {
                self.agent = agent; herdrSession = nil; self.origin = origin; self.nativeSession = nativeSession
            }
            /// Validated value only; not current route or native authority.
            public var validated: ConversationKey? {
                if let origin {
                    guard herdrSession == nil else { return nil }
                    return ConversationKey(agent:agent,origin:origin,nativeSession:nativeSession)
                }
                guard let herdrSession else { return nil }
                return ConversationKey(agent:agent,herdrSession:herdrSession,nativeSession:nativeSession)
            }
        }

        public struct Context: Codable, Equatable, Sendable {
            public let routeID: String
            public let paneID: String
            public let terminalID: String?
            public let hc: AgentProxyHcRouteState?
            public init(routeID: String, paneID: String, terminalID: String?, hc: AgentProxyHcRouteState? = nil) {
                self.routeID = routeID; self.paneID = paneID; self.terminalID = terminalID; self.hc = hc
            }
            /// Validated value only; caller must recheck current authority.
            public var validated: ConversationContext? {
                if let hc {
                    guard paneID == hc.intent.paneID.uuidString, terminalID == hc.binding?.terminalID else { return nil }
                    return ConversationContext(routeID:routeID,hc:hc)
                }
                guard let terminalID else { return nil }
                return ConversationContext(routeID:routeID,paneID:paneID,terminalID:terminalID)
            }
        }

        public struct Item: Codable, Equatable, Sendable {
            public let id: String
            public let message: Message
            public let origin: Origin
            public let status: String
            public init(id: String, message: Message, origin: Origin, status: String) {
                self.id = id; self.message = message; self.origin = origin; self.status = status
            }
        }

        public struct Message: Codable, Equatable, Sendable {
            public let role: String
            public let blocks: [Block]
            public let truncated: Bool
            public init(role: String, blocks: [Block], truncated: Bool) {
                self.role = role; self.blocks = blocks; self.truncated = truncated
            }

            private enum CodingKeys: String, CodingKey { case role, blocks, truncated }
            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try container.decode(String.self, forKey: .role)
                var values = try container.nestedUnkeyedContainer(forKey: .blocks)
                var decoded: [Block] = []
                decoded.reserveCapacity(64)
                while !values.isAtEnd {
                    guard decoded.count < 64 else { throw PersistenceFailure.oversized }
                    decoded.append(try values.decode(Block.self))
                }
                blocks = decoded
                truncated = try container.decode(Bool.self, forKey: .truncated)
            }
        }

        public struct Block: Codable, Equatable, Sendable {
            public let kind: String
            public let text: String
            public let callID: String?
            public let toolName: String?
            public init(kind: String, text: String, callID: String?, toolName: String?) {
                self.kind = kind; self.text = text; self.callID = callID; self.toolName = toolName
            }
        }

        /// `kind` is one of reconstructed, observed, response, summary,
        /// discontinuity, compaction, or subagent. The optional fields are
        /// required only by their respective tagged variants.
        public struct Origin: Codable, Equatable, Sendable {
            public let kind: String
            public let compactionAvailability: String?
            public let subagentID: String?
            public let subagentDepth: Int?
            public init(kind: String, compactionAvailability: String? = nil,
                        subagentID: String? = nil, subagentDepth: Int? = nil) {
                self.kind = kind; self.compactionAvailability = compactionAvailability
                self.subagentID = subagentID; self.subagentDepth = subagentDepth
            }
        }

        public struct Subagents: Codable, Equatable, Sendable {
            public let observed: Int
            public let withFinalResult: Int
            public let limited: Bool
            public let linkAvailable: Bool
            public let ancestryIncomplete: Bool
            public init(observed: Int, withFinalResult: Int, limited: Bool,
                        linkAvailable: Bool, ancestryIncomplete: Bool) {
                self.observed = observed; self.withFinalResult = withFinalResult; self.limited = limited
                self.linkAvailable = linkAvailable; self.ancestryIncomplete = ancestryIncomplete
            }
        }

        /// Decode only a bounded v1 envelope. Per-record admission is performed
        /// by `ConversationStore.restore`, using the same validation as upsert.
        public static func decode(_ data: Data, maximumBytes: Int = PersistentSnapshot.maximumEncodedBytes) throws -> Self {
            guard maximumBytes >= 0, maximumBytes <= Self.maximumEncodedBytes, data.count <= maximumBytes else {
                throw PersistenceFailure.oversized
            }
            let decoded: Self
            do { decoded = try JSONDecoder().decode(Self.self, from: data) }
            catch let failure as PersistenceFailure { throw failure }
            catch { throw PersistenceFailure.malformed }
            try decoded.validateEnvelope()
            return decoded
        }

        public func encoded(maximumBytes: Int = PersistentSnapshot.maximumEncodedBytes) throws -> Data {
            guard maximumBytes >= 0, maximumBytes <= Self.maximumEncodedBytes else { throw PersistenceFailure.oversized }
            try validateEnvelope()
            let data: Data
            do { data = try JSONEncoder().encode(self) }
            catch { throw PersistenceFailure.malformed }
            guard data.count <= maximumBytes else { throw PersistenceFailure.oversized }
            return data
        }

        func validateEnvelope() throws {
            guard [1,Self.schemaVersion].contains(schemaVersion) else { throw PersistenceFailure.unsupportedVersion }
            if schemaVersion == 1 {
                guard records.allSatisfy({ $0.key.origin == nil && $0.context.hc == nil }) else { throw PersistenceFailure.malformed }
            }
            guard records.count <= 256,
                  records.allSatisfy({ $0.items.count <= 4_096 && $0.items.allSatisfy { $0.message.blocks.count <= 64 } }) else {
                throw PersistenceFailure.oversized
            }
        }
    }

    struct RestoreResult: Equatable, Sendable {
        /// UTF-8-byte-exact mapping from a validated persistent ID to its
        /// freshly allocated live ID. Callers must not treat a prior
        /// epoch/cursor as still valid.
        public let restoredIDs: [Data: String]
        /// Only syntactically safe identifiers are returned; malformed IDs are
        /// counted without reflecting untrusted bytes back to a caller. Values
        /// use the same byte-exact identity domain as `restoredIDs`.
        public let rejectedPersistentIDs: [Data]
        public let rejectedRecordCount: Int
        public let evictedPersistentIDs: [Data]
    }
}
