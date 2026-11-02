import Foundation

nonisolated struct WireVector: Decodable {
    let channel: UInt32
    let kind: UInt8
    let payloadHex: String
    let wireHex: String
}
nonisolated enum TestFailure: Error { case failed(String), sink }

@MainActor
private enum Check {
    static var assertions = 0
    static var groups = 0
    static func that(_ value: @autoclosure () throws -> Bool, _ message: String = #function) throws {
        assertions += 1
        guard try value() else { throw TestFailure.failed(message) }
    }
    static func fails(_ expected: CoreWire.Failure, _ operation: () throws -> Void) throws {
        assertions += 1
        do { try operation() }
        catch let failure as CoreWire.Failure {
            guard failure == expected else { throw TestFailure.failed("wrong protocol failure: \(failure)") }
            return
        }
        catch { throw TestFailure.failed("unexpected error type") }
        throw TestFailure.failed("expected protocol failure: \(expected)")
    }
    static func group(_ name: String, _ operation: () throws -> Void) throws {
        try operation(); groups += 1; print("PASS \(name)")
    }
}

@main
private struct CoreProtocolTests {
    @MainActor static func main() throws {
        let vectors = try JSONDecoder().decode([WireVector].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var encoded: [String] = []
        try Check.group("independent Python wire vectors / all kinds / little endian") {
            for vector in vectors {
                let frame = try CoreFrame(channel: vector.channel, kind: CoreWire.Kind(rawValue: vector.kind)!, payload: unhex(vector.payloadHex))
                try Check.that(frame.encoded() == unhex(vector.wireHex))
                encoded.append(hex(frame.encoded()))
                // Includes nonzero Data indices, not just Data starting at zero.
                let prefixed = Data([1, 2, 3]) + frame.encoded()
                var decoder = CoreFrameDecoder(); var actual: [CoreFrame] = []
                try decoder.receive(prefixed.dropFirst(3)) { actual.append($0) }
                try decoder.finish()
                try Check.that(actual == [frame])
            }
        }
        try JSONEncoder().encode(encoded).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

        let frame = try CoreFrame(channel: 0x12345678, kind: .data, payload: Data([0, 255, 0x1b, 0x5b, 0x6d, 0xc3, 0xa9, 10]))
        let wire = frame.encoded()
        try Check.group("every frame split and one-byte input") {
            for split in 0...wire.count {
                var decoder = CoreFrameDecoder(); var result: [CoreFrame] = []
                try decoder.receive(wire.prefix(split)) { result.append($0) }
                try decoder.receive(Data()) { result.append($0) }
                try decoder.receive(wire.dropFirst(split)) { result.append($0) }
                try Check.that(result == [frame] && decoder.bufferedByteCount == 0)
                try decoder.finish()
            }
            var decoder = CoreFrameDecoder(); var result: [CoreFrame] = []
            for byte in wire { try decoder.receive(Data([byte])) { result.append($0) } }
            try decoder.finish(); try Check.that(result == [frame])
        }
        try Check.group("coalesced frames / empty DATA and CLOSE") {
            let frames = [try CoreFrame(channel: 0, kind: .data), frame, try CoreFrame(channel: 7, kind: .close)]
            var decoder = CoreFrameDecoder(); var result: [CoreFrame] = []
            try decoder.receive(frames.reduce(Data()) { $0 + $1.encoded() }) { result.append($0) }
            try decoder.finish(); try Check.that(result == frames)
        }
        try Check.group("seeded fragmentation of multiplexed binary data") {
            var seed: UInt64 = 0x5a9de29
            func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
            var expected: [CoreFrame] = []
            for _ in 0..<200 {
                let count = Int(next() % 513)
                let payload = Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next() >> 24) })
                expected.append(try CoreFrame(channel: UInt32(next() % 9), kind: .data, payload: payload))
            }
            let all = expected.reduce(Data()) { $0 + $1.encoded() }
            var decoder = CoreFrameDecoder(); var result: [CoreFrame] = []; var cursor = 0
            while cursor < all.count {
                let end = min(all.count, cursor + 1 + Int(next() % 97))
                try decoder.receive(all[cursor..<end]) { result.append($0) }
                try Check.that(decoder.bufferedByteCount <= CoreWire.headerSize + 512)
                cursor = end
            }
            try decoder.finish(); try Check.that(result == expected)
        }
        try Check.group("oversized header rejected before payload; permanently failed") {
            var decoder = CoreFrameDecoder()
            try Check.fails(.payloadTooLarge) { try decoder.receive(header(channel: 1, kind: 0, count: 16 * 1024 * 1024 + 1)) { _ in throw TestFailure.sink } }
            try Check.that(decoder.bufferedByteCount == 0)
            try Check.fails(.decoderClosed) { try decoder.receive(wire) { _ in } }
            try Check.fails(.decoderClosed) { try decoder.finish() }
            try Check.fails(.payloadTooLarge) { _ = try CoreFrame(channel: 1, kind: .data, payload: Data(count: CoreWire.maximumPayload + 1)) }
        }
        try Check.group("maximum payload / larger aggregate read delivered incrementally") {
            let large = try CoreFrame(channel: 2, kind: .data, payload: Data(repeating: 0xa5, count: CoreWire.maximumPayload))
            var decoder = CoreFrameDecoder(); var count = 0
            try decoder.receive(large.encoded() + wire) { decoded in
                try Check.that(decoded == (count == 0 ? large : frame)); count += 1
            }
            try decoder.finish(); try Check.that(count == 2 && decoder.bufferedByteCount == 0)
        }
        try Check.group("unknown kind and invalid channel/control lengths fail closed") {
            for (bytes, error) in [
                (header(channel: 1, kind: 6, count: 0), CoreWire.Failure.unknownKind(6)),
                (header(channel: 0, kind: 2, count: 0), .invalidControlChannel),
                (header(channel: 1, kind: 1, count: 0), .invalidControlPayload),
                (header(channel: 1, kind: 3, count: 5), .invalidControlPayload),
                (header(channel: 1, kind: 4, count: 2), .invalidControlPayload),
                (header(channel: 1, kind: 4, count: 1) + Data([2]), .invalidControlPayload)
            ] {
                var decoder = CoreFrameDecoder()
                try Check.fails(error) { try decoder.receive(bytes) { _ in throw TestFailure.sink } }
                try Check.that(decoder.bufferedByteCount == 0)
            }
            try Check.fails(.invalidControlPayload) { _ = try CoreFrame(channel: 1, kind: .credit) }
            try Check.fails(.invalidControlPayload) { _ = try CoreFrame(channel: 1, kind: .focus, payload: Data([2])) }
            try Check.fails(.invalidControlChannel) { _ = try CoreFrame(channel: 0, kind: .close) }
        }
        try Check.group("all truncated header/payload EOF positions") {
            for length in 1..<wire.count {
                var decoder = CoreFrameDecoder()
                try decoder.receive(wire.prefix(length)) { _ in throw TestFailure.sink }
                try Check.fails(.truncatedFrame) { try decoder.finish() }
                try Check.that(decoder.bufferedByteCount == 0)
            }
            var empty = CoreFrameDecoder(); try empty.finish()
            try Check.fails(.decoderClosed) { try empty.receive(Data()) { _ in } }
            try Check.fails(.decoderClosed) { try empty.finish() }
        }
        try Check.group("consumer failure poisons frame decoder") {
            var decoder = CoreFrameDecoder()
            do { try decoder.receive(wire + wire) { _ in throw TestFailure.sink }; throw TestFailure.failed("sink accepted") }
            catch TestFailure.sink {}
            try Check.that(decoder.bufferedByteCount == 0)
            try Check.fails(.decoderClosed) { try decoder.receive(wire) { _ in } }
        }
        try testLines()
        try testHello(wire: wire, frame: frame)
        print("PASS CoreProtocol: \(Check.groups) groups, \(Check.assertions) assertions")
    }

    @MainActor static func testLines() throws {
        try Check.group("event lines preserve binary/UTF-8 boundaries and empty lines") {
            let text = Data("{\"name\":\"한글😀\"}\n\n{\"seq\":2}\r\n".utf8)
            for split in 0...text.count {
                var lines = try CoreEventLines(); var result: [Data] = []
                try lines.receive(text.prefix(split)) { result.append($0) }
                try lines.receive(text.dropFirst(split)) { result.append($0) }
                try lines.finish()
                try Check.that(result == [Data("{\"name\":\"한글😀\"}".utf8), Data(), Data("{\"seq\":2}\r".utf8)])
            }
        }
        try Check.group("line byte budget, exact bound, and aggregate input") {
            var lines = try CoreEventLines(maximumLineBytes: 4); var result: [Data] = []
            try lines.receive(Data("1234".utf8)) { result.append($0) }
            try Check.that(lines.bufferedByteCount == 4)
            try lines.receive(Data("\n1234\n1234\n".utf8)) { result.append($0) }
            try lines.finish(); try Check.that(result.count == 3)
            var overflow = try CoreEventLines(maximumLineBytes: 4)
            try overflow.receive(Data("1234".utf8)) { _ in }
            try Check.fails(.lineTooLong) { try overflow.receive(Data("5\n".utf8)) { _ in } }
            try Check.that(overflow.bufferedByteCount == 0)
            try Check.fails(.decoderClosed) { try overflow.receive(Data()) { _ in } }
            try Check.fails(.invalidLineLimit) { _ = try CoreEventLines(maximumLineBytes: 0) }
            try Check.fails(.invalidLineLimit) { _ = try CoreEventLines(maximumLineBytes: CoreWire.maximumPayload + 1) }
        }
        try Check.group("event EOF and consumer error cannot be resumed") {
            var lines = try CoreEventLines()
            try lines.receive(Data("partial".utf8)) { _ in }
            try Check.fails(.truncatedLine) { try lines.finish() }
            try Check.that(lines.bufferedByteCount == 0)
            var sink = try CoreEventLines()
            do { try sink.receive(Data("{}\n{}\n".utf8)) { _ in throw TestFailure.sink }; throw TestFailure.failed("sink accepted") }
            catch TestFailure.sink {}
            try Check.fails(.decoderClosed) { try sink.finish() }
        }
    }

    @MainActor static func testHello(wire: Data, frame: CoreFrame) throws {
        let reply = try helloLine()
        try Check.group("hello request is generation-1 framed JSON-RPC line") {
            let decoder = CoreHandshakeDecoder(requestID: 42)
            let request = try decoder.request()
            try Check.that(request.last == 10 && request.filter { $0 == 10 }.count == 1)
            let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            try Check.that(object["id"] as? Int == 42 && object["method"] as? String == "hello")
            let params = object["params"] as! [String: Any]
            try Check.that(params["generation"] as? Int == 1 && params["framed"] as? Bool == true)
        }
        try Check.group("every split of hello + binary frames; callback order") {
            let all = reply + wire + (try CoreFrame(channel: 7, kind: .close)).encoded()
            for split in 0...all.count {
                var decoder = CoreHandshakeDecoder(); var order: [String] = []; var frames: [CoreFrame] = []
                var accepted: [CoreHello] = []
                func hello(_ value: CoreHello) { order.append("hello"); accepted.append(value) }
                func receive(_ value: CoreFrame) { order.append("frame"); frames.append(value) }
                try decoder.receive(all.prefix(split), onHello: hello, onFrame: receive)
                try decoder.receive(all.dropFirst(split), onHello: hello, onFrame: receive)
                try Check.that(accepted.count == 1 && accepted[0].core.id == "fixture-core" && accepted[0].features == ["future-feature"])
                try Check.that(order == ["hello", "frame", "frame"] && frames.first == frame)
                try Check.that(decoder.bufferedByteCount == 0 && decoder.hello != nil)
                try decoder.finish()
                try Check.fails(.decoderClosed) { try decoder.receive(Data(), onHello: { _ in }, onFrame: { _ in }) }
            }
        }
        try Check.group("hello rejection / mismatched envelope / malformed JSON") {
            let cases: [(Data, CoreWire.Failure)] = [
                (Data("banner\n".utf8), .invalidHello),
                (Data([0xff, 10]), .invalidHello),
                (Data("{}\n".utf8), .invalidHello),
                (try helloLine(envelope: ["id": 1]), .invalidHello),
                (try helloLine(envelope: ["id": true]), .invalidHello),
                (try helloLine(envelope: ["jsonrpc": "1.0"]), .invalidHello),
                (try helloLine(envelope: ["error": ["code": -32000]]), .invalidHello),
                (Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32000,\"message\":\"private message\"}}\n".utf8), .helloRejected(-32000)),
                (try helloLine(result: ["generation": 2]), .unsupportedGeneration(2)),
                (try helloLine(result: ["framed": false]), .framingNotAccepted),
                (try helloLine(result: ["core": ["id": "", "name": "fixture"]]), .invalidHello),
                (try helloLine(result: ["version": ""]), .invalidHello),
                (try helloLine(result: ["methods": ["terminal.list"]]), .missingMethods(["events.subscribe", "terminal.attach"]))
            ]
            for (bytes, error) in cases {
                var decoder = CoreHandshakeDecoder()
                try Check.fails(error) { try decoder.receive(bytes + wire, onHello: { _ in throw TestFailure.sink }, onFrame: { _ in throw TestFailure.sink }) }
                try Check.that(decoder.hello == nil && decoder.bufferedByteCount == 0)
                try Check.fails(.decoderClosed) { try decoder.receive(reply, onHello: { _ in }, onFrame: { _ in }) }
            }
        }
        try Check.group("extra required methods and custom request id") {
            var missing = CoreHandshakeDecoder(requiredMethods: ["doc.get", "doc.set"])
            try Check.fails(.missingMethods(["doc.get", "doc.set"])) { try missing.receive(reply, onHello: { _ in }, onFrame: { _ in }) }
            var custom = CoreHandshakeDecoder(requestID: 73, requiredMethods: [])
            try custom.receive(helloLine(envelope: ["id": 73]), onHello: { _ in }, onFrame: { _ in })
            try custom.finish()
        }
        try Check.group("hello limit and unterminated handshake EOF") {
            for prefix in [Data(), reply.dropLast()] {
                var decoder = CoreHandshakeDecoder()
                try decoder.receive(prefix, onHello: { _ in }, onFrame: { _ in })
                try Check.fails(.truncatedHello) { try decoder.finish() }
                try Check.that(decoder.bufferedByteCount == 0)
            }
            var large = CoreHandshakeDecoder()
            try Check.fails(.lineTooLong) { try large.receive(Data(repeating: 32, count: CoreHandshakeDecoder.maximumHelloBytes + 1), onHello: { _ in }, onFrame: { _ in }) }
            try Check.that(large.bufferedByteCount == 0)
            var exact = CoreHandshakeDecoder()
            let padded = Data(repeating: 32, count: CoreHandshakeDecoder.maximumHelloBytes - (reply.count - 1)) + reply
            try exact.receive(padded, onHello: { _ in }, onFrame: { _ in }); try exact.finish()
        }
        try Check.group("truncated frame after hello and consumer failure retire metadata") {
            var decoder = CoreHandshakeDecoder()
            try decoder.receive(reply + wire.dropLast(), onHello: { _ in }, onFrame: { _ in })
            try Check.fails(.truncatedFrame) { try decoder.finish() }
            try Check.that(decoder.hello == nil && decoder.bufferedByteCount == 0)
            var failed = CoreHandshakeDecoder()
            do { try failed.receive(reply + wire, onHello: { _ in throw TestFailure.sink }, onFrame: { _ in throw TestFailure.failed("frame delivered") }); throw TestFailure.failed("sink accepted") }
            catch TestFailure.sink {}
            try Check.that(failed.hello == nil && failed.bufferedByteCount == 0)
            try Check.fails(.decoderClosed) { try failed.finish() }
        }
    }

    @MainActor static func helloLine(result overrides: [String: Any] = [:], envelope: [String: Any] = [:]) throws -> Data {
        var result: [String: Any] = ["core": ["id": "fixture-core", "name": "fixture"], "generation": 1,
            "version": "0.1.16", "methods": ["terminal.list", "terminal.attach", "events.subscribe"],
            "features": ["future-feature"], "framed": true]
        result.merge(overrides) { _, new in new }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": 0, "result": result]
        reply.merge(envelope) { _, new in new }
        return try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) + Data([10])
    }

    static func header(channel: UInt32, kind: UInt8, count: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: channel >> ($0 * 8)) } + [kind] + (0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
    }
    static func unhex(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map { UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)! })
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
