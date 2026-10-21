import CryptoKit
import Foundation

// The messages a device and a Mac exchange over the pairing listener's TCP
// connection (SHPHRD-77, "기기→Mac 경로"), and their encryption: HPKE
// (RFC 9180) in PSK mode with DHKEM(X25519)/HKDF-SHA256/ChaCha20-Poly1305.
// The QR code gives the device the Mac's one-off X25519 public key and a
// 32-byte secret, so the first message is readable only by that Mac, and
// only someone who saw that code could have written it. Both sides take the
// same six-digit confirmation code from the HPKE context, which a person
// compares on the two screens before approving on the Mac.
//
// Every message is a frame: a big-endian `uint32` length and that many bytes
// of body, 8 KiB at most. A body starts with `SHP1`, a type byte and the
// 16-byte session ID of the code it belongs to.
//
//   M1, device → Mac: header, the 32-byte encapsulated key, then the HPKE
//       seal of a `PairingRequest` (sequence 0), with the header and the
//       encapsulated key as associated data.
//   M2, Mac → device: header, then a `PairingResponse` sealed with
//       ChaCha20-Poly1305 under a key exported from the HPKE context — HPKE
//       itself only goes from sender to recipient.
//   M3, device → Mac: header, then the HPKE seal of a `PairingReport`
//       (sequence 1).
//   Failure, Mac → device: header and one byte saying why, unencrypted: it
//       is sent when there is no context to encrypt with (a code already
//       used, expired, unknown), and only ends the attempt.
//
// The encrypted contents are JSON, so that later versions can add to them.

public nonisolated enum PairingProtocol {
    public static let header = Data("SHP1".utf8)
    /// Of a frame's body.
    public static let maximumMessageLength = 8 * 1024
    public static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    public static let sessionIDLength = 16
    public static let presharedKeyLength = 32
    /// X25519's encapsulated key is its ephemeral public key.
    static let encapsulatedKeyLength = 32

    static let infoLabel = "shepherd-pair v1"
    static let confirmationContext = Data("shepherd-pair v1 sas".utf8)
    static let responseKeyContext = Data("shepherd-pair v1 m2".utf8)

    /// HPKE's `info`: the protocol's label and the session ID, so that a
    /// context belongs to one code.
    static func info(sessionID: Data) -> Data {
        Data(infoLabel.utf8) + sessionID
    }

    /// `body` with its length in front.
    public static func frame(_ body: Data) throws -> Data {
        guard body.count <= maximumMessageLength else { throw PairingProtocolError.tooLong }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    /// A failure message for `sessionID`, framed.
    public static func failure(_ reason: PairingFailure, sessionID: Data) throws -> Data {
        try frame(PairingEnvelope.header(type: .failure, sessionID: sessionID) + Data([reason.rawValue]))
    }

    /// The six-digit code: four bytes exported from the context with the
    /// label `shepherd-pair v1 sas`, as a big-endian number, modulo 10⁶.
    static func confirmationCode(from exported: SymmetricKey) -> PairingConfirmationCode {
        let number = exported.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        return PairingConfirmationCode(value: number % 1_000_000)
    }
}

public nonisolated enum PairingMessageType: UInt8, Sendable {
    case request = 1
    case response = 2
    case report = 3
    case failure = 0x7F
}

/// Why the Mac ended an attempt without an encrypted answer.
public nonisolated enum PairingFailure: UInt8, Sendable {
    /// The code's first request has come already — perhaps from someone
    /// else who saw the code.
    case alreadyUsed = 1
    case expired = 2
    /// No code the Mac is showing has this session ID.
    case unknownSession = 3
    /// The Mac stopped pairing, or turned down too many requests for this code.
    case closed = 4
}

/// The confirmation code both screens show.
public nonisolated struct PairingConfirmationCode: Hashable, Sendable, CustomStringConvertible {
    /// 0 to 999 999.
    public let value: UInt32

    /// Six digits, zeros in front included.
    public var digits: String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 6 - text.count)) + text
    }

    /// "482 913".
    public var description: String {
        "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

/// A frame's body, split into its header and the rest.
public nonisolated struct PairingEnvelope: Sendable {
    public let type: PairingMessageType
    public let sessionID: Data
    /// What follows the header.
    public let content: Data

    public init(body: Data) throws {
        let bytes = Data(body)
        let headerLength = PairingProtocol.header.count + 1 + PairingProtocol.sessionIDLength
        guard bytes.count >= headerLength, bytes.prefix(PairingProtocol.header.count) == PairingProtocol.header else {
            throw PairingProtocolError.unreadable
        }
        guard let type = PairingMessageType(rawValue: bytes[bytes.startIndex + PairingProtocol.header.count]) else {
            throw PairingProtocolError.unreadable
        }
        self.type = type
        sessionID = Data(bytes.dropFirst(PairingProtocol.header.count + 1).prefix(PairingProtocol.sessionIDLength))
        content = Data(bytes.dropFirst(headerLength))
    }

    /// The failure's reason, for a failure message.
    public var failure: PairingFailure? {
        guard type == .failure, content.count == 1 else { return nil }
        return PairingFailure(rawValue: content[content.startIndex])
    }

    var headerBytes: Data {
        Self.header(type: type, sessionID: sessionID)
    }

    static func header(type: PairingMessageType, sessionID: Data) -> Data {
        PairingProtocol.header + Data([type.rawValue]) + sessionID
    }
}

/// Collects frames off the connection as its bytes arrive.
public nonisolated struct PairingFrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    /// The frames `bytes` completed. Throws as soon as a frame says it is
    /// longer than `PairingProtocol.maximumMessageLength`, before its body
    /// arrives, so that the connection can be dropped.
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) throws -> [Data] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= PairingProtocol.maximumMessageLength else { throw PairingProtocolError.tooLong }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

