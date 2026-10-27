import Foundation
import NIOCore
import AgentProxyProtocol

/// The copy of each exchange of a known route, sent to the recorder as
/// `AgentProxyTeeFrame`s. It never holds an exchange up: a frame is written
/// only while the recorder's socket takes it; otherwise that exchange alone
/// is dropped (its `end` says so) and forwarding goes on.
///
/// Used on the proxy's event loop only.
final class Tee {
    private struct Copy {
        var bytes = 0
        var dropped = false
    }

    private var channel: Channel?
    private var copies: [UInt64: Copy] = [:]
    private(set) var dropped = 0

    var isAttached: Bool { channel?.isActive == true }

    func attach(_ channel: Channel) {
        self.channel = channel
        copies.removeAll()
    }

    /// The recorder went away: what it had of the open exchanges is gone.
    func detach(_ channel: Channel) {
        guard self.channel === channel else { return }
        self.channel = nil
        copies.removeAll()
    }

    /// Forget all pre-barrier copies. Later frames for those exchanges are not
    /// sent; newly opened exchanges are ordered after the control frame.
    func fenceExistingCopies() { copies.removeAll() }

    /// Whether the exchange is copied at all.
    @discardableResult
    func open(_ exchange: UInt64, _ open: AgentProxyTeeFrame.Open) -> Bool {
        guard let channel, channel.isActive, channel.isWritable,
              let payload = try? JSONEncoder().encode(open) else { return false }
        copies[exchange] = Copy()
        write(exchange, .open, ByteBuffer(bytes: payload), on: channel)
        return true
    }

    func requestBody(_ exchange: UInt64, _ buffer: ByteBuffer) { body(exchange, .requestBody, buffer) }
    func responseBody(_ exchange: UInt64, _ buffer: ByteBuffer) { body(exchange, .responseBody, buffer) }

    func requestEnd(_ exchange: UInt64) {
        guard let channel = live(exchange) else { return }
        write(exchange, .requestEnd, ByteBuffer(), on: channel)
    }

    func responseHead(_ exchange: UInt64, _ head: AgentProxyTeeFrame.ResponseHead) {
        guard let channel = live(exchange), let payload = try? JSONEncoder().encode(head) else { return }
        write(exchange, .responseHead, ByteBuffer(bytes: payload), on: channel)
    }

    func end(_ exchange: UInt64, _ outcome: AgentProxyTeeFrame.End.Outcome) {
        guard let copy = copies.removeValue(forKey: exchange), let channel, channel.isActive,
              let payload = try? JSONEncoder().encode(AgentProxyTeeFrame.End(outcome: copy.dropped ? .dropped : outcome)) else { return }
        // Small, and the one frame a dropped exchange still gets, so the
        // recorder can let go of what it had of it.
        write(exchange, .end, ByteBuffer(bytes: payload), on: channel)
    }

    private func body(_ exchange: UInt64, _ kind: AgentProxyTeeFrame.Kind, _ buffer: ByteBuffer) {
        guard var channel = live(exchange), buffer.readableBytes > 0 else { return }
        guard copies[exchange]!.bytes + buffer.readableBytes <= AgentProxyTeeFrame.exchangeLimitBytes else { drop(exchange); return }
        copies[exchange]!.bytes += buffer.readableBytes
        var rest = buffer
        while rest.readableBytes > 0 {
            guard let slice = rest.readSlice(length: min(rest.readableBytes, AgentProxyTeeFrame.maximumPayloadBytes)) else { break }
            write(exchange, kind, slice, on: channel)
            guard let next = live(exchange) else { return }
            channel = next
        }
    }

    /// The channel, when this exchange is being copied and the socket takes
    /// more; otherwise the exchange is dropped.
    private func live(_ exchange: UInt64) -> Channel? {
        guard let copy = copies[exchange], !copy.dropped else { return nil }
        guard let channel, channel.isActive, channel.isWritable else { drop(exchange); return nil }
        return channel
    }

    private func drop(_ exchange: UInt64) {
        guard copies[exchange]?.dropped == false else { return }
        copies[exchange]?.dropped = true
        dropped += 1
    }

    private func write(_ exchange: UInt64, _ kind: AgentProxyTeeFrame.Kind, _ payload: ByteBuffer, on channel: Channel) {
        let header = ByteBuffer(bytes: AgentProxyTeeFrame.header(kind: kind, exchange: exchange, payloadCount: payload.readableBytes))
        channel.write(header, promise: nil)
        channel.writeAndFlush(payload, promise: nil)
    }
}
