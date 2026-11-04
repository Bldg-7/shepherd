/// Generation-1 canonical terminal IDs, never mutable labels. An ID identifies
/// an API object; it is not native-session, browser or credential authority.
public nonisolated enum CoreTerminalID {
    public static func isCanonical(_ value: String) -> Bool {
        let bytes = Array(value.utf8), alphabet = Array("0123456789bcdfghjkmnpqrstvwxyz".utf8)
        guard bytes.count >= 2, bytes.count <= 9, bytes[0] == 116, (49...57).contains(bytes[1]) else { return false }
        var rest = UInt64(bytes[1] - 49), before: UInt64 = 0, size: UInt64 = 9
        for byte in bytes.dropFirst(2) {
            guard let digit = alphabet.firstIndex(of: byte) else { return false }
            rest = rest * 30 + UInt64(digit); before += size; size *= 30
            if before + rest + 1 > UInt32.max { return false }
        }
        return before + rest + 1 <= UInt32.max
    }
}
