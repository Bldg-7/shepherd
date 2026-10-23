import Foundation
import AgentProxyCore
import AgentProxyForwarder
import AgentProxyProtocol

enum CompressionTests {
    enum Failure: Error { case assertion(String) }
    static func run(fixtures: URL) throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw Failure.assertion(name) }
            checks += 1
        }
        let expected = try Data(contentsOf: fixtures.appendingPathComponent("codex-request.json"))
        for (encoding, suffix) in [("gzip", "gz"), ("deflate", "zz"), ("zstd", "zst")] {
            let input = try Data(contentsOf: fixtures.appendingPathComponent("codex-request." + suffix))
            for chunk in [1, 7, 16384, input.count] {
                let decoder = AgentProxyBodyDecoder.make(encoding)!
                var result = Data()
                for offset in stride(from: 0, to: input.count, by: chunk) {
                    try decoder.append(Data(input[offset..<min(input.count, offset + chunk)])) { result.append($0) }
                }
                try decoder.finish { result.append($0) }
                try check(result == expected, "\(encoding) chunk \(chunk) round trip")
                do { try decoder.append(Data([1])) { _ in }; throw Failure.assertion("closed decoder accepted bytes") }
                catch is AgentProxyBodyDecoder.Failure { checks += 1 }
            }
            let capture = ConversationCapture(makeDecoder: AgentProxyBodyDecoder.make)
            func frame(_ kind: AgentProxyTeeFrame.Kind, _ bytes: Data) throws {
                var wire = AgentProxyTeeFrame.Decoder()
                wire.append(AgentProxyTeeFrame.header(kind: kind, exchange: 1, payloadCount: bytes.count) + bytes)
                while let decoded = try wire.next() { capture.consume(decoded) }
            }
            let requestOpen = AgentProxyTeeFrame.Open(routeID: "route", upstream: "chatgpt", method: "POST",
                path: "/backend-api/codex/responses", headers: [["content-encoding", encoding], ["content-type", "application/json"]],
                routeIdentity: .init(kind: .codex, session: "default", paneID: "pane", terminalID: "terminal", cliVersion: "0.162.1"))
            try frame(.open, JSONEncoder().encode(requestOpen))
            try frame(.requestBody, input); try frame(.requestEnd, Data())
            try check(capture.reconciler.store.count == 1 && capture.bufferedRequestBytes == 0, "\(encoding) actual compressed request reaches classified store")
            try frame(.responseHead, JSONEncoder().encode(AgentProxyTeeFrame.ResponseHead(status: 200,
                headers: [["content-encoding", encoding], ["content-type", "text/event-stream"]])))
            try frame(.responseBody, Data(contentsOf: fixtures.appendingPathComponent("capture-response." + suffix)))
            try frame(.end, JSONEncoder().encode(AgentProxyTeeFrame.End(outcome: .complete)))
            let stored = capture.reconciler.store.list().first.flatMap { capture.reconciler.store.read(id: $0.id) }
            try check(stored?.summary.status == .complete && stored?.items.last?.message.blocks.first?.text == "captured response",
                      "\(encoding) compressed SSE reaches completed conversation")
            try check(capture.activeExchangeCount == 0 && capture.accountedBytes <= capture.limits.totalBytes, "\(encoding) codec buffers retired within budget")
            for bad in [Data(input.dropLast()), input + Data([0]), input + input, Data([0, 1, 2, 3])] {
                let decoder = AgentProxyBodyDecoder.make(encoding)!
                do {
                    try decoder.append(bad) { _ in }
                    try decoder.finish { _ in }
                    throw Failure.assertion("\(encoding) accepted incomplete/trailing/concatenated/malformed stream")
                } catch is AgentProxyBodyDecoder.Failure { checks += 1 }
            }
            let decoder = AgentProxyBodyDecoder.make(encoding)!
            enum Stop: Error { case sink }
            do {
                try decoder.append(input) { _ in throw Stop.sink }
                throw Failure.assertion("sink error swallowed")
            } catch Stop.sink { checks += 1 }
            do { try decoder.finish { _ in }; throw Failure.assertion("failed sink decoder resumed") }
            catch is AgentProxyBodyDecoder.Failure { checks += 1 }
        }
        // Standard zstd magic, non-single-segment frame with an excessive
        // advertised window. The decoder must reject before allocating it.
        let hugeWindow = Data([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0xf8, 0x01, 0x00, 0x00])
        do {
            let decoder = AgentProxyBodyDecoder.make("zstd")!
            try decoder.append(hugeWindow) { _ in }
            try decoder.finish { _ in }
            throw Failure.assertion("excessive zstd window accepted")
        } catch is AgentProxyBodyDecoder.Failure { checks += 1 }
        try check(AgentProxyBodyDecoder.make("br") == nil && AgentProxyBodyDecoder.make("gzip, zstd") == nil, "unknown and stacked encodings rejected")
        try JSONSerialization.data(withJSONObject: ["passed": checks, "failed": 0]).write(to: fixtures.appendingPathComponent("compression-results.json"))
        print("Compression tests: \(checks) passed")
    }
}
