#if os(macOS)
import Foundation
import CoreFoundation
import Darwin

nonisolated struct CredentialRoute: Sendable {
    let paneRoute: CDPRoute
    init?(_ path: String) {
        guard path.hasPrefix("/v1/"), path.hasSuffix("/credential"),
              let route = CDPRoute(String(path.dropLast("/credential".count))) else { return nil }
        paneRoute = route
    }
}

/// Integration owns lifecycle admission. An absent service is never browser Ready.
@MainActor final class CredentialCLIService {
    private struct Lease {
        let owner: CredentialOwner
        let file: URL
        var handles = Set<CredentialHandle>()
        var pending = 0
    }
    private let broker: CredentialBroker
    private let admit: (CredentialOwner, CDPRoute) -> Bool
    private var leases: [String: Lease] = [:]
    init(broker: CredentialBroker, admit: @escaping (CredentialOwner, CDPRoute) -> Bool) {
        self.broker = broker; self.admit = admit
    }

    /// Call only for a resolved local active agent lease. Descriptor stores the
    /// path, not bytes; integration deletes it and awaits revoke on agent exit.
    func provision(owner: CredentialOwner, directory: URL) throws -> URL {
        guard leases.count < 128 else { throw CredentialBrokerError.capacity }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw CredentialBrokerError.denied }
        let capability = try credentialOpaqueID()
        let file = directory.appendingPathComponent("credential-" + UUID().uuidString)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CredentialBrokerError.unavailable }
        defer { close(fd) }
        let bytes = Array(capability.utf8)
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { try? FileManager.default.removeItem(at: file); throw CredentialBrokerError.unavailable }
        leases[capability] = Lease(owner: owner, file: file)
        return file
    }

    func revoke(owner: CredentialOwner) async {
        for (key, lease) in leases where lease.owner == owner {
            leases[key] = nil; try? FileManager.default.removeItem(at: lease.file)
        }
        await broker.revoke(owner: owner)
    }

    /// Only the trusted grant view calls this after broker creation. No public
    /// request can register an item or discover another owner's handles.
    func registerApproved(_ handle: CredentialHandle, owner: CredentialOwner) throws {
        guard let key = leases.first(where: { $0.value.owner == owner })?.key,
              leases[key]!.handles.count < 128 else { throw CredentialBrokerError.unavailable }
        leases[key]!.handles.insert(handle)
    }

    func authenticated(_ route: CredentialRoute, headers: [String]) -> Bool {
        guard headers.count == 1, let lease = leases[headers[0]],
              lease.owner.session == route.paneRoute.session,
              lease.owner.paneID == route.paneRoute.pane else { return false }
        return admit(lease.owner, route.paneRoute)
    }

    func receive(_ route: CredentialRoute, headers: [String], text: String) async -> String {
        guard authenticated(route, headers: headers), let key = headers.first,
              var lease = leases[key], lease.pending < 8 else { return response(["error":"denied"]) }
        lease.pending += 1; leases[key] = lease
        defer { if leases[key] != nil { leases[key]!.pending -= 1 } }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let expiry = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.leases[key] != nil else { return }
                await self.revoke(owner: lease.owner)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: expiry)
        defer { expiry.cancel() }
        do {
            guard text.utf8.count <= 16384, let data = text.data(using: .utf8),
                  let command = try Self.flatObject(data)["command"] as? String else { throw CredentialBrokerError.invalidRequest }
            let dto = try Self.flatObject(data)
            func exact(_ keys: Set<String>) throws {
                guard Set(dto.keys) == keys.union(["command"]) else { throw CredentialBrokerError.invalidRequest }
            }
            var result: [String: Any]
            if command == "list-approved-handles" {
                try exact([])
                var handles: [String] = []
                for handle in lease.handles {
                    if let state = try? await broker.status(handle, owner: lease.owner), state == .approved || state == .bound { handles.append(handle.opaqueID) }
                }
                result = ["handles":handles.sorted()]
            } else {
                guard let id = dto["handle"] as? String, id.count == 64,
                      id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CredentialBrokerError.invalidRequest }
                let handle = CredentialHandle(opaqueID: id)
                guard lease.handles.contains(handle) else { throw CredentialBrokerError.denied }
                switch command {
                case "bind":
                    try exact(["handle","pageID","frameID","backendNodeID","requestField","destination"])
                    func string(_ key: String) throws -> String {
                        guard let value = dto[key] as? String, !value.isEmpty, value.utf8.count <= 2048,
                              !value.unicodeScalars.contains(where: { $0.value < 32 }) else { throw CredentialBrokerError.invalidRequest }
                        return value
                    }
                    guard let number = dto["backendNodeID"] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue), number.intValue > 0 else { throw CredentialBrokerError.invalidRequest }
                    let field = try string("requestField")
                    let destination = try CredentialDestination(url: string("destination"), field: field)
                    _ = try await broker.bind(CredentialBindInput(handle: handle, pageID: string("pageID"), frameID: string("frameID"), backendNodeID: number.intValue, requestField: field, destinationProposal: destination), owner: lease.owner)
                    result = ["state":"bound"]
                case "status":
                    try exact(["handle"])
                    result = ["state":try await broker.status(handle, owner: lease.owner).rawValue]
                case "unbind":
                    try exact(["handle"])
                    try await broker.cancel(handle, owner: lease.owner)
                    result = ["state":"revoked"]
                default: throw CredentialBrokerError.denied
                }
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline, authenticated(route, headers: headers) else {
                await broker.revoke(owner: lease.owner); throw CredentialBrokerError.denied
            }
            return response(result)
        } catch {
            return response(["error":(error as? CredentialBrokerError)?.rawValue ?? "invalidRequest"])
        }
    }
    /// This public schema is flat: reject duplicate keys and nested values
    /// rather than relying on JSONSerialization's last-key-wins behavior.
    nonisolated static func flatObject(_ data: Data) throws -> [String: Any] {
        let bytes = Array(data); var index = 0
        func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        func stringToken() throws -> Data {
            guard index < bytes.count, bytes[index] == 34 else { throw CredentialBrokerError.invalidRequest }
            let start = index; index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return Data(bytes[start..<index]) }
                if byte == 92 { guard index < bytes.count else { break }; index += 1 }
            }
            throw CredentialBrokerError.invalidRequest
        }
        whitespace(); guard index < bytes.count, bytes[index] == 123 else { throw CredentialBrokerError.invalidRequest }; index += 1
        whitespace(); var result: [String: Any] = [:]
        if index < bytes.count, bytes[index] == 125 { index += 1; whitespace(); guard index == bytes.count else { throw CredentialBrokerError.invalidRequest }; return result }
        while index < bytes.count {
            let keyData = try stringToken()
            guard let key = try JSONSerialization.jsonObject(with:keyData,options:.fragmentsAllowed) as? String,
                  result[key] == nil else { throw CredentialBrokerError.invalidRequest }
            whitespace(); guard index < bytes.count, bytes[index] == 58 else { throw CredentialBrokerError.invalidRequest }; index += 1; whitespace()
            let token: Data
            if index < bytes.count, bytes[index] == 34 { token = try stringToken() }
            else {
                let start = index
                while index < bytes.count, ![9,10,13,32,44,125].contains(bytes[index]) { index += 1 }
                token = Data(bytes[start..<index])
            }
            let value = try JSONSerialization.jsonObject(with:token,options:.fragmentsAllowed)
            guard value is String || value is NSNumber else { throw CredentialBrokerError.invalidRequest }
            result[key] = value; whitespace()
            guard index < bytes.count else { throw CredentialBrokerError.invalidRequest }
            if bytes[index] == 125 { index += 1; whitespace(); guard index == bytes.count else { throw CredentialBrokerError.invalidRequest }; return result }
            guard bytes[index] == 44 else { throw CredentialBrokerError.invalidRequest }; index += 1; whitespace()
        }
        throw CredentialBrokerError.invalidRequest
    }

    private func response(_ value: [String: Any]) -> String {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return "{\"error\":\"unavailable\"}" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
