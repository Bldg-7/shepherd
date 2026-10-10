import Foundation

// Needs Citadel for `Curve25519.Signing.PrivateKey.makeSSHRepresentation`,
// which writes the OpenSSH private-key container — guarded with `canImport`
// like the rest of HerdrKit's Citadel-backed pieces.
#if canImport(Citadel)
import Citadel
import Crypto

/// A fresh Ed25519 SSH identity generated on-device, so adding a Host never
/// requires already having a key lying around somewhere. The private key
/// never leaves this process — only `authorizedKeysLine` is ever shown, for
/// the user to append to that Host's own `~/.ssh/authorized_keys`.
struct DeviceKey {
    private let key: Curve25519.Signing.PrivateKey

    init() {
        key = Curve25519.Signing.PrivateKey()
    }

    /// OpenSSH-format private key text, the same shape `OpenSSHPrivateKey`
    /// parses back and `MachineStore` stores in the Keychain.
    func privateKeyPEM(comment: String) -> Data {
        Data(key.makeSSHRepresentation(comment: comment).utf8)
    }

    /// One `authorized_keys` line: `ssh-ed25519 <base64> [comment]`.
    func authorizedKeysLine(comment: String) -> String {
        // SSH wire encoding of an ed25519 public key: `string "ssh-ed25519"`
        // then `string <32 raw bytes>`, each length-prefixed big-endian UInt32.
        var blob = Data()
        func writeString(_ bytes: Data) {
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(bytes)
        }
        writeString(Data("ssh-ed25519".utf8))
        writeString(key.publicKey.rawRepresentation)

        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "ssh-ed25519 \(blob.base64EncodedString())"
        return trimmedComment.isEmpty ? line : "\(line) \(trimmedComment)"
    }
}
#endif
