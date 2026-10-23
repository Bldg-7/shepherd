import Foundation
import AgentProxyCore
import AgentProxyCompressionC

/// Decoder for copied HTTP bodies only. Does not touch forwarded bytes.
/// Single gzip/zlib/zstd frame, checked checksum, no external dictionaries,
/// no trailing/concatenated frames; zstd window <=8 MiB. Capture rejects any
/// unsupported shape while the independent HTTP exchange continues unchanged.
public final class AgentProxyBodyDecoder: CaptureDecompressor {
    public enum Failure: Error { case invalidStream, closed }
    private let decoder: OpaquePointer
    private var terminal = false

    public static func make(_ encoding: String) -> (any CaptureDecompressor)? {
        let kind: Int32
        switch encoding {
        case "gzip": kind = 1
        case "deflate": kind = 2
        case "zstd": kind = 3
        default: return nil
        }
        guard let state = ap_decoder_create(kind) else { return nil }
        return AgentProxyBodyDecoder(state)
    }
    private init(_ decoder: OpaquePointer) { self.decoder = decoder }
    deinit { ap_decoder_free(decoder) }

    public func append(_ bytes: Data, emit: (Data) throws -> Void) throws {
        guard !terminal else { throw Failure.closed }
        do {
            try bytes.withUnsafeBytes { input in
                var offset = 0
                var output = [UInt8](repeating: 0, count: 64 << 10)
                while true {
                    var consumed = input.count - offset
                    var produced = output.count
                    let status = output.withUnsafeMutableBufferPointer { target in
                        ap_decoder_step(decoder, input.bindMemory(to: UInt8.self).baseAddress?.advanced(by: offset),
                                        &consumed, target.baseAddress, &produced)
                    }
                    guard status >= 0 else { throw Failure.invalidStream }
                    offset += consumed
                    if produced > 0 { try emit(Data(output.prefix(produced))) }
                    if status == 1 { break }
                    if offset == input.count && produced < output.count { break }
                    guard consumed > 0 || produced > 0 else { throw Failure.invalidStream }
                }
            }
        } catch { terminal = true; throw error }
    }
    public func finish(emit: (Data) throws -> Void) throws {
        guard !terminal else { throw Failure.closed }
        defer { terminal = true }
        try append(Data(), emit: emit)
        guard ap_decoder_complete(decoder) != 0 else { throw Failure.invalidStream }
    }
}
