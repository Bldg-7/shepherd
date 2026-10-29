import Foundation
import Darwin
import AgentProxyProtocol
import AgentProxyCore

/// Reads tee frames from descriptor 3 into bounded normalized capture. Socket
/// mode can schedule normalized records to the database when a state directory
/// is supplied; it never logs raw tee bodies. Exits on EOF or malformed framing.
public enum AgentProxyRecorder {
    /// Confirmed OFF maintenance: with capture off no recorder is running, so
    /// take producer and socket admission, then remove the conversation
    /// database. Exits 0 on success, 5 if removal failed, 4 if admission did.
    public static func clearHistory(stateDirectory: String, socketPath: String) -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, args[0] == "clear-history", args[1] == "--confirmed",
              args[2] == "--state-dir", args[3] == stateDirectory, args[4] == "--socket", args[5] == socketPath,
              stateDirectory.hasPrefix("/"), AgentProxyPaths.socketPathFits(socketPath) else { return 4 }
        do {
            try ConversationStateRoot.prepare(stateDirectory)
            let producer = try ConversationProducerLease(rootPath: stateDirectory)
            let socketLease = try SocketLease(socketPath, removeStale: false)
            return withExtendedLifetime((producer, socketLease)) {
                do {
                    try producer.verify(); try socketLease.verifyLock()
                    try ConversationDatabase.removeAll(stateDirectory: stateDirectory)
                    try producer.verify()
                    return 0
                } catch { return 5 }
            }
        } catch { return 4 }
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
