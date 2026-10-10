import Foundation
import Security
import CryptoKit

// App-internal capabilities. Only handle/status/error DTOs cross the agent boundary.
nonisolated enum CredentialBrokerError: String, Error, Sendable {
    case denied, unavailable, expired, invalidElement, invalidRequest, unsupported, capacity, consumed, cancelled
}
nonisolated struct CredentialOwner: Hashable, Sendable {
    let machineID: String
    let herdrMachineID: String
    let session: String
    let paneID: String
    let terminalID: String
    let agentGeneration: UInt64
    let profileID: String
}
nonisolated struct CredentialHandle: Hashable, Sendable, Codable { let opaqueID: String }
nonisolated struct CredentialBindingID: Hashable, Sendable { let opaqueID: String }
nonisolated struct CredentialRequestTicket: Hashable, Sendable { let opaqueID: String }
nonisolated enum CredentialState: String, Sendable, Codable {
    case approved, bound, authorized, consumed, revoked, expired, failed
}
nonisolated struct CredentialDestination: Equatable, Sendable {
    let scheme: String
    let host: String
    let effectivePort: Int
    let path: String
    let query: String?
    let method: String
    let mediaType: String
    let field: String

    // Deliberately narrow canonical subset; encoded paths/IDNs/IPv6 are unsupported,
    // rather than interpreted differently by Foundation, Chromium and upstream.
    init(url: String, method: String = "POST", mediaType: String = "application/x-www-form-urlencoded", field: String) throws {
        guard let c = URLComponents(string: url), c.scheme == "https", c.user == nil,
              c.password == nil, c.fragment == nil, let host = c.host, !host.isEmpty,
              host == host.lowercased(), host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              Self.canonicalHost(host),
              (1...65535).contains(c.port ?? 443), c.percentEncodedPath == c.path,
              c.path.hasPrefix("/"), !c.path.contains("//"),
              !c.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              c.path.utf8.allSatisfy({ $0 >= 33 && $0 < 127 && $0 != 92 }),
              c.percentEncodedQuery == c.query,
              c.query?.utf8.allSatisfy({ $0 >= 33 && $0 < 127 && $0 != 92 }) ?? true,
              method == "POST", mediaType == "application/x-www-form-urlencoded",
              !field.isEmpty, field.utf8.count <= 128, field.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw CredentialBrokerError.unsupported }
        // Reject authority normalization (e.g. backslashes or alternate port spelling).
        let authority = host + (c.port.map { ":\($0)" } ?? "")
        guard url == "https://" + authority + c.path + (c.query.map { "?" + $0 } ?? "") else {
            throw CredentialBrokerError.unsupported
        }
        self.scheme = "https"; self.host = host; effectivePort = c.port ?? 443
        path = c.path; query = c.query; self.method = method; self.mediaType = mediaType; self.field = field
    }
    private static func canonicalHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return false }
        let numeric = labels.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }
        if numeric {
            return labels.count == 4 && labels.allSatisfy { label in
                guard let value = Int(label), value <= 255 else { return false }
                return String(value) == label
            }
        }
        // Prevent Chromium's legacy decimal/octal/hex IPv4 interpretations.
        guard let last = labels.last, last.utf8.count >= 2 else { return false }
        return last.utf8.allSatisfy { (97...122).contains($0) }
    }
}
nonisolated struct CredentialBindInput: Sendable {
    let handle: CredentialHandle
    let pageID: String
    let frameID: String
    let backendNodeID: Int
    let requestField: String
    let destinationProposal: CredentialDestination
}
nonisolated struct TrustedElementSnapshot: Equatable, Sendable {
    let owner: CredentialOwner
    let engineGeneration: UInt64
    let browserID: String
    let pageID: String
    let frameID: String
    let documentGeneration: UInt64
    let executionContextGeneration: UInt64
    let backendNodeID: Int
    let origin: String
    let connected: Bool
    let inputType: String
    let name: String
    let formDestination: CredentialDestination
    let ordinaryForm: Bool
    let value: String
}
nonisolated struct CredentialBinding: Sendable {
    let id: CredentialBindingID
    let input: CredentialBindInput
    let snapshot: TrustedElementSnapshot
}
nonisolated protocol CredentialElementInspecting: Sendable {
    func snapshot(_ input: CredentialBindInput, owner: CredentialOwner) async throws -> TrustedElementSnapshot
    func revalidate(_ binding: CredentialBinding) async throws -> TrustedElementSnapshot
}
nonisolated protocol CredentialMonotonicClock: Sendable { func nowNanoseconds() -> UInt64 }
nonisolated struct CredentialSystemClock: CredentialMonotonicClock {
    func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
// NSLock supports the deployment target. This one-way lease never awaits or
// performs provider I/O under its lock; only bounded synchronous enqueue commits.
nonisolated final class CredentialRevocationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func revoke() { lock.withLock { valid = false } }
    func withCommit(_ commit: () throws -> Void) throws {
        try lock.withLock {
            guard valid else { throw CredentialBrokerError.cancelled }
            try commit()
        }
    }
}
nonisolated struct TrustedCredentialProviderLease: Sendable {
    let epoch: UInt64
    let providerID: PasswordManagerProviderID
    let accountID: String
    let resolver: any TrustedPasswordResolving
    var revocation = CredentialRevocationLease()
}
// Only trusted UI supplies this; deliberately not Codable or part of agent protocol.
nonisolated struct HumanCredentialGrant: Sendable {
    let reference: ApprovedPasswordReference
    let destination: CredentialDestination
    let owner: CredentialOwner
    let providerEpoch: UInt64
    let lifetimeNanoseconds: UInt64
}
// Constructed by native bridge, never decoded from agent/page JSON. Native caller
// must map the actual SHBPage/frame/document, not page-supplied claims or headers.
nonisolated struct NativeCredentialRequestEvidence: Sendable {
    let owner: CredentialOwner
    let bindingID: CredentialBindingID
    let snapshot: TrustedElementSnapshot
    let requestID: String
    let destination: CredentialDestination
    let bodyDigest: Data
    static func digest(_ body: Data) -> Data { Data(SHA256.hash(data: body)) }
}
nonisolated struct CredentialObservedRequest: Sendable {
    let destination: CredentialDestination
    let body: Data
}
// The proxy carries this nonsecret authority to its event loop. Provider and
// per-grant revocation use a fixed lock order, with no await, provider access or
// blocking I/O. The nonblocking channel-pipeline write is the commit boundary.
nonisolated struct CredentialWriteAuthorization: Sendable {
    private let provider: CredentialRevocationLease?
    private let grant: CredentialRevocationLease?
    private let clock: any CredentialMonotonicClock
    private let deadline: UInt64?

    init(provider: CredentialRevocationLease? = nil, grant: CredentialRevocationLease? = nil,
         clock: any CredentialMonotonicClock = CredentialSystemClock(), deadline: UInt64? = nil) {
        self.provider = provider; self.grant = grant; self.clock = clock; self.deadline = deadline
    }
    func withCommit(_ commit: () throws -> Void) throws {
        func checkDeadline() throws {
            if let deadline, clock.nowNanoseconds() >= deadline { throw CredentialBrokerError.expired }
            try commit()
        }
        func checkGrant() throws {
            if let grant { try grant.withCommit(checkDeadline) }
            else { try checkDeadline() }
        }
        if let provider { try provider.withCommit(checkGrant) }
        else { try checkGrant() }
    }
}
// Private storage, no raw getter/String/description/serialization. Only the
// app-owned external HTTPS transport receives this after atomic consumption.
nonisolated struct CredentialSecretLease: ~Copyable, Sendable {
    private var bytes: Data
    let authorization: CredentialWriteAuthorization
    init(_ bytes: Data, revocation: CredentialRevocationLease? = nil) {
        self.bytes = bytes; authorization = CredentialWriteAuthorization(provider: revocation)
    }
    init(_ bytes: Data, authorization: CredentialWriteAuthorization) {
        self.bytes = bytes; self.authorization = authorization
    }
    consuming func consumeForTransport(_ write: (Data) throws -> Void) throws {
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        try authorization.withCommit { try write(bytes) }
    }
}
nonisolated protocol CredentialSecretTransport: Sendable {
    // Synchronously enqueue the owned write. A transport that queues onto its
    // event loop MUST recheck secret.authorization at the actual pipeline write.
    // No redirects/retry; strip provenance.
    func beginWrite(_ secret: consuming CredentialSecretLease, request: CredentialObservedRequest) throws
}
nonisolated protocol CredentialAgentOperating: Sendable {
    func bind(_ input: CredentialBindInput, owner: CredentialOwner) async throws -> CredentialBindingID
    func status(_ handle: CredentialHandle, owner: CredentialOwner) async throws -> CredentialState
    func cancel(_ handle: CredentialHandle, owner: CredentialOwner) async throws
}
nonisolated protocol CredentialProxyConsuming: Sendable {
    func consumeRequest(_ ticket: CredentialRequestTicket, observed: CredentialObservedRequest,
                        transport: any CredentialSecretTransport) async throws
}

