import CryptoKit
import Foundation

/// The SSH wire form of an `ecdsa-sha2-nistp256` public key (RFC 5656 3.1):
/// `string "ecdsa-sha2-nistp256"`, `string "nistp256"`, `string Q`, where Q
/// is the uncompressed point, 65 bytes. It is what goes in base64 in an
/// `authorized_keys` line, and what a fingerprint is taken of.
public nonisolated enum SSHP256PublicKey {
    public static let keyType = "ecdsa-sha2-nistp256"
    private static let curveName = "nistp256"

    public static func blob(for key: P256.Signing.PublicKey) -> Data {
        var blob = Data()
        appendString(Data(keyType.utf8), to: &blob)
        appendString(Data(curveName.utf8), to: &blob)
        appendString(key.x963Representation, to: &blob)
        return blob
    }

    /// The key in `blob`, which must be exactly the three fields above with
    /// a point on the curve, and nothing after them.
    public static func publicKey(fromBlob blob: Data) throws -> P256.Signing.PublicKey {
        var reader = SSHFieldReader(Array(blob))
        guard let type = reader.readString(), type.elementsEqual(keyType.utf8),
              let curve = reader.readString(), curve.elementsEqual(curveName.utf8),
              let point = reader.readString(), point.count == 65, point.first == 0x04,
              reader.isAtEnd,
              let key = try? P256.Signing.PublicKey(x963Representation: point) else {
            throw AuthorizedKeyLineError.notAP256Key
        }
        return key
    }

    private static func appendString(_ bytes: Data, to blob: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(bytes)
    }
}

/// `SHA256:` and the base64 SHA-256 of a public key blob — the form
/// `HostKeyFingerprint.compute` gives and `Machine.pinnedHostKeyFingerprint`
/// holds (with base64's padding, unlike `ssh-keygen -l`).
public nonisolated enum SSHKeyFingerprint {
    public static func sha256(ofBlob blob: Data) -> String {
        sha256(digest: Data(SHA256.hash(data: blob)))
    }

    public static func sha256(digest: Data) -> String {
        "SHA256:" + digest.base64EncodedString()
    }
}

