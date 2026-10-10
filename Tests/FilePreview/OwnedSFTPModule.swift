// TEST ONLY: no sockets, shell API, network, or vendor credentials.
import Foundation

public struct OwnedAuth: Sendable { public init() {} }
public protocol OwnedValidator: Sendable { var pinnedFingerprint: String? { get } }
public enum SSHHostKeyValidator: Sendable { case custom(any OwnedValidator) }
public struct OwnedTime: Sendable { public static func seconds(_ n: Int) -> Self { .init() } }
public struct SSHClientSettings: Sendable {
    public let host: String
    public let port: Int
    public let authenticationMethod: @Sendable () -> OwnedAuth
    public let hostKeyValidator: SSHHostKeyValidator
    public var connectTimeout = OwnedTime.seconds(30)
    public init(host: String, port: Int, authenticationMethod: @escaping @Sendable () -> OwnedAuth, hostKeyValidator: SSHHostKeyValidator) {
        self.host = host; self.port = port; self.authenticationMethod = authenticationMethod; self.hostKeyValidator = hostKeyValidator
    }
}
public struct OwnedAttrs: Sendable { public var size: UInt64?; public var permissions: UInt32? }
public struct OwnedBuffer: Sendable { public let readableBytesView: [UInt8]; public var readableBytes: Int { readableBytesView.count } }
public struct OwnedFlags: Sendable { public let rawValue: Int; public static let read = Self(rawValue: 1) }
public actor OwnedSFTP {
    public static let shared = OwnedSFTP()
    public var bytes: [UInt8] = []
    public var mode: UInt32? = 0o100600
    public var claimedSize: UInt64? = 0
    public var oversizeReply = false
    public var holdConnect = false
    public var holdRead = false
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var readContinuation: CheckedContinuation<Void, Error>?
    public private(set) var connects = 0
    public private(set) var closes = 0
    public private(set) var fileCloses = 0
    public private(set) var sftpCloses = 0
    public private(set) var opens = 0
    public private(set) var paths: [String] = []
    public private(set) var lengths: [UInt32] = []
    public private(set) var hosts: [String] = []
    public private(set) var pins: [String?] = []
    public var waitingConnect: Bool { connectContinuation != nil }
    public var waitingRead: Bool { readContinuation != nil }
    public func plan(_ bytes: [UInt8] = [], mode: UInt32? = 0o100600, size: UInt64? = nil, oversize: Bool = false, heldConnect: Bool = false, heldRead: Bool = false) {
        self.bytes = bytes; self.mode = mode; claimedSize = size ?? UInt64(bytes.count)
        oversizeReply = oversize; holdConnect = heldConnect; holdRead = heldRead
        connects = 0; closes = 0; opens = 0; paths = []; lengths = []; hosts = []; pins = []; fileCloses = 0; sftpCloses = 0
    }
    public func connect(_ settings: SSHClientSettings) async {
        connects += 1; hosts.append(settings.host)
        if case .custom(let validator) = settings.hostKeyValidator { pins.append(validator.pinnedFingerprint) }
        if holdConnect { await withCheckedContinuation { connectContinuation = $0 } }
    }
    public func releaseConnect() { connectContinuation?.resume(); connectContinuation = nil }
    public func close() {
        closes += 1
        readContinuation?.resume(throwing: CancellationError()); readContinuation = nil
    }
    public func attributes(_ path: String) -> OwnedAttrs { paths.append(path); return OwnedAttrs(size: claimedSize, permissions: mode) }
    public func open(_ path: String, flags: OwnedFlags) { precondition(flags.rawValue == 1); paths.append(path); opens += 1 }
    public func read(_ offset: UInt64, length: UInt32) async throws -> OwnedBuffer {
        lengths.append(length)
        if holdRead { try await withCheckedThrowingContinuation { readContinuation = $0 } }
        if oversizeReply { return OwnedBuffer(readableBytesView: Array(repeating: 65, count: Int(length) + 1)) }
        return OwnedBuffer(readableBytesView: Array(bytes.dropFirst(Int(offset)).prefix(Int(length))))
    }
    public func closeFile() { fileCloses += 1 }
    public func closeSFTP() { sftpCloses += 1 }
}
public final class SSHClient: @unchecked Sendable {
    public static func connect(to settings: SSHClientSettings) async throws -> SSHClient { await OwnedSFTP.shared.connect(settings); return .init() }
    public func close() async throws { await OwnedSFTP.shared.close() }
    public func openSFTP() async throws -> OwnedSFTPClient { .init() }
}
public final class OwnedSFTPClient: Sendable {
    public func getAttributes(at path: String) async throws -> OwnedAttrs { await OwnedSFTP.shared.attributes(path) }
    public func openFile(filePath: String, flags: OwnedFlags) async throws -> OwnedFile { await OwnedSFTP.shared.open(filePath, flags: flags); return OwnedFile(path: filePath) }
    public func close() async throws { await OwnedSFTP.shared.closeSFTP() }
}
public final class OwnedFile: Sendable {
    private let path: String
    init(path: String) { self.path = path }
    public func readAttributes() async throws -> OwnedAttrs { await OwnedSFTP.shared.attributes(path) }
    public func read(from offset: UInt64, length: UInt32) async throws -> OwnedBuffer { try await OwnedSFTP.shared.read(offset, length: length) }
    public func close() async throws { await OwnedSFTP.shared.closeFile() }
}
