import Foundation

/// Intent detection claims even malformed HTTP(S) links before any TUI input.
/// Validation is separate: no search, scheme expansion or external-app fallback.
nonisolated enum TerminalWebLink {
    static func isWebLink(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered.hasPrefix("http:") || lowered.hasPrefix("https:")
    }

    /// Hangul, Han or kana glued to the last letter or digit of a link, like
    /// the particle in `…/pull/16048에서`, is prose that follows the link.
    static let gluedProseSuffix = #"(?<=[A-Za-z0-9])[\p{Hangul}\p{Han}\p{Hiragana}\p{Katakana}]+$"#

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
        if let prose = token.range(of: gluedProseSuffix, options: .regularExpression) {
            guard characterOffset - start < token.distance(from: token.startIndex, to: prose.lowerBound) else { return nil }
            token.removeSubrange(prose)
        }
        return isWebLink(token) ? token : nil
    }

    /// `raw` as a link Shepherd Browser can open: valid (`validatedURL`),
    /// with the browser on and able to run here. Nil for a click that isn't
    /// the pane's own any more.
    static func urlToOpen(_ raw: String, contextMatches: Bool, browserEnabled: Bool, engineAvailable: Bool) throws -> String? {
        guard contextMatches else { return nil }
        let url = try validatedURL(raw)
        guard browserEnabled else { throw TerminalWebLinkError.browserDisabled }
        guard engineAvailable else { throw TerminalWebLinkError.engineUnavailable }
        return url
    }

    /// `raw` as a link to open, wherever it opens: `http` or `https`, with a
    /// host and without credentials, control characters or whitespace, and
    /// at most 8 KB. The same whether it goes to Shepherd Browser or to the
    /// Mac's default browser; only the former has conditions of its own
    /// (`urlToOpen`).
    static func validatedURL(_ raw: String) throws -> String {
        guard raw.utf8.count <= 8192, !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URLComponents(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.url != nil,
              url.port == nil || (1...65535).contains(url.port!) else { throw TerminalWebLinkError.invalidURL }
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
