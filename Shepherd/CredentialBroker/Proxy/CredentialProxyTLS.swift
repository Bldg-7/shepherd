#if os(macOS)
import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL
import Security

// Process-owned ephemeral keys: no file, Keychain, root installation or reuse.
nonisolated final class CredentialProxyTLS: Sendable {
    private let key: P256.Signing.PrivateKey
    private let certificate: Certificate
    let anchorDER: Data

    init(now: Date = Date()) throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("Shepherd ephemeral credential transport") }
        let certificate = try Certificate(version: .v3, serialNumber: .init(bytes: Array(UUID().uuidString.utf8.prefix(20))),
            publicKey: .init(key.publicKey), notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(600), issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            }, issuerPrivateKey: .init(key))
        self.key = key; self.certificate = certificate
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        anchorDER = Data(serializer.serializedBytes)
    }

    func identity(host: String, now: Date = Date()) throws -> (context: NIOSSLContext, leafDER: Data) {
        _ = try CredentialDestination(url: "https://" + host + "/", field: "password")
        let leafKey = P256.Signing.PrivateKey()
        let san: GeneralName
        if let ip = IPv4Address(host) { san = .ipAddress(ASN1OctetString(contentBytes: ip.bytes[...])) }
        else { san = .dnsName(host) }
        let leaf = try Certificate(version: .v3, serialNumber: .init(bytes: Array(UUID().uuidString.utf8.prefix(20))),
            publicKey: .init(leafKey.publicKey), notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: min(certificate.notValidAfter, now.addingTimeInterval(300)),
            issuer: certificate.subject, subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
            }, issuerPrivateKey: .init(key))
        var serializer = DER.Serializer(); try serializer.serialize(leaf)
        let der = Data(serializer.serializedBytes)
        let sslLeaf = try NIOSSLCertificate(bytes: Array(der), format: .der)
        let sslKey = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)
        let config = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(sslLeaf)], privateKey: .privateKey(sslKey))
        return (try NIOSSLContext(configuration: config), der)
    }

    // Host validation does NOT authorize a port, path, query or request method.
    // The exact leaf pin is scoped to the owning engine/profile by the native caller.
    static func verify(chain: [Data], anchor: Data, leaf: Data, hostname: String) -> Bool {
        guard chain.first == leaf, !chain.isEmpty,
              let ca = SecCertificateCreateWithData(nil, anchor as CFData) else { return false }
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard certificates.count == chain.count else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, [ca] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    private struct IPv4Address {
        let bytes: [UInt8]
        init?(_ host: String) {
            let parts = host.split(separator: ".")
            guard parts.count == 4 else { return nil }
            let bytes = parts.compactMap { UInt8($0) }
            guard bytes.count == 4 else { return nil }
            self.bytes = bytes
        }
    }
}
#endif
