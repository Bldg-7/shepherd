import Foundation

/// Quotes `text` so a POSIX shell (sh, bash, zsh) reads it back as exactly
/// one word with exactly these characters, whatever they are — spaces,
/// `$`, `;`, backticks, newlines, quotes.
///
/// Single quotes are the only shell quoting with no escape character
/// inside: everything up to the next `'` is literal. So the one character
/// that needs handling is `'` itself, which can't appear inside the quotes
/// at all — it's written by closing the quoted span, adding a
/// backslash-escaped quote, and opening a new span (`'\''`).
///
/// One call protects against one round of shell parsing. A string that
/// passes through two shells (see `TerminalSession`) has to be quoted once
/// per shell, innermost first.
///
/// `nonisolated` because the callers are the terminal session actors, not
/// the main actor this module's declarations default to.
nonisolated func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
