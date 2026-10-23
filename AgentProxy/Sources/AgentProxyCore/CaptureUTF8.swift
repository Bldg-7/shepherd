/// Strict decoding that preserves an in-band BOM and supports iOS 17.
/// Foundation's encoding-based initializer strips a leading BOM, while
/// String(validating:as:) requires iOS 18. Round-tripping the standard UTF-8
/// decoder distinguishes valid input from any replacement of malformed bytes.
nonisolated enum CaptureUTF8 {
    static func decode<Bytes: Collection>(_ bytes: Bytes) -> String? where Bytes.Element == UInt8 {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}