/// The line the Mac adds to `~/.ssh/authorized_keys` for a paired device
/// (SHPHRD-77, "Mac에서의 허가"):
///
///     restrict,port-forwarding ecdsa-sha2-nistp256 AAAA… shepherd-mobile:<8>:<slug>
///
/// `restrict` turns off everything optional — forwarding, a PTY, agent and X11
/// forwarding, `~/.ssh/rc` — and `port-forwarding` turns forwarding back on,
/// which `direct-streamlocal` (the channel herdr.sock is reached through)
/// needs. The key is the one the device sent, parsed and written out again
/// rather than copied, so the line holds nothing the device chose but the
/// key itself; the comment is the Mac's own marker, which is how the line is
/// found again to remove it. Writing the file is the Mac app's (with the
/// checks it needs); this is only the text.
public nonisolated struct AuthorizedKeyLine: Hashable, Sendable {
    public static let options = "restrict,port-forwarding"
    public static let markerPrefix = "shepherd-mobile"
    /// The most characters of the device's name the marker keeps.
    public static let maximumSlugLength = 32

    /// The device key's SSH wire form, re-encoded from the parsed key.
    public let keyBlob: Data
    /// `shepherd-mobile:<first 8 characters of the device ID>:<slug of its name>`.
    public let marker: String

    /// `devicePublicKey` is the SSH wire form the device sent; it must be a
    /// P-256 key (see `SSHP256PublicKey.publicKey(fromBlob:)`).
    public init(devicePublicKey: Data, deviceID: UUID, deviceName: String) throws {
        let key = try SSHP256PublicKey.publicKey(fromBlob: devicePublicKey)
        keyBlob = SSHP256PublicKey.blob(for: key)
        marker = "\(Self.markerPrefix):\(Self.shortID(deviceID)):\(Self.slug(for: deviceName))"
    }

    /// The line, without a newline.
    public var text: String {
        "\(Self.options) \(SSHP256PublicKey.keyType) \(keyBlob.base64EncodedString()) \(marker)"
    }

    public var fingerprint: String {
        SSHKeyFingerprint.sha256(ofBlob: keyBlob)
    }

    /// Whether `line` is this line, as far as removing it goes: the same key
    /// and the same marker. Options are not compared, so a line someone
    /// tightened by hand is still found; a line with the same key and another
    /// comment is not this one and is left alone.
    public func matches(_ line: String) -> Bool {
        guard let entry = AuthorizedKeysEntry(line: line) else { return false }
        return entry.keyBlob == keyBlob && entry.comment == marker
    }

    /// Whether `line` holds this key at all, whatever its options and comment:
    /// a key already there isn't added a second time.
    public func hasSameKey(as line: String) -> Bool {
        AuthorizedKeysEntry(line: line)?.keyBlob == keyBlob
    }

    /// The device ID's first eight characters, lower-case.
    public static func shortID(_ deviceID: UUID) -> String {
        String(deviceID.uuidString.lowercased().prefix(8))
    }

    /// The device's name as lower-case ASCII letters, digits and hyphens:
    /// accents dropped, every other run of characters one hyphen, none at
    /// either end, `maximumSlugLength` at most; "device" when nothing is left.
    /// It keeps the comment one word that a person reading the file can tell
    /// apart, without anything a shell or an editor would trip on.
    public static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var slug = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingHyphen && !slug.isEmpty { slug.append("-") }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if slug.count > maximumSlugLength {
            slug = String(slug.prefix(maximumSlugLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "device" : slug
    }
}

/// One key line of an `authorized_keys` file, as sshd reads it (sshd(8),
/// "AUTHORIZED_KEYS FILE FORMAT"): options, if any, the key type, the key in
/// base64, and a comment.
public nonisolated struct AuthorizedKeysEntry: Hashable, Sendable {
    /// Nil when the line has none.
    public let options: String?
    public let keyType: String
    public let keyBlob: Data
    /// What follows the key, trimmed; empty when nothing does.
    public let comment: String

    /// Nil for a blank line, a comment line, or one that isn't a key line.
    public init?(line: String) {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        while let last = rest.last, last.isNewline { rest = rest.dropLast() }
        guard !rest.isEmpty, rest.first != "#" else { return nil }

        var options: String?
        if !Self.isKeyType(Self.firstWord(of: rest)) {
            // The options run to the first space or tab outside double quotes.
            var inQuotes = false
            var escaped = false
            var end = rest.endIndex
            for index in rest.indices {
                let character = rest[index]
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { inQuotes.toggle(); continue }
                if !inQuotes && (character == " " || character == "\t") { end = index; break }
            }
            guard !inQuotes, end != rest.endIndex else { return nil }
            options = String(rest[..<end])
            rest = rest[end...].drop { $0 == " " || $0 == "\t" }
        }

        let keyType = Self.firstWord(of: rest)
        guard Self.isKeyType(keyType) else { return nil }
        rest = rest.dropFirst(keyType.count).drop { $0 == " " || $0 == "\t" }
        let encoded = Self.firstWord(of: rest)
        guard let blob = Data(base64Encoded: String(encoded)), !blob.isEmpty else { return nil }
        rest = rest.dropFirst(encoded.count)

        self.options = options
        self.keyType = String(keyType)
        keyBlob = blob
        comment = rest.trimmingCharacters(in: .whitespaces)
    }

    private static func firstWord(of text: Substring) -> Substring {
        text.prefix { $0 != " " && $0 != "\t" }
    }

    /// The key types OpenSSH writes: `ssh-…`, `ecdsa-sha2-…` and the
    /// security-key `sk-…` ones, certificates included.
    private static func isKeyType(_ word: Substring) -> Bool {
        word.hasPrefix("ssh-") || word.hasPrefix("ecdsa-sha2-") || word.hasPrefix("sk-")
    }
}

public nonisolated enum AuthorizedKeyLineError: Error, Equatable, LocalizedError {
    case notAP256Key

    public var errorDescription: String? {
        switch self {
        case .notAP256Key:
            String(localized: "The device sent a key that isn't a P-256 SSH public key.", bundle: .shepherdKit)
        }
    }
}

/// Reads SSH wire fields (RFC 4251 5): a `string` is a big-endian `uint32`
/// length and that many bytes.
nonisolated struct SSHFieldReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func readString() -> [UInt8]? {
        guard bytes.count - offset >= 4 else { return nil }
        let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        guard bytes.count - offset - 4 >= length else { return nil }
        let value = Array(bytes[offset + 4..<offset + 4 + length])
        offset += 4 + length
        return value
    }
}
