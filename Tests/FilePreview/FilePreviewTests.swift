import Foundation
import Darwin

@main @MainActor enum FilePreviewTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func reject(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("expected rejection") } catch { checks += 1 }
    }
    static func main() async throws {
        let dir = ProcessInfo.processInfo.arguments[1]
        let resolve: (String, String?) throws -> FilePreviewLink = { try .resolve($0, directory: $1, hostname: "owned-host") }
        check(try resolve("README.md", dir).path == dir + "/README.md", "relative source directory")
        check(try resolve("docs/../README.md:42:7", dir).line == 42, "source line")
        check(try resolve("README.md:42:7", dir).column == 7, "source column vs scheme")
        check(try resolve("file:///tmp/a%20b.md#L42", nil).path == "/tmp/a b.md", "decode only file URLs")
        check(try resolve("file://owned-host/tmp/a.md#12:3", nil).column == 3, "host and fragment")
        check(try resolve("file://localhost/tmp/a.md", nil).path == "/tmp/a.md", "localhost means source terminal host")
        check(try resolve("/remote/path.md", nil).path == "/remote/path.md", "absolute without cwd")
        check(try FilePreviewLink.resolve("file://trusted-alias/tmp/a.md", directory: nil, hostname: "localhost", additionalHosts: ["trusted-alias"]).path == "/tmp/a.md", "explicit trusted local aliases")
        reject { _ = try FilePreviewLink.resolve("file://untrusted/tmp/a.md", directory: nil, hostname: "localhost", additionalHosts: ["trusted-alias"]) }
        check(try resolve("literal%20.md", dir).path.hasSuffix("literal%20.md"), "literal percent remains literal")
        for raw in ["", "~/.ssh/key", "a\0.md", "file:///tmp/a%00.md", "file://other/tmp/a.md", "file://u:p@owned-host/tmp/a.md", "file:///tmp/a.md?x=1", "file:///tmp/a.md#bad", "file:///tmp/a.md#L0", "https://a/b.md", "javascript:foo.md:12", "vscode:/tmp/a.md", "ssh://owned-host/a", "file://owned-host:22/tmp/a.md", "/", String(repeating: "a", count: 8193)] {
            reject { _ = try resolve(raw, dir) }
        }
        reject { _ = try resolve("a.md", nil) }
        reject { _ = try resolve("a.md", "relative") }
        check(FilePreviewLink.token(in: "Read docs/a.md:12:3 now", characterOffset: 9) == "docs/a.md:12:3", "plain token")
        check(FilePreviewLink.token(in: "README.md:42", characterOffset: 2) == "README.md:42", "bare source token")
        check(FilePreviewLink.token(in: "`./a.md`,", characterOffset: 4) == "./a.md", "punctuation")
        check(FilePreviewLink.token(in: "https://a/a.md", characterOffset: 10) == nil, "don't steal URL events")
        check(FilePreviewLink.token(in: "status ready", characterOffset: 2) == nil, "don't steal TUI words")
        check(FilePreviewLink.token(in: "a.md", characterOffset: 4) == nil, "no out of bounds")
        check(!FilePreviewPresentation.usesSplit(isPad: false, detailWidth: 2000), "phone always pushed")
        check(!FilePreviewPresentation.usesSplit(isPad: true, detailWidth: 759), "narrow pad")
        check(FilePreviewPresentation.usesSplit(isPad: true, detailWidth: 760), "wide pad threshold")
        check(FilePreviewPresentation.usesSplit(isPad: true, detailWidth: 1100), "wide pad")
        let path = dir + "/owned.md"
        try Data("# Owned\n\n**hello** [next](next.md)\n```swift\nlet x = 1\n```\n> quote\n- item\n---\n".utf8).write(to: URL(fileURLWithPath: path))
        let data = try FilePreviewReader.readLocal(path: path)
        let document = try FilePreviewDocument(data: data, path: path)
        if case .text(let text, let md) = document.content {
            check(md, "md rendered")
            let blocks = PreviewMarkdownBlock.parse(text)
            check(blocks.count == 6, "heading paragraph code quote bullet rule")
            if case .heading(1) = blocks[0].kind { checks += 1 } else { preconditionFailure("heading") }
            if case .code = blocks[2].kind { check(blocks[2].text == "let x = 1", "code remains literal") } else { preconditionFailure("code") }
        } else { preconditionFailure("text") }
        check(try FilePreviewReader.readLocal(path: path) == data, "bounded actual owned file read")
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.md", withDestinationPath: path)
        check(try FilePreviewReader.readLocal(path: dir + "/link.md") == data, "regular symlink target")
        reject { _ = try FilePreviewReader.readLocal(path: dir) }
        let fifo = dir + "/owned.pipe"
        check(mkfifo(fifo, 0o600) == 0, "owned FIFO")
        reject { _ = try FilePreviewReader.readLocal(path: fifo) }
        reject { _ = try FilePreviewReader.readLocal(path: dir + "/missing.md") }
        let large = dir + "/large.txt"
        try Data(repeating: 65, count: FilePreviewDocument.maximumBytes + 1).write(to: URL(fileURLWithPath: large))
        reject { _ = try FilePreviewReader.readLocal(path: large) }
        reject { _ = try FilePreviewDocument(data: Data(repeating: 0, count: FilePreviewDocument.maximumBytes + 1), path: "a.png") }
        reject { _ = try FilePreviewDocument(data: Data([0]), path: "a.txt") }
        reject { _ = try FilePreviewDocument(data: Data([0xff]), path: "a.txt") }
        if case .text(_, let md) = try FilePreviewDocument(data: Data("<script>alert(1)</script>".utf8), path: "a.html").content { check(!md, "HTML inert source") }
        if case .text(_, let md) = try FilePreviewDocument(data: Data("<svg/>".utf8), path: "a.svg").content { check(!md, "SVG inert source") }
        if case .image = try FilePreviewDocument(data: Data([1,2,3]), path: "a.png").content { checks += 1 }
        let unfinished = PreviewMarkdownBlock.parse("```\nlast line")
        check(unfinished.count == 1 && unfinished[0].text == "last line", "unterminated code fence")
        let reader = FilePreviewReader()
        await reader.cancel()
        do {
            _ = try await reader.read(path: path, machine: Machine(displayName: "Owned", hostname: "localhost", username: "owned", isLocal: true), secret: nil)
            preconditionFailure("cancelled reader must not acquire resources")
        } catch is CancellationError { checks += 1 }
        let cancelled = Task { try FilePreviewReader.readLocal(path: path) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("pre-cancel must deny read") } catch is CancellationError { checks += 1 }
        print("PASS \(checks) path, token, layout, native Markdown, owned-file, size/FIFO and cancellation checks; no SSH or Keychain")
    }
}
