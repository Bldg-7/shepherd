import Foundation

/// Intent detection claims even malformed HTTP(S) links before any TUI input.
/// Validation is separate: no search, scheme expansion or external-app fallback.
nonisolated enum TerminalWebLink {
    static func isWebLink(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered.hasPrefix("http:") || lowered.hasPrefix("https:")
    }

    static func token(in text: String, characterOffset: Int) -> String? {
        guard text.count <= 8192, characterOffset >= 0, characterOffset < text.count else { return nil }
        let chars = Array(text)
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>()[]{}|"))
        func boundary(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { delimiters.contains($0) } }
        guard !boundary(chars[characterOffset]) else { return nil }
        var start = characterOffset, end = characterOffset + 1
        while start > 0 && !boundary(chars[start - 1]) { start -= 1 }
        while end < chars.count && !boundary(chars[end]) { end += 1 }
        var token = String(chars[start..<end])
        while token.last == "," || token.last == ";" { token.removeLast() }
        if token.last == "." { token.removeLast() }
        return isWebLink(token) ? token : nil
    }

    static func urlToOpen(_ raw: String, contextMatches: Bool, browserEnabled: Bool, engineAvailable: Bool) throws -> String? {
        guard contextMatches else { return nil }
        guard raw.utf8.count <= 8192, !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URLComponents(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.url != nil,
              url.port == nil || (1...65535).contains(url.port!) else { throw TerminalWebLinkError.invalidURL }
        guard browserEnabled else { throw TerminalWebLinkError.browserDisabled }
        guard engineAvailable else { throw TerminalWebLinkError.engineUnavailable }
        return raw
    }
}

nonisolated enum TerminalWebLinkError: Error, LocalizedError {
    case invalidURL, browserDisabled, engineUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "Only valid HTTP and HTTPS links without embedded credentials can be opened.")
        case .browserDisabled: String(localized: "Enable Experimental Browser in Settings to open web links.")
        case .engineUnavailable: String(localized: "The browser needs a Mac with Apple silicon.")
        }
    }
}
