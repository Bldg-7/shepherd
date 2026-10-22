import Foundation

/// What `HerdrAttachInput` writes for each write of the terminal view, and
/// what herdr's attach client does with it: a model of the client, ported
/// from herdr's source, is given the bytes as the app writes them, with and
/// without the escaping. No herdr, process or terminal.
@main enum HerdrAttachInputTests {
    static var checks = 0
    static func check(_ b: Bool, _ why: String) { precondition(b, why); checks += 1 }

    static let esc: UInt8 = 0x1b, ctrlB: UInt8 = 0x02
    static func csi(_ s: String) -> [UInt8] { [esc, 0x5b] + Array(s.utf8) }
    static func paste(_ text: [UInt8]) -> [UInt8] { csi("200~") + text + csi("201~") }

    static func main() {
        table()
        splitPaste()
        herdr()
        print("PASS \(checks) herdr attach input checks: each Ctrl+B press herdr 0.9 takes as its prefix written twice (0x02, kitty CSI 98;5u with Caps/Num Lock and event type 1, modifyOtherKeys), repeats, releases, other modifiers, associated text and non-Latin layouts left alone, pastes left alone also over three writes; herdr's attach client (0.9.0, 0.9.1, master; 0.5.12-0.8.2) modeled from its source: without the escaping Ctrl+B q detaches, with it no key sequence detaches and the pane gets the bytes the view sent; herdr 0.8.2's known limits; no herdr or terminal")
    }

    // MARK: - One write

