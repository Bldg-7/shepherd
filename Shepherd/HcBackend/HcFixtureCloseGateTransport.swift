#if DEBUG && os(macOS)
import Foundation
import ShepherdKit

/// Owned UI fixture only. Pause exactly one complete doc.set BEFORE dispatch,
/// without changing bytes/version, consuming raw VT, or replaying a write.
/// Like CoreProcessTransport, the nonisolated Sendable facade satisfies the
/// imported SDK protocol while an internal actor owns all mutable gate state.
nonisolated final class HcFixtureCloseGateTransport: CoreByteTransport {
    nonisolated struct Snapshot: Sendable {
        let entered: Bool
        let forwarded: Int
        let released: Bool
        let closed: Bool
    }
    private let state: State
    init(base: any CoreByteTransport) { state = State(base:base) }
    func start() async throws { try await state.start() }
    func read() async throws -> Data? { try await state.read() }
    func write(_ bytes: Data) async throws { try await state.write(bytes) }
    func close() async throws { try await state.close() }
    func arm() async throws { try await state.arm() }
    func release() async throws { try await state.release() }
    func snapshot() async -> Snapshot { await state.snapshot() }

    private actor State {
        private let base: any CoreByteTransport
        private var armed = false
        private var used = false
        private var entered = false
        private var forwarded = 0
        private var released = false
        private var closed = false
        private var writing = false
        private var held: CheckedContinuation<Void, any Error>?
        init(base: any CoreByteTransport) { self.base = base }
        func start() async throws { try await base.start() }
        func read() async throws -> Data? {
            guard !closed else { throw CoreConnectionFailure.closed }
            return try await base.read()
        }
        func arm() throws {
            guard !closed, !used, !armed else { throw CoreConnectionFailure.notReady }
            armed = true
        }
        func snapshot() -> Snapshot { .init(entered:entered,forwarded:forwarded,released:released,closed:closed) }
        func release() throws {
            guard !closed, entered, !released, let continuation = held else { throw CoreConnectionFailure.notReady }
            held = nil; released = true; continuation.resume()
        }
        private func isDocumentSet(_ bytes: Data) throws -> Bool {
            var decoder = CoreFrameDecoder(), first: CoreFrame?
            try decoder.receive(bytes) { frame in
                guard first == nil else { throw CoreConnectionFailure.transportFailed }
                first = frame
            }
            try decoder.finish()
            guard let frame = first else { throw CoreConnectionFailure.transportFailed }
            guard frame.channel == 0, frame.kind == .data,
                  let value = try? JSONSerialization.jsonObject(with:frame.payload) as? [String:Any] else { return false }
            return value["method"] as? String == "doc.set"
        }
        func write(_ bytes: Data) async throws {
            guard !closed else { throw CoreConnectionFailure.closed }
            guard !writing, bytes.count <= CoreWire.maximumPayload + CoreWire.headerSize else {
                try await close(); throw CoreConnectionFailure.writeLimitExceeded
            }
            writing = true; defer { writing = false }
            do {
                let pause: Bool
                if armed { pause = try isDocumentSet(bytes) } else { pause = false }
                try await withTaskCancellationHandler {
                    if pause {
                        armed = false; used = true; entered = true
                        try await withCheckedThrowingContinuation { held = $0 }
                    }
                    try Task.checkCancellation()
                    guard !closed else { throw CoreConnectionFailure.closed }
                    try await base.write(bytes)
                    if pause { forwarded += 1 }
                } onCancel: {
                    Task { try? await self.close() }
                }
            } catch {
                try await close()
                throw error
            }
        }
        func close() async throws {
            closed = true; armed = false
            let continuation = held; held = nil
            continuation?.resume(throwing:CoreConnectionFailure.closed)
            try await base.close()
        }
    }
}
#endif