/// M1's contents: who is asking, and the key to let in.
public nonisolated struct PairingRequest: Codable, Hashable, Sendable {
    public static let maximumNameLength = 64

    public var deviceID: UUID
    /// The name the person gave the device, shown on the Mac.
    public var deviceName: String
    /// "iPhone", "iPad".
    public var deviceModel: String
    public var appVersion: String
    /// The device key's SSH wire form (`SecureEnclaveSSHKey.publicKeyBlob`).
    public var publicKey: Data

    public init(deviceID: UUID, deviceName: String, deviceModel: String, appVersion: String, publicKey: Data) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.publicKey = publicKey
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case deviceModel = "device_model"
        case appVersion = "app_version"
        case publicKey = "public_key"
    }

    /// The names are what the Mac shows and writes down: one line, 64
    /// characters at most, no control characters. The key must be a P-256
    /// SSH key.
    func validated() throws -> PairingRequest {
        for text in [deviceName, deviceModel, appVersion] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= Self.maximumNameLength,
                  trimmed.unicodeScalars.allSatisfy({ ![.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }) else {
                throw PairingProtocolError.invalidRequest
            }
        }
        guard (try? SSHP256PublicKey.publicKey(fromBlob: publicKey)) != nil else { throw PairingProtocolError.invalidRequest }
        var request = self
        request.deviceName = deviceName.trimmingCharacters(in: .whitespaces)
        request.deviceModel = deviceModel.trimmingCharacters(in: .whitespaces)
        request.appVersion = appVersion.trimmingCharacters(in: .whitespaces)
        return request
    }
}

/// M2's contents: the Mac's answer.
public nonisolated struct PairingResponse: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case approved
        case rejected
    }

    public var decision: Decision
    /// The Mac's installation ID, as in the code.
    public var macID: UUID

    public init(decision: Decision, macID: UUID) {
        self.decision = decision
        self.macID = macID
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case macID = "mac_id"
    }
}

