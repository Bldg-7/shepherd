import Foundation
import Darwin
import AgentProxyProtocol
import AgentProxyCore

/// Reads tee frames from descriptor 3 into bounded normalized capture. Socket
/// mode can schedule normalized records to the journal when a state directory
/// is supplied; it never logs raw tee bodies. Exits on EOF or malformed framing.
public enum AgentProxyRecorder {
    public static func run(descriptor: Int32 = 3, socketPath: String? = nil, stateDirectory: String? = nil) -> Int32 {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return 2 }
        if let socketPath { return ConversationSocket.run(descriptor: descriptor, path: socketPath, stateDirectory: stateDirectory) }
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
