import Foundation
import Darwin
#if canImport(Citadel)
import Citadel
import NIOCore
import NIOConcurrencyHelpers
#endif

/// A reader owns one connection, never a terminal's SSH client. No remote
/// shell commands, temp copies, downloads, or credential persistence.
actor FilePreviewReader {
    private var cancelled = false
    #if canImport(Citadel)
    private var client: SSHClient?
    #endif

    func cancel() async {
        cancelled = true
        #if canImport(Citadel)
        let old = client
        client = nil
        try? await old?.close()
        #endif
    }

    nonisolated static func readLocal(path: String) throws -> Data {
        try Task.checkCancellation()
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw FilePreviewError.notRegularFile }
        guard info.st_size <= FilePreviewDocument.maximumBytes else { throw FilePreviewError.tooLarge }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &bytes, min(bytes.count, FilePreviewDocument.maximumBytes + 1 - data.count))
            if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { return data }
            data.append(contentsOf: bytes.prefix(n))
            guard data.count <= FilePreviewDocument.maximumBytes else { throw FilePreviewError.tooLarge }
        }
    }

    func read(path: String, machine: Machine, secret: Data?) async throws -> Data {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        #if os(macOS)
        if machine.isLocal {
            let task = Task.detached { try Self.readLocal(path: path) }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        #endif
        #if canImport(Citadel)
        guard let pin = machine.pinnedHostKeyFingerprint else { throw FilePreviewError.needsHostKey }
        guard let secret else { throw MachineStore.EditError.missingCredential }
        let auth = try HostCredential(authMethod: machine.authMethod, secretData: secret).authenticationMethod(username: machine.username)
        let observed = NIOLockedValueBox<String?>(nil)
        var settings = SSHClientSettings(host: machine.hostname, port: machine.port,
            authenticationMethod: { auth }, hostKeyValidator: .custom(TOFUHostKeyValidator(pinnedFingerprint: pin, observedFingerprint: observed)))
        settings.connectTimeout = .seconds(10)
        let connection = try await SSHClient.connect(to: settings)
        // An SSH handshake can finish after its owner disappeared. Close the
        // acquired connection rather than resurrecting a cancelled request.
        if cancelled || Task.isCancelled { try? await connection.close(); throw CancellationError() }
        client = connection
        do {
            let sftp = try await connection.openSFTP()
            let initial = try await sftp.getAttributes(at: path)
            guard let mode = initial.permissions, mode & 0o170000 == 0o100000 else { throw FilePreviewError.notRegularFile }
            if let size = initial.size, size > FilePreviewDocument.maximumBytes { throw FilePreviewError.tooLarge }
            let file = try await sftp.openFile(filePath: path, flags: .read)
            let attributes = try await file.readAttributes()
            guard let permissions = attributes.permissions, permissions & 0o170000 == 0o100000 else {
                throw FilePreviewError.notRegularFile
            }
            if let size = attributes.size, size > FilePreviewDocument.maximumBytes { throw FilePreviewError.tooLarge }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                let length = min(65536, FilePreviewDocument.maximumBytes + 1 - data.count)
                let chunk = try await file.read(from: UInt64(data.count), length: UInt32(length))
                guard chunk.readableBytes <= length else { throw FilePreviewError.tooLarge }
                if chunk.readableBytes == 0 { break }
                data.append(contentsOf: chunk.readableBytesView)
                guard data.count <= FilePreviewDocument.maximumBytes else { throw FilePreviewError.tooLarge }
            }
            try await file.close()
            try await sftp.close()
            try await connection.close()
            client = nil
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return data
        } catch {
            try? await connection.close()
            client = nil
            throw error
        }
        #else
        throw FilePreviewError.unsupportedContent
        #endif
    }
}
