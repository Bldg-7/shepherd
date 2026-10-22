import Foundation
import Darwin
import AgentProxyProtocol

/// The recorder, as far as this stage goes: it reads the forwarder's frames
/// from descriptor 3, checks that they are well formed, and lets them go.
/// Putting the conversations together and answering on `ac.sock` come in
/// stage 2. It keeps nothing, writes nothing and prints nothing; it exits
/// when the forwarder closes its end (or exits), and with an error on a
/// malformed frame, after which the forwarder starts a new one.
public enum AgentProxyRecorder {
    public static func run(descriptor: Int32 = 3) -> Int32 {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return 2 }
        var decoder = AgentProxyTeeFrame.Decoder()
        var open = Set<UInt64>()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return 0 }
            decoder.append(chunk[0..<count])
            do {
                while let frame = try decoder.next() {
                    switch frame.kind {
                    case .open: open.insert(frame.exchange)
                    case .end: open.remove(frame.exchange)
                    default: break
                    }
                }
            } catch {
                return 3
            }
        }
    }
}