    static func table() {
        let pasted = paste([0x61, ctrlB, 0x71])
        let doubled: [(String, [UInt8])] = [
            ("legacy Ctrl+B", [ctrlB]),
            ("kitty Ctrl+B", csi("98;5u")),
            ("kitty Ctrl+B with Caps Lock", csi("98;69u")),
            ("kitty Ctrl+B with Num Lock", csi("98;133u")),
            ("kitty Ctrl+B with Caps Lock and Num Lock", csi("98;197u")),
            ("kitty Ctrl+B press, event type given", csi("98;5:1u")),
            ("kitty Ctrl+B with its shifted key given as itself", csi("98:98;5u")),
            ("kitty Ctrl+B with a base layout key (herdr reads key 98 as b)", csi("98::120;5u")),
            ("modifyOtherKeys Ctrl+B", csi("27;5;98~")),
            ("modifyOtherKeys Ctrl+B with Caps Lock", csi("27;69;98~")),
        ]
        for (name, bytes) in doubled {
            check(HerdrAttachInput.escaped(bytes[...]) == bytes + bytes, "\(name) is written twice")
        }
        let unchanged: [(String, [UInt8])] = [
            ("kitty Ctrl+B repeat", csi("98;5:2u")),
            ("kitty Ctrl+B release", csi("98;5:3u")),
            ("kitty Ctrl+Shift+B", csi("98;6u")),
            ("kitty Ctrl+Shift+B with its shifted key", csi("98:66;6u")),
            ("kitty Ctrl+Shift+B as SwiftTerm sends it with alternates", csi("98:2;6u")),
            ("kitty Ctrl+Alt+B", csi("98;7u")),
            ("kitty Ctrl+Super+B", csi("98;13u")),
            ("kitty B without modifiers", csi("98u")),
            ("kitty Ctrl+B with associated text, which SwiftTerm doesn't send", csi("98;5;98u")),
            ("kitty Ctrl+B of a non-Latin layout (left to herdr, see HerdrAttachInput)", csi("1080::98;5u")),
            ("kitty Ctrl+B with an empty event type", csi("98;5:u")),
            ("modifyOtherKeys Ctrl+Shift+B", csi("27;6;98~")),
            ("modifyOtherKeys Ctrl+B with an event type", csi("27;5:1;98~")),
            ("kitty q", csi("113u")),
            ("a letter", Array("a".utf8)),
            ("a paste with Ctrl+B q in it", pasted),
            ("an empty write", []),
        ]
        for (name, bytes) in unchanged {
            check(HerdrAttachInput.escaped(bytes[...]) == bytes, "\(name) is written as it is")
        }
        // Against the model of herdr 0.9 below: what is written twice is
        // what herdr takes as the prefix when it comes alone, and what is
        // left alone isn't, but for the associated text form, which herdr
        // takes too (SwiftTerm doesn't send it), and the non-Latin layout's
        // key, which herdr 0.9.4 and later take.
        func takesAsPrefix(_ bytes: [UInt8]) -> Bool { Herdr09.singleKey(bytes).map { $0.isPrefix && $0.kind == .press } ?? false }
        for (name, bytes) in doubled {
            check(takesAsPrefix(bytes), "herdr 0.9 takes \(name) as the prefix")
        }
        for (name, bytes) in unchanged where bytes != csi("98;5;98u") {
            check(!takesAsPrefix(bytes), "herdr 0.9.1 doesn't take \(name) as the prefix")
        }
        check(takesAsPrefix(csi("98;5;98u")), "herdr 0.9 takes kitty Ctrl+B with associated text as the prefix (a form left alone)")
        check(HerdrAttachInput.escaped([esc, ctrlB]) == [esc, ctrlB, ctrlB], "Alt+Ctrl+B as ESC 0x02 has its 0x02 doubled")
        check(HerdrAttachInput.escaped(Array("a\u{2}b\u{2}".utf8)) == Array("a\u{2}\u{2}b\u{2}\u{2}".utf8), "every 0x02 in a write is doubled")
        check(HerdrAttachInput.escaped(csi("98;5u") + csi("98;5u")) == csi("98;5u") + csi("98;5u"), "two kitty presses in one write are not one key, and have no 0x02")
        check(HerdrAttachInput.escaped([ctrlB] + pasted + [ctrlB]) == [ctrlB, ctrlB] + pasted + [ctrlB, ctrlB], "a paste is left alone between doubled 0x02s")
        check(HerdrAttachInput.escaped(pasted + pasted) == pasted + pasted, "two pastes in one write are left alone")
        // A paste whose end is in a later write: what follows its start is left alone.
        check(HerdrAttachInput.escaped(csi("200~") + [ctrlB]) == csi("200~") + [ctrlB], "an open paste is left alone")
        // ESC [ 201 ~ outside a paste ends nothing.
        check(HerdrAttachInput.escaped(csi("201~") + [ctrlB]) == csi("201~") + [ctrlB, ctrlB], "a paste's end without its start ends nothing")
        // The ArraySlice the terminal view hands over need not start at 0.
        let view: [UInt8] = [0x61] + csi("98;5u")
        check(HerdrAttachInput.escaped(view[1...]) == csi("98;5u") + csi("98;5u"), "a slice is read from its own start")
    }

    /// SwiftTerm sends a ⌘V paste as three writes: the start, the text, the end.
    static func splitPaste() {
        var open = false
        func write(_ bytes: [UInt8]) -> [UInt8] { HerdrAttachInput.escaped(bytes[...], pasteOpen: &open) }
        check(write(csi("200~")) == csi("200~") && open, "a paste's start opens it")
        check(write([0x61, ctrlB, 0x71]) == [0x61, ctrlB, 0x71] && open, "the pasted text is left alone")
        check(write(csi("98;5u")) == csi("98;5u") && open, "even a whole kitty Ctrl+B while the paste is open")
        check(write(csi("201~")) == csi("201~") && !open, "the paste's end closes it")
        check(write([ctrlB]) == [ctrlB, ctrlB] && !open, "a Ctrl+B after the paste is doubled again")
        check(write([0x61] + csi("200~") + [ctrlB]) == [0x61] + csi("200~") + [ctrlB] && open, "a start later in a write opens it too")
        check(write([ctrlB] + csi("201~") + [ctrlB]) == [ctrlB] + csi("201~") + [ctrlB, ctrlB] && !open, "an end in the middle of a write closes it there")
    }

    // MARK: - herdr's attach client