/// M3's contents: how the device's first connection went.
public nonisolated struct PairingReport: Codable, Hashable, Sendable {
    public var sshConnected: Bool
    public var herdrReached: Bool
    /// What went wrong, in the device's words, when something did.
    public var failure: String?

    public init(sshConnected: Bool, herdrReached: Bool, failure: String? = nil) {
        self.sshConnected = sshConnected
        self.herdrReached = herdrReached
        self.failure = failure
    }

    enum CodingKeys: String, CodingKey {
        case sshConnected = "ssh_connected"
        case herdrReached = "herdr_reached"
        case failure
    }
}

/// The device's end: seals M1 and M3 for the Mac in the code, opens M2.
public nonisolated struct PairingDeviceChannel: Sendable {
    public let sessionID: Data
    public let confirmationCode: PairingConfirmationCode
    private var sender: HPKE.Sender
    private let responseKey: SymmetricKey
    private var sentRequest = false

    public init(payload: PairingPayload) throws {
        try self.init(sessionID: payload.sessionID, presharedKey: payload.presharedKey, macPublicKey: payload.macPublicKey)
    }

    public init(sessionID: Data, presharedKey: Data, macPublicKey: Data) throws {
        guard sessionID.count == PairingProtocol.sessionIDLength, presharedKey.count == PairingProtocol.presharedKeyLength,
              let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicKey) else {
            throw PairingProtocolError.unreadable
        }
        self.sessionID = sessionID
        sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: PairingProtocol.ciphersuite,
                                 info: PairingProtocol.info(sessionID: sessionID),
                                 presharedKey: SymmetricKey(data: presharedKey), presharedKeyIdentifier: sessionID)
        confirmationCode = PairingProtocol.confirmationCode(
            from: try sender.exportSecret(context: PairingProtocol.confirmationContext, outputByteCount: 4))
        responseKey = try sender.exportSecret(context: PairingProtocol.responseKeyContext, outputByteCount: 32)
    }

    /// M1, framed. Only once, and before `report`.
    public mutating func request(_ request: PairingRequest) throws -> Data {
        guard !sentRequest else { throw PairingProtocolError.outOfOrder }
        let header = PairingEnvelope.header(type: .request, sessionID: sessionID) + sender.encapsulatedKey
        let sealed = try sender.seal(try JSONEncoder().encode(request), authenticating: header)
        sentRequest = true
        return try PairingProtocol.frame(header + sealed)
    }

    /// M2's answer. Throws for a message of another type or session, or one
    /// that doesn't open under this context.
    public func openResponse(_ envelope: PairingEnvelope) throws -> PairingResponse {
        guard envelope.sessionID == sessionID else { throw PairingProtocolError.wrongSession }
        guard envelope.type == .response else {
            if let failure = envelope.failure { throw PairingProtocolError.failed(failure) }
            throw PairingProtocolError.unreadable
        }
        guard let box = try? ChaChaPoly.SealedBox(combined: envelope.content),
              let plain = try? ChaChaPoly.open(box, using: responseKey, authenticating: envelope.headerBytes),
              let response = try? JSONDecoder().decode(PairingResponse.self, from: plain) else {
            throw PairingProtocolError.unreadable
        }
        return response
    }

    /// M3, framed. After `request`.
    public mutating func report(_ report: PairingReport) throws -> Data {
        guard sentRequest else { throw PairingProtocolError.outOfOrder }
        let header = PairingEnvelope.header(type: .report, sessionID: sessionID)
        let sealed = try sender.seal(try JSONEncoder().encode(report), authenticating: header)
        return try PairingProtocol.frame(header + sealed)
    }
}

