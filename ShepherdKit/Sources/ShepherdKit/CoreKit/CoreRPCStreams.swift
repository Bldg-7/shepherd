import Foundation

extension CoreRPCConnection {
    /// Only this entry point can open channels; generic call() cannot leak an
    /// attach whose stream frames arrived before the caller resumed.
    public func openStream(_ method: String, parameters: Data = Data("{}".utf8), timeout: Duration = .seconds(30)) async throws -> CoreStream {
        guard method == "terminal.attach" || method == "events.subscribe" else { throw CoreStreamFailure.invalidFrame }
        let options = try CoreStreamOpen(method: method, parameters: parameters)
        let reply = try await request(method, parameters: parameters, timeout: timeout, stream: options)
        let header: CoreStreamHeader = try reply.result()
        guard let slot = streams[header.channel], state == .ready else { throw CoreStreamFailure.closed }
        if Task.isCancelled {
            try await closeStream(slot.id)
            throw CancellationError()
        }
        return CoreStream(connection: self, id: slot.id, reply: reply, observe: options.observe,
                          resizeNotifications: slot.resizeNotifications)
    }

    func installStream(_ reply: CoreRPCReply, options: CoreStreamOpen, orphaned: Bool) throws {
        let header: CoreStreamHeader = try reply.result()
        guard streams.count < maximumStreams else { throw CoreStreamFailure.limitExceeded }
        try usedChannels.claim(header.channel)
        let slot = CoreStreamState(id: CoreStreamID(epoch: epoch, channel: header.channel), options: options,
                                   resizeNotifications: options.wantsResize && header.resize_notifications == true)
        streams[header.channel] = slot
        if orphaned { try beginStreamClose(slot) }
    }
    func receiveStream(_ frame: CoreFrame) throws {
        // Wire order guarantees the RPC reply before stream frames. Installing
        // synchronously in receiveFrame removes the thread-registration race;
        // truly pre-reply data is a protocol violation, not an unbounded cache.
        guard let slot = streams[frame.channel], !slot.ended else { throw CoreStreamFailure.invalidChannel }
        switch frame.kind {
        case .data:
            guard frame.payload.count <= slot.credit else { throw CoreStreamFailure.creditExceeded }
            slot.credit -= frame.payload.count
            if slot.closing { return }
            guard frame.payload.count <= maximumStreamBytes - bufferedStreamBytes else { throw CoreStreamFailure.bufferExceeded }
            slot.dataBytes += frame.payload.count; bufferedStreamBytes += frame.payload.count
        case .resize:
            guard slot.resizeNotifications, slot.options.method == "terminal.attach" else { throw CoreStreamFailure.invalidFrame }
            if slot.closing { return }
        case .close:
            guard frame.payload.count <= 16 << 10 else { throw CoreStreamFailure.bufferExceeded }
            if slot.closing {
                streams[frame.channel] = nil
                for closer in slot.closers { closer.resume() }; slot.closers.removeAll()
                scheduleTimer(); return
            }
            slot.ended = true
        default: throw CoreStreamFailure.invalidFrame
        }
        guard slot.packets.count < 1024 else { throw CoreStreamFailure.bufferExceeded }
        slot.packets.append(frame)
        deliverStream(slot)
    }
    func nextStreamPacket(_ id: CoreStreamID, timeout: Duration?) async throws -> CoreStreamPacket? {
        try Task.checkCancellation()
        if let timeout { try validate(timeout) }
        guard id.epoch == epoch else { throw CoreStreamFailure.staleEpoch }
        guard state == .ready else { throw CoreConnectionFailure.closed }
        guard let slot = streams[id.channel] else { return nil }
        guard slot.id == id else { throw CoreStreamFailure.staleEpoch }
        guard !slot.closing else { return nil }
        guard slot.reader == nil else { throw CoreStreamFailure.concurrentRead }
        guard slot.outstanding == nil else { throw CoreStreamFailure.unacknowledgedData }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                if Task.isCancelled { c.resume(throwing: CancellationError()); cancelStreamRead(id); return }
                slot.reader = c
                slot.readDeadline = timeout.map { .now.advanced(by: $0) }
                deliverStream(slot); scheduleTimer()
            }
        } onCancel: { Task { await self.cancelStreamRead(id) } }
    }
    private func deliverStream(_ slot: CoreStreamState) {
        guard !slot.closing, let reader = slot.reader, !slot.packets.isEmpty, slot.outstanding == nil else { return }
        let frame = slot.packets.removeFirst()
        var receipt: CoreCreditReceipt?
        if frame.kind == .data {
            guard slot.sequence < UInt64.max else { fail(CoreStreamFailure.limitExceeded); return }
            slot.sequence += 1
            receipt = CoreCreditReceipt(stream: slot.id, sequence: slot.sequence, bytes: frame.payload.count)
            slot.outstanding = receipt
        }
        slot.reader = nil; slot.readDeadline = nil
        if frame.kind == .close { streams[slot.id.channel] = nil }
        reader.resume(returning: CoreStreamPacket(frame: frame, receipt: receipt))
    }
    func acknowledgeStream(_ id: CoreStreamID, receipt: CoreCreditReceipt) throws {
        let slot = try streamSlot(id)
        guard !slot.closing else { throw CoreStreamFailure.closed }
        guard receipt.stream == id, slot.outstanding == receipt else { throw CoreStreamFailure.invalidReceipt }
        if receipt.bytes > 0 {
            do { try streamControl(slot, kind: .credit, payload: Data(CoreWire.littleEndian(UInt32(receipt.bytes)))) }
            catch { fail(error); throw error }
        }
        slot.outstanding = nil; slot.dataBytes -= receipt.bytes; bufferedStreamBytes -= receipt.bytes
        slot.credit += receipt.bytes
        // next() requires explicit caller processing/ack, so there is never a
        // second outstanding packet hidden behind a resumed consumer.
    }
    func sendStream(_ id: CoreStreamID, kind: CoreWire.Kind, payload: Data) throws {
        let slot = try streamSlot(id)
        guard !slot.closing, !slot.ended else { throw CoreStreamFailure.closed }
        guard slot.options.method == "terminal.attach", !slot.options.observe else { throw CoreStreamFailure.readOnly }
        guard [.data, .resize, .focus, .facts].contains(kind) else { throw CoreStreamFailure.invalidFrame }
        let frame = try CoreFrame(channel: id.channel, kind: kind, payload: payload)
        try enqueue(Write(bytes: frame.encoded(), token: nil, deadline: .now.advanced(by: .seconds(30)),
                          channel: id.channel, priority: kind != .data))
    }
    func closeStream(_ id: CoreStreamID) async throws {
        guard id.epoch == epoch else { throw CoreStreamFailure.staleEpoch }
        if state == .closed { try await close(); return }
        guard let slot = streams[id.channel] else { return }
        guard slot.id == id else { throw CoreStreamFailure.staleEpoch }
        if slot.ended { discardStream(slot); return }
        guard slot.closers.count < 16 else { throw CoreStreamFailure.limitExceeded }
        try await withCheckedThrowingContinuation { c in
            slot.closers.append(c)
            do { try beginStreamClose(slot) }
            catch { fail(error) }
        }
    }
    private func streamSlot(_ id: CoreStreamID) throws -> CoreStreamState {
        guard id.epoch == epoch else { throw CoreStreamFailure.staleEpoch }
        guard state == .ready else { throw CoreConnectionFailure.closed }
        guard let slot = streams[id.channel], slot.id == id else { throw CoreStreamFailure.closed }
        return slot
    }
    private func discardStream(_ slot: CoreStreamState) {
        bufferedStreamBytes -= slot.dataBytes; slot.dataBytes = 0
        slot.packets.removeAll(); slot.outstanding = nil
        slot.reader?.resume(returning: nil); slot.reader = nil; slot.readDeadline = nil
        streams[slot.id.channel] = nil
        discardStreamWrites(slot.id.channel)
        for c in slot.closers { c.resume() }; slot.closers.removeAll()
        scheduleTimer()
    }
    private func discardStreamWrites(_ channel: UInt32) {
        writes.removeAll { item in
            guard item.channel == channel else { return false }
            queuedWriteBytes -= item.bytes.count; return true
        }
    }
    private func beginStreamClose(_ slot: CoreStreamState) throws {
        guard !slot.closing else { return }
        slot.closing = true; slot.closeDeadline = .now.advanced(by: .seconds(2))
        bufferedStreamBytes -= slot.dataBytes; slot.dataBytes = 0
        slot.packets.removeAll(); slot.outstanding = nil
        slot.reader?.resume(returning: nil); slot.reader = nil; slot.readDeadline = nil
        discardStreamWrites(slot.id.channel)
        try streamControl(slot, kind: .close)
        scheduleTimer()
    }
    private func streamControl(_ slot: CoreStreamState, kind: CoreWire.Kind, payload: Data = Data()) throws {
        let frame = try CoreFrame(channel: slot.id.channel, kind: kind, payload: payload)
        try enqueue(Write(bytes: frame.encoded(), token: nil, deadline: .now.advanced(by: .seconds(2)),
                          channel: slot.id.channel, priority: true))
    }
    private func cancelStreamRead(_ id: CoreStreamID) {
        guard let slot = streams[id.channel], slot.id == id else { return }
        slot.reader?.resume(throwing: CancellationError()); slot.reader = nil
        if slot.ended { discardStream(slot); return }
        do { try beginStreamClose(slot) } catch { fail(error) }
    }
    var nextStreamDeadline: ContinuousClock.Instant? {
        streams.values.flatMap { [$0.readDeadline, $0.closeDeadline].compactMap { $0 } }.min()
    }
    func expireStreams(at now: ContinuousClock.Instant) {
        for slot in Array(streams.values) {
            if let deadline = slot.closeDeadline, deadline <= now { fail(CoreStreamFailure.closeTimedOut); return }
            if let deadline = slot.readDeadline, deadline <= now {
                slot.reader?.resume(throwing: CoreStreamFailure.timedOut); slot.reader = nil; slot.readDeadline = nil
                if slot.ended { discardStream(slot) }
                else { do { try beginStreamClose(slot) } catch { fail(error); return } }
            }
        }
    }
}

nonisolated struct CoreStreamHeader: Decodable, Sendable {
    let channel: UInt32
    let resize_notifications: Bool?
}

/// Channels may be allocated/replied out of order. Compress used IDs into
/// intervals, not an ever-growing tombstone set; cap even malicious gaps.
nonisolated struct CoreChannelIDs: Sendable {
    private var ranges: [ClosedRange<UInt32>] = []
    mutating func claim(_ id: UInt32) throws {
        guard id > 0, !ranges.contains(where: { $0.contains(id) }) else { throw CoreStreamFailure.invalidChannel }
        var next = ranges + [id...id]; next.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<UInt32>] = []
        for range in next {
            if let last = merged.last, UInt64(range.lowerBound) <= UInt64(last.upperBound) + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        guard merged.count <= 128 else { throw CoreStreamFailure.limitExceeded }
        ranges = merged
    }
}
