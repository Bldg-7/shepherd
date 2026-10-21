#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The pairing code's text as a QR code. Core Image picks the encoding
/// itself; the text, base64url with lower-case letters, goes in byte mode,
/// and medium error correction (15%) leaves room for a glare on a screen.
nonisolated enum PairingQRCode {
    static let correctionLevel = "M"

    /// One pixel per module, black on white, with Core Image's own quiet
    /// zone; nil when the text is too long for a QR code.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }

    /// The text of the QR codes Core Image finds in `image`, for the tests
    /// that read a code back.
    static func messages(in image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
#endif