    /// A key as herdr parses one (`crossterm::event::KeyCode`, `KeyModifiers`
    /// and `KeyEventKind`), with only what the prefix and q are decided by.
    struct Key {
        /// Shift, Alt, Ctrl, Super, Hyper and Meta, as bits 0 to 5 of a
        /// kitty modifier value M - 1 (`key_modifiers_from_u8`, parse.rs
        /// 380–401, which keeps no other bit: not Caps Lock or Num Lock).
        struct Modifiers: OptionSet { let rawValue: UInt8
            static let shift = Modifiers(rawValue: 1), alt = Modifiers(rawValue: 2), control = Modifiers(rawValue: 4)
            init(rawValue: UInt8) { self.rawValue = rawValue & 0b11_1111 }
        }
        enum Code: Equatable { case character(Character), named }
        enum Kind { case press, `repeat`, release }
        var code: Code
        var modifiers: Modifiers
        var kind = Kind.press
        var isPrefix: Bool { code == .character("b") && modifiers == .control }
        var isQuit: Bool { code == .character("q") && modifiers.isEmpty && kind == .press }
    }

    /// herdr 0.9's attach client, from its stdin to what it forwards to the
    /// pane, ported from herdr 0.9.1 (the release tarball; `attach.rs` the same
    /// in the v0.9.0 tag and in master as of 2026-10-21):
    /// - `src/client/input.rs` `unix_stdin_reader_loop` and `src/raw_input.rs`
    ///   `RawInputByteFramer` (`drain_available_chunks` 422–, `extract_one_event`
    ///   567–644, `complete_escape_sequence_len` 770–825): stdin is cut into one
    ///   event per chunk, a paste kept whole however it was read;
    /// - `src/client/attach.rs` `filter_input` 57–146, for each chunk;
    /// - `src/input/parse.rs` `parse_kitty_key_sequence` 13–62,
    ///   `parse_modify_other_keys_sequence` 90–100 and `parse_legacy_key_sequence`
    ///   103–161, for the one key a chunk is (`single_attach_key`). master
    ///   adds a base-layout rule for non-Latin keys, which no key here has.
    /// Left out, because no input here is one: mouse reports and the scroll
    /// keys (`attach_scroll_action`), host replies, ESC ESC, OSC and other
    /// control strings, and a lone ESC held over an idle moment.
    struct Herdr09 {
        var pane: [UInt8] = []
        var detached = false
        private var buffer: [UInt8] = []
        private var pendingPrefix: [UInt8]?

        mutating func read(_ bytes: [UInt8]) {
            buffer += bytes
            while !detached, let length = Self.eventLength(buffer) {
                let chunk = Array(buffer.prefix(length))
                buffer.removeFirst(length)
                filter(chunk)
            }
        }

        /// What is left once the keys have been read: only an open paste.
        var waiting: [UInt8] { buffer }

