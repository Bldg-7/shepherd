import Foundation
import Darwin
import AgentProxyProtocol
import AgentProxyCore

/// Reads tee frames from descriptor 3 into bounded normalized capture. Socket
/// mode can schedule normalized records to the journal when a state directory
/// is supplied; it never logs raw tee bodies. Exits on EOF or malformed framing.
public enum AgentProxyRecorder {
    /// The executable enters the dedicated storage-owner role, never a second
    /// recorder-side journal writer. All paths are explicit and local.
    public static func storageOwner(stateDirectory: String, descriptor: Int32, producerDescriptor: Int32) -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, args[0] == "storage-owner", args[1] == "--state-dir", args[2] == stateDirectory,
              args[3] == "--producer-fd", args[4] == "4", stateDirectory.hasPrefix("/"), descriptor == 3, producerDescriptor == 4 else { return 4 }
        return ConversationStorageOwner.run(stateDirectory: stateDirectory, descriptor: descriptor, producerDescriptor: producerDescriptor)
    }

    /// Same owner implementation in explicitly confirmed OFF maintenance mode.
    public static func storageOwnerMaintenance(stateDirectory: String, socketPath: String) -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 7, args[0] == "storage-owner", args[1] == "--maintenance-clear", args[2] == "--confirmed",
              args[3] == "--state-dir", args[4] == stateDirectory, args[5] == "--socket", args[6] == socketPath,
              stateDirectory.hasPrefix("/"), AgentProxyPaths.socketPathFits(socketPath) else { return 4 }
        return ConversationStorageOwner.runMaintenance(stateDirectory: stateDirectory, socketPath: socketPath)
    }

    public static func run(descriptor: Int32 = 3, socketPath: String? = nil, stateDirectory: String? = nil,
                           inheritedProducerDescriptor: Int32? = nil) -> Int32 {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return 2 }
        if let socketPath { return ConversationSocket.run(descriptor: descriptor, path: socketPath, stateDirectory: stateDirectory, inheritedProducerDescriptor: inheritedProducerDescriptor) }
        var decoder = AgentProxyTeeFrame.Decoder()
        let capture = ConversationCapture(makeDecoder: AgentProxyBodyDecoder.make)
        defer { capture.finishAll() }
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return 0 }
            decoder.append(chunk[0..<count])
            do {
                while let frame = try decoder.next() {
                    capture.consume(frame)
                }
            } catch {
                return 3
            }
        }
    }
}
