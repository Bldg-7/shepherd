import Foundation
import Darwin
import AgentProxyCore

/// One socketpair-connected process owns all journal operations. Only bounded,
/// normalized records cross this private inherited channel; wire/provider data,
/// route credentials, and user-supplied paths are never accepted from IPC.
enum ConversationStorageOwner {
    static let maximumMessageBytes = (32 << 20) + (1 << 20)
    static let protocolVersion = 1
    struct Request: Codable {
        enum Operation: String, Codable { case begin, load, save, clear, status }
        let id: UInt64
        let generation: UInt64
        let protocolVersion: Int
        let operation: Operation
        let key: ConversationStore.PersistentSnapshot.Key?
        let record: ConversationStore.PersistentSnapshot.Record?
        let updatedAt: Date?
    }
    struct Reply: Codable {
        enum Outcome: String, Codable { case success, unavailable, partial }
        let id: UInt64
        let generation: UInt64
        let protocolVersion: Int
        let outcome: Outcome
        let record: ConversationStore.PersistentSnapshot.Record?
        let health: String
    }

    /// A distinct verified owner lock prevents two owner processes, including
    /// a replacement after a lost IPC connection, from opening one journal.
    private final class OwnerLease {
        private let root: Int32
        private let lock: Int32
        init(path: String) throws {
            let root = try ConversationPersistenceFiles.openVerifiedStateRoot(path, testControl: nil)
            do { lock = try ConversationPersistenceFiles.openAndLock(named: "owner.lock", in: root, testControl: nil); self.root = root }
            catch { Darwin.close(root); throw error }
        }
        deinit { Darwin.close(lock); Darwin.close(root) }
        func verify() throws {
            try ConversationPersistenceFiles.verifyDirectory(root)
            _ = try ConversationPersistenceFiles.verifyFileBinding(named: "owner.lock", in: root, descriptor: lock, maximumBytes: 0, exactSize: 0)
        }
    }

    /// The same owner role is started with explicit paths for OFF maintenance.
    /// It must acquire root-wide admission before the journal can be opened.
    static func runMaintenance(stateDirectory: String, socketPath: String) -> Int32 {
        do {
            try ConversationPersistenceFiles.prepareOwnerStateRoot(stateDirectory)
            let producer = try ConversationProducerLease(rootPath: stateDirectory)
            let owner = try OwnerLease(path: stateDirectory)
            let socketLease = try SocketLease(socketPath, removeStale: false)
            return try withExtendedLifetime((producer, owner, socketLease)) {
                try producer.verify(); try owner.verify(); try socketLease.verifyLock()
                let files = try ConversationPersistenceFiles(verifiedStateRootPath: stateDirectory)
                let journal = ConversationPersistenceJournal(files: files)
                let request = Request(id: 1, generation: 1, protocolVersion: protocolVersion, operation: .clear, key: nil, record: nil, updatedAt: nil)
                do { return try perform(request, journal: journal, producer: producer, owner: owner).outcome == .success ? 0 : 5 }
                catch { return 5 }
            }
        } catch { return 4 }
    }

    /// Runs only in the designated owner process with inherited socketpair
    /// and producer admission. No TCP or pathname listener is created.
    static func run(stateDirectory: String, descriptor: Int32, producerDescriptor: Int32) -> Int32 {
        var socketInfo = stat()
        guard fstat(descriptor, &socketInfo) == 0, socketInfo.st_mode & S_IFMT == S_IFSOCK else { return 4 }
        do {
            let producer = try ConversationProducerLease(rootPath: stateDirectory, inheritedDescriptor: producerDescriptor)
            let owner = try OwnerLease(path: stateDirectory)
            guard let first = try readMessage(descriptor), let begin = try? JSONDecoder().decode(Request.self, from: first),
                  begin.protocolVersion == protocolVersion, begin.id > 0, begin.generation > 0, begin.operation == .begin,
                  begin.key == nil, begin.record == nil, begin.updatedAt == nil else { return 3 }
            try producer.verify(); try owner.verify()
            let files: ConversationPersistenceFiles
            do { files = try ConversationPersistenceFiles(verifiedStateRootPath: stateDirectory) }
            catch {
                let health: String
                if let reason = error as? ConversationPersistenceFilesError {
                    switch reason {
                    case .lockUnavailable, .ioFailure, .retryableOpen(_), .retryableBeforeTemporaryCreation(_): health = "retryable"
                    default: health = "unsafe"
                    }
                } else { health = "unsafe" }
                try writeMessage(try JSONEncoder().encode(Reply(id: begin.id, generation: begin.generation, protocolVersion: protocolVersion,
                    outcome: .unavailable, record: nil, health: health)), descriptor: descriptor)
                return 4
            }
            let journal = ConversationPersistenceJournal(files: files)
            do { try journal.activate() }
            catch {
                let retryable: Bool
                if let reason = error as? ConversationPersistenceJournalError, reason == .unavailable,
                   case .degraded = journal.health { retryable = true } else { retryable = false }
                try writeMessage(try JSONEncoder().encode(Reply(id: begin.id, generation: begin.generation, protocolVersion: protocolVersion,
                    outcome: .unavailable, record: nil, health: retryable ? "retryable" : "unsafe")), descriptor: descriptor)
                return 4
            }
            try writeMessage(try JSONEncoder().encode(try perform(begin, journal: journal, producer: producer, owner: owner)), descriptor: descriptor)
            var previous = begin.id
            var generation = begin.generation
            while let data = try readMessage(descriptor) {
                let request = try JSONDecoder().decode(Request.self, from: data)
                guard request.protocolVersion == protocolVersion, request.id > previous else { return 3 }
                previous = request.id
                if request.operation == .clear {
                    guard generation < UInt64.max, request.generation == generation + 1 else { return 3 }
                    generation = request.generation
                } else {
                    guard request.operation != .begin, request.generation == generation else { return 3 }
                }
                let reply = try perform(request, journal: journal, producer: producer, owner: owner)
                try writeMessage(try JSONEncoder().encode(reply), descriptor: descriptor)
            }
            return 0
        } catch { return 4 }
    }

