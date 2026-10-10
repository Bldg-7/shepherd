import Foundation

/// A link is data, never a command. All paths belong to the clicked pane's
/// filesystem; the host component never selects a different machine.
nonisolated struct FilePreviewLink: Equatable, Sendable {
    let path: String
    let line: Int?
    let column: Int?

    /// Classifies intent only. Neither cwd nor URI host here grants a read:
    /// the actual request is resolved again against the clicked pane/machine.
    static func isFileGestureLink(_ raw: String) -> Bool {
        if raw.lowercased().hasPrefix("file:") { return true }
        do { _ = try resolve(raw, directory: "/", hostname: ""); return true }
        catch FilePreviewError.unsupportedLink { return false }
        catch { return true } // claimed file errors must not fall through to TUI
    }

    static var localHostAliases: Set<String> {
        let host = ProcessInfo.processInfo.hostName.lowercased()
        return [host, String(host.split(separator: ".").first ?? "localhost")]
    }

    static func resolve(_ raw: String, directory: String?, hostname: String, additionalHosts: Set<String> = []) throws -> Self {
        guard raw.utf8.count <= 8192, !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FilePreviewError.invalidPath
        }
        var path = raw
        var line: Int?
        var column: Int?
        if raw.lowercased().hasPrefix("file:") {
            guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "file",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil,
                  let decoded = url.percentEncodedPath.removingPercentEncoding, !decoded.isEmpty else {
                throw FilePreviewError.invalidPath
            }
            let host = url.host?.lowercased() ?? ""
            guard host.isEmpty || host == "localhost" || host == hostname.lowercased() || additionalHosts.contains(host) else {
                throw FilePreviewError.wrongHost
            }
            path = decoded
            if let fragment = url.fragment {
                guard let match = fragment.range(of: #"^L?[1-9][0-9]*(?::[1-9][0-9]*)?$"#, options: .regularExpression) else {
                    throw FilePreviewError.invalidPath
                }
                let parts = fragment[match].drop(while: { $0 == "L" }).split(separator: ":")
                line = Int(parts[0]); column = parts.count > 1 ? Int(parts[1]) : nil
                guard line != nil, parts.count == 1 || column != nil else { throw FilePreviewError.invalidPath }
            }
        } else {
            // Remove a source location before checking schemes: README.md:42
            // is a path, not a URI scheme. Known schemes still fail closed.
            let candidate = raw.replacingOccurrences(of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#, with: "", options: .regularExpression)
            let schemeLike = raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
            let sourceLocation = candidate != raw && SelfPath.hasExtension(candidate)
                && candidate.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil
            guard !schemeLike || sourceLocation else { throw FilePreviewError.unsupportedLink }
        }
        if line == nil,
           let suffix = path.range(of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#, options: .regularExpression) {
            let numbers = path[suffix].dropFirst().split(separator: ":")
            line = Int(numbers[0]); column = numbers.count > 1 ? Int(numbers[1]) : nil
            guard line != nil, numbers.count == 1 || column != nil else { throw FilePreviewError.invalidPath }
            path.removeSubrange(suffix)
        }
        guard !path.isEmpty, !path.hasPrefix("~"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FilePreviewError.invalidPath
        }
        if !path.hasPrefix("/") {
            guard let directory, directory.hasPrefix("/"),
                  !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw FilePreviewError.missingDirectory
            }
            path = directory + "/" + path
        }
        // Lexical POSIX normalization; do not resolve a remote path against
        // this Mac's home directory or symlinks.
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        guard !components.isEmpty else { throw FilePreviewError.invalidPath }
        return Self(path: "/" + components.joined(separator: "/"), line: line, column: column)
    }

    /// Conservative fallback for non-OSC8 paths. The caller supplies a cell
    /// mapped to a string offset, so wide characters don't shift hit testing.
    static func token(in text: String, characterOffset: Int) -> String? {
        guard text.count <= 8192, characterOffset >= 0, characterOffset < text.count else { return nil }
        let chars = Array(text)
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>()[]{}|"))
        func boundary(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { delimiters.contains($0) } }
        guard !boundary(chars[characterOffset]) else { return nil }
        var a = characterOffset, b = characterOffset + 1
        while a > 0 && !boundary(chars[a - 1]) { a -= 1 }
        while b < chars.count && !boundary(chars[b]) { b += 1 }
        var token = String(chars[a..<b])
        while token.last == "," || token.last == ";" { token.removeLast() }
        if token.hasSuffix(".") { token.removeLast() }
        let withoutLocation = token.replacingOccurrences(of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#, with: "", options: .regularExpression)
        guard withoutLocation.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil else { return nil }
        let ext = (withoutLocation as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, FilePreviewDocument.textExtensions.contains(ext) || FilePreviewDocument.imageExtensions.contains(ext) else { return nil }
        return token
    }
}

private nonisolated enum SelfPath {
    static func hasExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return FilePreviewDocument.textExtensions.contains(ext) || FilePreviewDocument.imageExtensions.contains(ext)
    }
}

nonisolated enum FilePreviewError: Error, LocalizedError {
    case invalidPath, unsupportedLink, wrongHost, missingDirectory, nestedMachine, tooLarge, notRegularFile, unsupportedContent, needsHostKey, timedOut
    var errorDescription: String? {
        switch self {
        case .invalidPath: String(localized: "This file path is not supported.")
        case .unsupportedLink: String(localized: "Only file links can be opened in this preview.")
        case .wrongHost: String(localized: "The file link belongs to a different machine.")
        case .missingDirectory: String(localized: "The pane's working directory is unknown. Use an absolute file path.")
        case .nestedMachine: String(localized: "File preview is not available for nested Herdr machines.")
        case .tooLarge: String(localized: "This file is too large to preview (4 MB maximum).")
        case .notRegularFile: String(localized: "Only regular files can be previewed.")
        case .unsupportedContent: String(localized: "This file type or text encoding cannot be previewed.")
        case .needsHostKey: String(localized: "Connect to this machine's terminal first to verify its host key.")
        case .timedOut: String(localized: "Reading the file timed out.")
        }
    }
}

nonisolated struct FilePreviewDocument: Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "swift", "js", "jsx", "ts", "tsx", "json", "jsonl", "yaml", "yml", "toml", "xml", "html", "css", "scss", "py", "rb", "rs", "go", "c", "h", "cpp", "hpp", "sh", "bash", "zsh", "sql", "log", "csv", "ini", "conf", "diff", "patch", "svg"]
    enum Content: Sendable { case text(String, markdown: Bool), image(Data) }
    let content: Content

    init(data: Data, path: String) throws {
        guard data.count <= Self.maximumBytes else { throw FilePreviewError.tooLarge }
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { content = .image(data); return }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw FilePreviewError.unsupportedContent }
        // HTML/SVG are displayed as inert source, never loaded into WebKit.
        content = .text(text, markdown: ext == "md" || ext == "markdown")
    }
}

/// Window-width, not device orientation or a cached size class, decides iPad
/// layout. Browser and preview are mutually exclusive presentation states.
nonisolated enum FilePreviewPresentation {
    static func usesSplit(isPad: Bool, detailWidth: Double) -> Bool { isPad && detailWidth >= 760 }
}