        static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e], pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]

        /// `extract_one_event`'s length for the event `buffer` starts with, or nil while it is incomplete.
        static func eventLength(_ buffer: [UInt8]) -> Int? {
            guard let first = buffer.first else { return nil }
            if buffer.starts(with: pasteStart) {
                return firstIndex(of: pasteEnd, in: buffer).map { $0 + pasteEnd.count }
            }
            if first == 0x1b {
                guard buffer.count > 1 else { return nil }
                precondition(buffer[1] != 0x1b && buffer[1] != 0x5d && buffer[1] != 0x50 && buffer[1] != 0x4f, "not modeled")
                if buffer[1] == 0x5b {
                    // CSI: up to the first final byte, @ to ~ (find_csi_final from index 2).
                    return buffer.indices.dropFirst(2).first { (0x40...0x7e).contains(buffer[$0]) }.map { $0 + 1 }
                }
                return utf8Width(buffer[1]).flatMap { buffer.count >= 1 + $0 ? 1 + $0 : nil }
            }
            return utf8Width(first).flatMap { buffer.count >= $0 ? $0 : nil }
        }

        static func utf8Width(_ byte: UInt8) -> Int? {
            switch byte {
            case 0..<0x80: 1
            case 0xc2...0xdf: 2
            case 0xe0...0xef: 3
            case 0xf0...0xf4: 4
            default: nil
            }
        }

        static func firstIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
            guard bytes.count >= needle.count else { return nil }
            return (0...(bytes.count - needle.count)).first { bytes[$0..<$0 + needle.count].elementsEqual(needle) }
        }

        /// `is_complete_text_bracketed_paste`: exactly one paste, its text UTF-8.
        static func isCompleteTextPaste(_ data: [UInt8]) -> Bool {
            guard data.starts(with: pasteStart), let end = firstIndex(of: pasteEnd, in: data), end + pasteEnd.count == data.count else { return false }
            return String(bytes: data[pasteStart.count..<end], encoding: .utf8) != nil
        }

        /// `filter_input`, attach.rs 57–146, with `attach_scroll_action` always nil.
        mutating func filter(_ data: [UInt8]) {
            if Self.isCompleteTextPaste(data) {
                if let prefix = pendingPrefix { pendingPrefix = nil; pane += prefix }
                pane += data
                return
            }
            if let key = Self.singleKey(data) {
                if var prefix = pendingPrefix {
                    pendingPrefix = nil
                    if key.isPrefix && key.kind != .press {
                        prefix += data
                        pendingPrefix = prefix
                        return
                    }
                    if key.isQuit { detached = true; return }
                    if key.isPrefix { pane += data; return }
                    pane += prefix + data
                    return
                }
                if key.isPrefix && key.kind == .press {
                    pendingPrefix = data
                    return
                }
            }
            // The legacy byte path.
            var output: [UInt8] = []
            for byte in data {
                if var prefix = pendingPrefix {
                    pendingPrefix = nil
                    switch byte {
                    case 0x71: detached = true; return
                    case 0x02: output += prefix
                    default: prefix.append(byte); output += prefix
                    }
                    continue
                }
                if byte == 0x02 { pendingPrefix = [0x02] } else { output.append(byte) }
            }
            pane += output
        }

        /// The one key a chunk is, or nil when it is a paste, some other
        /// event, or not one herdr parses (`single_attach_key`).
        static func singleKey(_ data: [UInt8]) -> Key? {
            guard !isCompleteTextPaste(data), let text = String(bytes: data, encoding: .utf8) else { return nil }
            return kitty(text) ?? modifyOtherKeys(text) ?? legacy(text)
        }

        /// `modifier_text.parse::<u8>()?.checked_sub(1)?`, then `key_modifiers_from_u8`.
        static func modifiers(_ field: Substring) -> Key.Modifiers? {
            guard let value = UInt8(field), value >= 1 else { return nil }
            return Key.Modifiers(rawValue: value - 1)
        }

        /// kitty_codepoint_to_keycode, parse.rs 306–377: Backspace, Tab,
        /// Enter, Esc and the private-use keys from 57358 are named keys
        /// (some keypad keys there are characters in herdr, but not b or q);
        /// any other code point is that character.
        static func code(_ codepoint: UInt32) -> Key.Code? {
            if [8, 9, 13, 27, 127].contains(codepoint) || (57358...57454).contains(codepoint) { return .named }
            return Unicode.Scalar(codepoint).map { .character(Character($0)) }
        }

        /// parse_kitty_key_sequence, parse.rs 13–62.
        static func kitty(_ text: String) -> Key? {
            guard text.hasPrefix("\u{1b}["), text.hasSuffix("u") else { return nil }
            let fields = text.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count <= 3 else { return nil }
            let modifierPart = fields.count > 1 && !fields[1].isEmpty ? fields[1] : "1"
            var modifierText = modifierPart, event: Substring?
            if let colon = modifierPart.firstIndex(of: ":"), colon != modifierPart.startIndex {
                modifierText = modifierPart[..<colon]
                event = modifierPart[modifierPart.index(after: colon)...]
            }
            guard var modifiers = modifiers(modifierText) else { return nil }
            let keyFields = fields[0].split(separator: ":", omittingEmptySubsequences: false)
            guard let codepoint = UInt32(keyFields[0]), let code = code(codepoint) else { return nil }
            let shifted = keyFields.count > 1 && !keyFields[1].isEmpty ? UInt32(keyFields[1]) : nil
            if fields.count == 3 {
                // Associated text: characters that aren't control characters
                // (parse_kitty_associated_text), or for a named key its own
                // control code (matching_control_associated_text).
                let scalars = fields[2].split(separator: ":", omittingEmptySubsequences: false).map { UInt32($0).flatMap(Unicode.Scalar.init) }
                let text = scalars.allSatisfy { $0 != nil && $0!.properties.generalCategory != .control }
                let matchingControl = code == .named && ["13", "8", "9", "27"].contains(fields[2])
                guard text || matchingControl else { return nil }
            }
            let kind: Key.Kind
            switch event ?? "1" {
            case "1": kind = .press
            case "2": kind = .repeat
            case "3": kind = .release
            default: return nil
            }
            // A shifted key other than the key itself means Shift.
            if code != .named, let shifted, shifted != codepoint, Unicode.Scalar(shifted) != nil { modifiers.insert(.shift) }
            return Key(code: code, modifiers: modifiers, kind: kind)
        }

        /// parse_modify_other_keys_sequence, parse.rs 90–100.
        static func modifyOtherKeys(_ text: String) -> Key? {
            guard text.hasPrefix("\u{1b}[27;"), text.hasSuffix("~") else { return nil }
            let body = text.dropFirst(5).dropLast()
            guard let semicolon = body.firstIndex(of: ";"), let modifiers = modifiers(body[..<semicolon]),
                  let codepoint = UInt32(body[body.index(after: semicolon)...]), let code = code(codepoint) else { return nil }
            return Key(code: code, modifiers: modifiers)
        }

        /// parse_legacy_key_sequence, parse.rs 103–146, for a character, or
        /// ESC and a character; the named sequences it goes on to (arrows,
        /// F keys and the like) are left out: none here is one.
        static func legacy(_ text: String) -> Key? {
            switch text {
            case "\r", "\t", "\u{1b}", "\u{7f}": return Key(code: .named, modifiers: [])
            case "\u{1b}\u{7f}": return Key(code: .named, modifiers: .alt)
            default: break
            }
            if text.hasPrefix("\u{1b}") {
                let rest = String(text.dropFirst())
                guard rest.unicodeScalars.count == 1, var key = legacy(rest) else { return nil }
                key.modifiers.insert(.alt)
                return key
            }
            guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return nil }
            // parse_legacy_ctrl_char, 147–161.
            switch scalar.value {
            case 0: return Key(code: .character(" "), modifiers: .control)
            case 1...26: return Key(code: .character(Character(Unicode.Scalar(scalar.value + 96)!)), modifiers: .control)
            case 27: return Key(code: .character("["), modifiers: .control)
            case 28: return Key(code: .character("\\"), modifiers: .control)
            case 29: return Key(code: .character("]"), modifiers: .control)
            case 30: return Key(code: .character("^"), modifiers: .control)
            case 31: return Key(code: .character("_"), modifiers: .control)
            default:
                // Rust's is_ascii_uppercase.
                return Key(code: .character(Character(scalar)), modifiers: (65...90).contains(scalar.value) ? .shift : [])
            }
        }
    }

    /// herdr 0.8.2's attach client (`src/client/mod.rs` `filter_input`,
    /// 131–169; the same byte loop in the v0.5.12, v0.6.0 and v0.7.0 tags):
    /// only the 0x02 byte is the prefix, wherever it is, and a read's
    /// output is dropped when it ends the attach.
    struct Herdr082 {
        var pane: [UInt8] = []
        var detached = false
        private var pendingPrefix = false

        mutating func read(_ bytes: [UInt8]) {
            guard !detached else { return }
            var output: [UInt8] = []
            for byte in bytes {
                if pendingPrefix {
                    pendingPrefix = false
                    switch byte {
                    case 0x71: detached = true; return
                    case 0x02: output.append(0x02)
                    default: output += [0x02, byte]
                    }
                    continue
                }
                if byte == 0x02 { pendingPrefix = true } else { output.append(byte) }
            }
            pane += output
        }
    }

    /// Keys typed in a pane, each as the writes the terminal view makes for it.
    struct Typing {
        var name: String
        var keys: [[[UInt8]]]
        var sent: [UInt8] { keys.flatMap { $0.flatMap { $0 } } }
        /// Each write as the app writes it to the attach, with or without the escaping.
        func written(escaping: Bool) -> [[UInt8]] {
            var open = false
            return keys.flatMap { $0 }.map { escaping ? HerdrAttachInput.escaped($0[...], pasteOpen: &open) : $0 }
        }
    }

    static func herdr() {
        let b: [UInt8] = [ctrlB], q = Array("q".utf8), x = Array("x".utf8)
        let press = csi("98;5u"), repeated = csi("98;5:2u"), release = csi("98;5:3u"), kittyQ = csi("113u")
        let pastedText: [UInt8] = [0x61, ctrlB, 0x71]
        let legacy: [Typing] = [
            Typing(name: "Ctrl+B q", keys: [[b], [q]]),
            Typing(name: "Ctrl+B Ctrl+B", keys: [[b], [b]]),
            Typing(name: "Ctrl+B x", keys: [[b], [x]]),
            Typing(name: "Ctrl+B held, then q", keys: [[b], [b], [b], [q]]),
            Typing(name: "ESC 0x02 q", keys: [[[esc, ctrlB]], [q]]),
        ]
        let kitty: [Typing] = [
            Typing(name: "kitty Ctrl+B press, release, q (> 7 u)", keys: [[press], [release], [kittyQ]]),
            Typing(name: "kitty Ctrl+B press, q as text (> 1 u)", keys: [[press], [q]]),
            Typing(name: "kitty Ctrl+B held: press, repeats, release, q", keys: [[press], [repeated], [repeated], [release], [kittyQ]]),
            Typing(name: "kitty Ctrl+B held without event types: presses, q", keys: [[press], [press], [q]]),
            Typing(name: "kitty Ctrl+B with Caps Lock, q", keys: [[csi("98;69u")], [csi("113;65u")]]),
            Typing(name: "modifyOtherKeys Ctrl+B, q", keys: [[csi("27;5;98~")], [q]]),
            Typing(name: "kitty Ctrl+B, Ctrl+B", keys: [[press], [press]]),
        ]
        let pastes: [Typing] = [
            Typing(name: "a paste with 0x02 q in it, in one write (a drop)", keys: [[paste(pastedText)], [q]]),
            Typing(name: "a ⌘V paste with 0x02 q in it, in three writes", keys: [[csi("200~"), pastedText, csi("201~")], [q]]),
            Typing(name: "Ctrl+B, then a paste with 0x02 q in it", keys: [[b], [csi("200~"), pastedText, csi("201~")]]),
            Typing(name: "kitty Ctrl+B, then a paste with 0x02 q in it", keys: [[press], [csi("200~"), pastedText, csi("201~")]]),
        ]
        let other: [Typing] = [
            Typing(name: "plain typing", keys: [[Array("h".utf8)], [Array("i".utf8)], [[0x0d]]]),
            Typing(name: "kitty Ctrl+Shift+B, q", keys: [[csi("98:2;6u")], [kittyQ]]),
            Typing(name: "kitty Ctrl+Alt+B, q", keys: [[csi("98;7u")], [kittyQ]]),
        ]

        func run09(_ typing: Typing, escaping: Bool) -> Herdr09 {
            var herdr = Herdr09()
            for write in typing.written(escaping: escaping) { herdr.read(write) }
            return herdr
        }
        func run082(_ typing: Typing, escaping: Bool) -> Herdr082 {
            var herdr = Herdr082()
            for write in typing.written(escaping: escaping) { herdr.read(write) }
            return herdr
        }

        // The bug: without the escaping, Ctrl+B q ends the attach.
        check(run09(legacy[0], escaping: false).detached, "herdr 0.9 without the escaping: Ctrl+B q detaches")
        check(run082(legacy[0], escaping: false).detached, "herdr 0.8.2 without the escaping: Ctrl+B q detaches")
        check(run09(kitty[0], escaping: false).detached, "herdr 0.9 without the escaping: kitty Ctrl+B press, release, q detaches")
        check(run09(kitty[4], escaping: false).detached, "herdr 0.9 without the escaping: kitty Ctrl+B with Caps Lock, q detaches")
        check(run09(kitty[5], escaping: false).detached, "herdr 0.9 without the escaping: modifyOtherKeys Ctrl+B q detaches")
        check(run09(legacy[4], escaping: false).detached, "herdr 0.9 without the escaping: ESC 0x02 q detaches")
        let lone = run09(Typing(name: "Ctrl+B", keys: [[b]]), escaping: false)
        check(lone.pane.isEmpty && !lone.detached, "herdr 0.9 without the escaping: a Ctrl+B alone reaches nothing yet")
        let kittyPair = run09(kitty[6], escaping: false)
        check(kittyPair.pane == press, "herdr 0.9 without the escaping: kitty Ctrl+B Ctrl+B gives the pane one Ctrl+B")

        // With it, herdr 0.9 gives the pane exactly what the view sent, and never detaches.
        for typing in legacy + kitty + pastes + other {
            let herdr = run09(typing, escaping: true)
            check(!herdr.detached, "herdr 0.9: \(typing.name) doesn't detach")
            check(herdr.pane == typing.sent, "herdr 0.9: the pane gets the bytes of \(typing.name)")
            check(herdr.waiting.isEmpty, "herdr 0.9: nothing of \(typing.name) is held")
        }
        let single = run09(Typing(name: "Ctrl+B", keys: [[b]]), escaping: true)
        check(single.pane == b, "herdr 0.9: a Ctrl+B alone reaches the pane at once")
        let kittySingle = run09(Typing(name: "kitty Ctrl+B", keys: [[press]]), escaping: true)
        check(kittySingle.pane == press, "herdr 0.9: a kitty Ctrl+B alone reaches the pane at once, as the program asked for it")
        // herdr reads stdin in any pieces: a write cut in two, or two writes in one read, give the same.
        for typing in legacy + kitty + pastes {
            var whole = Herdr09(), bytewise = Herdr09()
            let written = typing.written(escaping: true).flatMap { $0 }
            whole.read(written)
            for byte in written { bytewise.read([byte]) }
            check(whole.pane == typing.sent && bytewise.pane == typing.sent && !whole.detached && !bytewise.detached, "herdr 0.9: \(typing.name) read in one piece or byte by byte")
        }
        // The paste stays whole for herdr: it is forwarded as one chunk.
        var pasted = Herdr09()
        for write in Typing(name: "", keys: [[csi("200~"), pastedText, csi("201~")]]).written(escaping: true) { pasted.read(write) }
        check(pasted.pane == paste(pastedText), "herdr 0.9: a ⌘V paste's text reaches the pane unchanged, its 0x02 once")

        // herdr 0.8.2 and older: the 0x02 byte is the prefix, and nothing else.
        for typing in legacy {
            let herdr = run082(typing, escaping: true)
            check(!herdr.detached && herdr.pane == typing.sent, "herdr 0.8.2: \(typing.name) doesn't detach and the pane gets its bytes")
        }
        for typing in other {
            let herdr = run082(typing, escaping: true)
            check(!herdr.detached && herdr.pane == typing.sent, "herdr 0.8.2: \(typing.name) is unchanged")
        }
        // Its known limits (see HerdrAttachInput): a kitty Ctrl+B reaches
        // the pane twice, and a 0x02 in a paste still starts the prefix,
        // as it did before.
        let kittyOld = run082(kitty[0], escaping: true)
        check(!kittyOld.detached && kittyOld.pane == press + press + release + kittyQ, "herdr 0.8.2: a kitty Ctrl+B press reaches the pane twice")
        check(run082(kitty[0], escaping: false).pane == kitty[0].sent, "herdr 0.8.2 without the escaping: a kitty Ctrl+B reached the pane once")
        check(run082(pastes[0], escaping: true).detached && run082(pastes[0], escaping: false).detached, "herdr 0.8.2: 0x02 q in a paste detaches, with or without the escaping")
    }
}