    /// Every online and maintenance operation reaches the same owner-only
    /// journal dispatch and the same pre/post admission checks.
    private static func perform(_ request: Request, journal: ConversationPersistenceJournal,
                                producer: ConversationProducerLease, owner: OwnerLease) throws -> Reply {
        try producer.verify(); try owner.verify()
        var record: ConversationStore.PersistentSnapshot.Record? = nil
        let outcome: Reply.Outcome
        do {
            switch request.operation {
            case .begin:
                guard request.key == nil, request.record == nil, request.updatedAt == nil else { throw Failure.invalid }
            case .load:
                guard let key = request.key, request.record == nil, request.updatedAt == nil else { throw Failure.invalid }
                record = try journal.firstRecord(matching: key)?.record
            case .save:
                guard request.key == nil, let value = request.record, let updatedAt = request.updatedAt else { throw Failure.invalid }
                try journal.upsert(value, updatedAt: updatedAt)
            case .clear:
                guard request.key == nil, request.record == nil, request.updatedAt == nil else { throw Failure.invalid }
                try journal.clearSupported()
            case .status:
                guard request.key == nil, request.record == nil, request.updatedAt == nil else { throw Failure.invalid }
                // Checks descriptor bindings, index and bounded inventory. It
                // does not assert that every referenced body is readable.
                _ = try journal.metadata()
            }
            outcome = .success
        } catch is Failure { throw Failure.invalid }
        catch { outcome = request.operation == .clear ? .partial : .unavailable }
        try producer.verify(); try owner.verify()
        let health: String
        if outcome != .success { health = "degraded" }
        else { switch journal.health { case .healthy: health = "healthy"; case .degraded: health = "degraded" } }
        return Reply(id: request.id, generation: request.generation, protocolVersion: protocolVersion, outcome: outcome, record: record, health: health)
    }

    static func readMessage(_ descriptor: Int32) throws -> Data? {
        var header = [UInt8](repeating: 0, count: 4)
        let first = try readExactly(descriptor, into: &header, eofAllowed: true)
        guard first else { return nil }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maximumMessageBytes else { throw Failure.invalid }
        // Read directly into one bounded Data allocation; avoid retaining a
        // second full-size byte array beside the decoded response workspace.
        var body = Data(count: size)
        var offset = 0
        while offset < size {
            let remaining = size - offset
            let count = body.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!.advanced(by: offset), remaining) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.invalid }
            offset += count
        }
        return body
    }

    static func writeMessage(_ data: Data, descriptor: Int32) throws {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { throw Failure.invalid }
        let count = UInt32(data.count)
        let header = (0..<4).reversed().map { UInt8(truncatingIfNeeded: count >> UInt32($0 * 8)) }
        try writeAll(Data(header), descriptor: descriptor)
        try writeAll(data, descriptor: descriptor)
    }

    private static func readExactly(_ descriptor: Int32, into bytes: inout [UInt8], eofAllowed: Bool) throws -> Bool {
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!.advanced(by: offset), remaining) }
            if count < 0 && errno == EINTR { continue }
            if count == 0 && offset == 0 && eofAllowed { return false }
            guard count > 0 else { throw Failure.invalid }
            offset += count
        }
        return true
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.invalid }
            offset += count
        }
    }
    enum Failure: Error { case invalid, unavailable, unsafe }
}