nonisolated func credentialOpaqueID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw CredentialBrokerError.unavailable
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

// Strict ordinary form parser. No substring replacement, duplicate keys, files,
// JSON or malformed/ambiguous percent encoding. Shared with proxy lane.
nonisolated enum CredentialForm {
    static func fields(_ body: Data) throws -> [(String, String)] {
        guard !body.isEmpty, body.count <= 65536, let text = String(data: body, encoding: .utf8) else { throw CredentialBrokerError.unsupported }
        func decode(_ s: Substring) throws -> String {
            let b = Array(s.utf8); var result = [UInt8](); var i = 0
            func hex(_ v: UInt8) -> UInt8? {
                switch v { case 48...57: return v - 48; case 65...70: return v - 55; case 97...102: return v - 87; default: return nil }
            }
            while i < b.count {
                if b[i] == 37 {
                    guard i + 2 < b.count, let a = hex(b[i+1]), let c = hex(b[i+2]) else { throw CredentialBrokerError.invalidRequest }
                    result.append(a * 16 + c); i += 3
                } else {
                    guard b[i] >= 33 && b[i] < 127 else { throw CredentialBrokerError.invalidRequest }
                    result.append(b[i] == 43 ? 32 : b[i]); i += 1
                }
            }
            guard !result.contains(0), let value = String(bytes: result, encoding: .utf8) else { throw CredentialBrokerError.invalidRequest }
            return value
        }
        var seen = Set<String>(); var result = [(String, String)]()
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CredentialBrokerError.invalidRequest }
            let name = try decode(parts[0]); let value = try decode(parts[1])
            guard !name.isEmpty, seen.insert(name).inserted else { throw CredentialBrokerError.invalidRequest }
            result.append((name, value))
        }
        return result
    }
}