/// The Mac's end: opens M1 and M3 with the code's private key and secret,
/// seals M2.
public nonisolated struct PairingMacChannel: Sendable {
    public let sessionID: Data
    public let confirmationCode: PairingConfirmationCode
    private var recipient: HPKE.Recipient
    private let responseKey: SymmetricKey

    /// Opens M1 for the code `sessionID`, `presharedKey` and `privateKey`
    /// were made for. Throws `wrongSession` for another code's message, and
    /// `unreadable` for one that doesn't open — a wrong secret, a changed
    /// byte — or whose request isn't acceptable.
    public static func open(request envelope: PairingEnvelope, sessionID: Data, presharedKey: Data,
                            privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> (channel: PairingMacChannel, request: PairingRequest) {
        guard envelope.sessionID == sessionID else { throw PairingProtocolError.wrongSession }
        guard envelope.type == .request, envelope.content.count > PairingProtocol.encapsulatedKeyLength,
              presharedKey.count == PairingProtocol.presharedKeyLength else {
            throw PairingProtocolError.unreadable
        }
        let encapsulatedKey = Data(envelope.content.prefix(PairingProtocol.encapsulatedKeyLength))
        let sealed = Data(envelope.content.dropFirst(PairingProtocol.encapsulatedKeyLength))
        do {
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: PairingProtocol.ciphersuite,
                                               info: PairingProtocol.info(sessionID: sessionID), encapsulatedKey: encapsulatedKey,
                                               presharedKey: SymmetricKey(data: presharedKey), presharedKeyIdentifier: sessionID)
            let plain = try recipient.open(sealed, authenticating: envelope.headerBytes + encapsulatedKey)
            let request = try JSONDecoder().decode(PairingRequest.self, from: plain).validated()
            let channel = PairingMacChannel(
                sessionID: sessionID,
                confirmationCode: PairingProtocol.confirmationCode(
                    from: try recipient.exportSecret(context: PairingProtocol.confirmationContext, outputByteCount: 4)),
                recipient: recipient,
                responseKey: try recipient.exportSecret(context: PairingProtocol.responseKeyContext, outputByteCount: 32))
            return (channel, request)
        } catch PairingProtocolError.invalidRequest {
            throw PairingProtocolError.invalidRequest
        } catch {
            throw PairingProtocolError.unreadable
        }
    }

    private init(sessionID: Data, confirmationCode: PairingConfirmationCode, recipient: HPKE.Recipient, responseKey: SymmetricKey) {
        self.sessionID = sessionID
        self.confirmationCode = confirmationCode
        self.recipient = recipient
        self.responseKey = responseKey
    }

    /// M2, framed.
    public func response(_ response: PairingResponse) throws -> Data {
        let header = PairingEnvelope.header(type: .response, sessionID: sessionID)
        let sealed = try ChaChaPoly.seal(try JSONEncoder().encode(response), using: responseKey, authenticating: header)
        return try PairingProtocol.frame(header + sealed.combined)
    }

    /// M3's report.
    public mutating func openReport(_ envelope: PairingEnvelope) throws -> PairingReport {
        guard envelope.sessionID == sessionID else { throw PairingProtocolError.wrongSession }
        guard envelope.type == .report,
              let plain = try? recipient.open(envelope.content, authenticating: envelope.headerBytes),
              let report = try? JSONDecoder().decode(PairingReport.self, from: plain) else {
            throw PairingProtocolError.unreadable
        }
        return report
    }
}

public nonisolated enum PairingProtocolError: Error, Equatable, LocalizedError {
    case tooLong
    /// Not a message of this protocol, or one that doesn't open: a wrong
    /// secret, or bytes changed on the way.
    case unreadable
    case wrongSession
    case invalidRequest
    case outOfOrder
    /// The Mac's failure message.
    case failed(PairingFailure)

    public var errorDescription: String? {
        switch self {
        case .tooLong, .unreadable, .wrongSession, .invalidRequest, .outOfOrder:
            String(localized: "The pairing message couldn't be read.", bundle: .shepherdKit)
        case .failed(.alreadyUsed):
            String(localized: "This QR code was already used. Show a new one on the Mac and scan it.", bundle: .shepherdKit)
        case .failed(.expired):
            String(localized: "This pairing code has expired. Show a new one on the Mac.", bundle: .shepherdKit)
        case .failed(.unknownSession), .failed(.closed):
            String(localized: "The Mac isn't showing this QR code anymore. Show a new one on the Mac and scan it.", bundle: .shepherdKit)
        }
    }
}
