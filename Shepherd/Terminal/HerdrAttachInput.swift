import Foundation

/// What is written to a `herdr terminal attach` for the bytes the terminal
/// view sends, so that Ctrl+B reaches the pane's program.
///
/// herdr's attach client keeps Ctrl+B for itself as a prefix, in every
/// version and with no setting to turn it off: a Ctrl+B is held until the
/// next key, Ctrl+B q ends the attach, and Ctrl+B Ctrl+B sends one Ctrl+B on
/// to the pane. So every Ctrl+B the attach would take is written twice:
///
/// - A write that is one whole Ctrl+B press, in a form herdr 0.9.0 and later
///   read as one key, is written twice: the kitty keyboard protocol's
///   `CSI 98 ; M u`, also with event type 1, a shifted key of 98 or a base
///   layout key, and modifyOtherKeys' `CSI 27 ; M ; 98 ~`, where M is Ctrl
///   alone, with or without Caps Lock and Num Lock. The program asked for
///   that form, so it gets it, once.
/// - Anything else has each 0x02 byte doubled, which every herdr version
///   reads as Ctrl+B, except inside a bracketed paste: herdr 0.9.0 and later
///   pass a paste on without looking inside it.
///
/// A repeat or release, and Ctrl+B with Shift, Alt or Super, are left as they
/// are: herdr doesn't take them. So are two forms SwiftTerm doesn't send for
/// a Latin layout's Ctrl+B, which herdr does take: one with associated text,
/// and, from herdr 0.9.4, a non-Latin layout's key with b as its base layout
/// key (`CSI 1080::98;5u`). herdr 0.8.2 and older take only the 0x02 byte,
/// in a paste too: with them a kitty or modifyOtherKeys Ctrl+B reaches the
/// pane twice, and a 0x02 in a paste still starts the prefix.
nonisolated enum HerdrAttachInput {
    /// One write's bytes as herdr should get them (see the type).
    static func escaped(_ bytes: some Collection<UInt8>) -> [UInt8] {
        var pasteOpen = false
        return escaped(bytes, pasteOpen: &pasteOpen)
    }

    /// The same for one of a stream of writes: `pasteOpen` says whether an
    /// earlier write began a paste that hasn't ended yet, and is left saying
    /// whether one is still open after this write. SwiftTerm sends a ⌘V paste
    /// as three writes (the start, the text and the end), which herdr puts
    /// back together before it reads them.
    static func escaped(_ bytes: some Collection<UInt8>, pasteOpen: inout Bool) -> [UInt8] {
        let bytes = Array(bytes)
        if !pasteOpen, isPrefixPress(bytes) {
            return bytes + bytes
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 1)
        var index = 0
        while index < bytes.count {
            if pasteOpen {
                // The paste is left as it is, up to its end or this write's.
                let end = range(of: pasteEnd, in: bytes, from: index)?.upperBound
                output += bytes[index..<(end ?? bytes.count)]
                pasteOpen = end == nil
                index = end ?? bytes.count
            } else if bytes[index...].starts(with: pasteStart) {
                output += pasteStart
                pasteOpen = true
                index += pasteStart.count
            } else {
                output.append(bytes[index])
                if bytes[index] == ctrlB {
                    output.append(ctrlB)
                }
                index += 1
            }
        }
        return output
    }

    private static let ctrlB: UInt8 = 0x02
    private static let pasteStart = Array("\u{1b}[200~".utf8)
    private static let pasteEnd = Array("\u{1b}[201~".utf8)

    /// Whether `bytes` is one kitty or modifyOtherKeys Ctrl+B press as
    /// herdr 0.9.0 and later parse it (`src/input/parse.rs`) and take it as
    /// the prefix (`src/client/attach.rs`): key 98, b, with Ctrl the only one
    /// of Shift, Alt, Ctrl, Super, Hyper and Meta.
    private static func isPrefixPress(_ bytes: [UInt8]) -> Bool {
        guard bytes.starts(with: [0x1b, 0x5b]),
              let body = String(bytes: bytes.dropFirst(2), encoding: .ascii) else { return false }
        if body.hasPrefix("27;"), body.hasSuffix("~") {
            let fields = body.dropLast().split(separator: ";", omittingEmptySubsequences: false)
            return fields.count == 3 && isCtrlAlone(fields[1]) && fields[2] == "98"
        }
        guard body.hasSuffix("u") else { return false }
        let fields = body.dropLast().split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return false }
        // 98, then the shifted key, empty or 98 itself, then any base layout key.
        let key = fields[0].split(separator: ":", omittingEmptySubsequences: false)
        guard key[0] == "98", key.count <= 3 else { return false }
        if key.count >= 2, !(key[1].isEmpty || key[1] == "98") { return false }
        if key.count == 3, !isNumber(key[2]) { return false }
        // The modifiers, then a press (1) if an event type is given.
        let modifiers = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        switch modifiers.count {
        case 1: return isCtrlAlone(modifiers[0])
        case 2: return isCtrlAlone(modifiers[0]) && modifiers[1] == "1"
        default: return false
        }
    }

    /// Whether `field` is a modifier value M whose modifiers, M - 1, are Ctrl
    /// (4) alone in its low six bits; Caps Lock (64) and Num Lock (128) are
    /// above them.
    private static func isCtrlAlone(_ field: Substring) -> Bool {
        guard isNumber(field), field.count <= 3, let value = Int(field), (1...255).contains(value) else { return false }
        return (value - 1) & 0b11_1111 == 0b100
    }

    private static func isNumber(_ field: Substring) -> Bool {
        !field.isEmpty && field.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func range(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Range<Int>? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        return (start...(bytes.count - needle.count))
            .first { bytes[$0..<$0 + needle.count].elementsEqual(needle) }
            .map { $0..<$0 + needle.count }
    }
}
