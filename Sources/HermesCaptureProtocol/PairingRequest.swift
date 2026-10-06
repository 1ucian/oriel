import CryptoKit
import Foundation

public struct PairingRequestPayload: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let pairingNonce: Data
    public let clientKeyAgreementPublicKey: Data
    public let clientSigningPublicKey: Data
    public let deviceName: String
    public let requestedCapabilities: Set<SessionCapability>
    public let createdAt: Date

    public init(
        protocolVersion: UInt16 = PairingPayload.currentProtocolVersion,
        pairingNonce: Data,
        clientKeyAgreementPublicKey: Data,
        clientSigningPublicKey: Data,
        deviceName: String,
        requestedCapabilities: Set<SessionCapability>,
        createdAt: Date = .now
    ) {
        self.protocolVersion = protocolVersion
        self.pairingNonce = pairingNonce
        self.clientKeyAgreementPublicKey = clientKeyAgreementPublicKey
        self.clientSigningPublicKey = clientSigningPublicKey
        self.deviceName = deviceName
        self.requestedCapabilities = requestedCapabilities
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case pairingNonce
        case clientKeyAgreementPublicKey
        case clientSigningPublicKey
        case deviceName
        case requestedCapabilities
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(UInt16.self, forKey: .protocolVersion)
        pairingNonce = try container.decode(Data.self, forKey: .pairingNonce)
        clientKeyAgreementPublicKey = try container.decode(
            Data.self,
            forKey: .clientKeyAgreementPublicKey
        )
        clientSigningPublicKey = try container.decode(
            Data.self,
            forKey: .clientSigningPublicKey
        )
        deviceName = try container.decode(String.self, forKey: .deviceName)
        requestedCapabilities = Set(
            try container.decode(
                [SessionCapability].self,
                forKey: .requestedCapabilities
            )
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(pairingNonce, forKey: .pairingNonce)
        try container.encode(
            clientKeyAgreementPublicKey,
            forKey: .clientKeyAgreementPublicKey
        )
        try container.encode(
            clientSigningPublicKey,
            forKey: .clientSigningPublicKey
        )
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(
            requestedCapabilities.sorted { $0.rawValue < $1.rawValue },
            forKey: .requestedCapabilities
        )
        try container.encode(createdAt, forKey: .createdAt)
    }

    fileprivate func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct SignedPairingRequest: Codable, Equatable, Sendable {
    public static let maximumAge: TimeInterval = 60

    public let payload: PairingRequestPayload
    public let signature: Data

    public init(payload: PairingRequestPayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public static func sign(
        _ payload: PairingRequestPayload,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        guard privateKey.publicKey.rawRepresentation
            == payload.clientSigningPublicKey else {
            throw PairingError.invalidPublicKey
        }
        return Self(
            payload: payload,
            signature: try privateKey.signature(for: payload.canonicalData())
        )
    }

    @discardableResult
    public func verify(
        expectedNonce: Data,
        at now: Date = .now
    ) throws -> Bool {
        guard payload.protocolVersion == PairingPayload.currentProtocolVersion else {
            throw PairingError.unsupportedProtocol
        }
        guard payload.pairingNonce == expectedNonce,
              (16...64).contains(payload.pairingNonce.count) else {
            throw PairingError.invalidNonce
        }
        guard payload.clientKeyAgreementPublicKey.count == 32,
              payload.clientSigningPublicKey.count == 32 else {
            throw PairingError.invalidPublicKey
        }
        guard (1...63).contains(payload.deviceName.utf8.count) else {
            throw PairingError.invalidServiceName
        }
        guard payload.createdAt <= now,
              now.timeIntervalSince(payload.createdAt) <= Self.maximumAge else {
            throw PairingError.expired
        }
        guard !payload.requestedCapabilities.isEmpty,
              payload.requestedCapabilities.isSubset(
                of: SessionCapability.approvable
              ) else {
            throw PeerSessionError.capabilityDenied
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(
                rawRepresentation: payload.clientSigningPublicKey
            )
        } catch {
            throw PairingError.invalidPublicKey
        }
        guard publicKey.isValidSignature(
            signature,
            for: try payload.canonicalData()
        ) else {
            throw PairingError.invalidSignature
        }
        return true
    }
}

public enum PairingHandshakeCodec {
    public static let maximumBytes = 8 * 1_024

    public static func encode(_ request: SignedPairingRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(request)
        guard payload.count <= maximumBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        var size = UInt32(payload.count).bigEndian
        var framed = Data(capacity: 4 + payload.count)
        Swift.withUnsafeBytes(of: &size) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    public static func decode(_ framed: Data) throws -> SignedPairingRequest {
        guard framed.count >= 4 else { throw PeerSessionError.invalidPacket }
        var size: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &size) {
            framed.copyBytes(to: $0, from: 0..<4)
        }
        let count = Int(UInt32(bigEndian: size))
        guard count <= maximumBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        guard framed.count == count + 4 else {
            throw PeerSessionError.invalidPacket
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(
                SignedPairingRequest.self,
                from: framed.dropFirst(4)
            )
        } catch {
            throw PeerSessionError.invalidPacket
        }
    }
}
