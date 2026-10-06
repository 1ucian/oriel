import CryptoKit
import Foundation

public struct TrustedPeerRecord: Codable, Equatable, Sendable, Identifiable {
    public let signingPublicKey: Data
    public let keyAgreementPublicKey: Data
    public let serviceName: String
    public let displayName: String
    public let approvedCapabilities: Set<SessionCapability>
    public let createdAt: Date
    /// How to reach this peer through the relay when the local network does not answer.
    public let reconnectRoute: ReconnectRoute?

    public init(
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        serviceName: String,
        displayName: String,
        approvedCapabilities: Set<SessionCapability>,
        createdAt: Date = .now,
        reconnectRoute: ReconnectRoute? = nil
    ) {
        self.signingPublicKey = signingPublicKey
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.serviceName = serviceName
        self.displayName = displayName
        self.approvedCapabilities = approvedCapabilities
        self.createdAt = createdAt
        self.reconnectRoute = reconnectRoute
    }

    public var id: String {
        SHA256.hash(data: signingPublicKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func validate() throws {
        guard signingPublicKey.count == 32,
              keyAgreementPublicKey.count == 32 else {
            throw PairingError.invalidPublicKey
        }
        guard (1...63).contains(serviceName.utf8.count),
              (1...128).contains(displayName.utf8.count) else {
            throw PairingError.invalidServiceName
        }
        guard !approvedCapabilities.isEmpty,
              approvedCapabilities.isSubset(of: SessionCapability.approvable) else {
            throw PeerSessionError.capabilityDenied
        }
    }

    private enum CodingKeys: String, CodingKey {
        case signingPublicKey
        case keyAgreementPublicKey
        case serviceName
        case displayName
        case approvedCapabilities
        case createdAt
        case reconnectRoute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signingPublicKey = try container.decode(Data.self, forKey: .signingPublicKey)
        keyAgreementPublicKey = try container.decode(Data.self, forKey: .keyAgreementPublicKey)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        displayName = try container.decode(String.self, forKey: .displayName)
        approvedCapabilities = Set(
            try container.decode([SessionCapability].self, forKey: .approvedCapabilities)
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        reconnectRoute = try container.decodeIfPresent(ReconnectRoute.self, forKey: .reconnectRoute)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signingPublicKey, forKey: .signingPublicKey)
        try container.encode(keyAgreementPublicKey, forKey: .keyAgreementPublicKey)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(
            approvedCapabilities.sorted { $0.rawValue < $1.rawValue },
            forKey: .approvedCapabilities
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(reconnectRoute, forKey: .reconnectRoute)
    }
}

public enum ReconnectHandshakePolicy {
    public static let timeoutSeconds: Int64 = 10
    /// Phones and Macs do not share a clock; a real iPhone a few seconds off the Mac must
    /// still reconnect. Challenge lifetimes stay short, so this buys little for a replay.
    public static let clockSkewTolerance: TimeInterval = 30
}

public struct ReconnectChallengePayload: Codable, Equatable, Sendable {
    public static let maximumLifetime: TimeInterval = 60

    public let protocolVersion: UInt16
    public let macKeyAgreementPublicKey: Data
    public let macSigningPublicKey: Data
    public let nonce: Data
    public let issuedAt: Date
    public let expiresAt: Date
    public let serviceName: String

    public init(
        protocolVersion: UInt16 = PairingPayload.currentProtocolVersion,
        macKeyAgreementPublicKey: Data,
        macSigningPublicKey: Data,
        nonce: Data,
        issuedAt: Date = .now,
        expiresAt: Date,
        serviceName: String
    ) {
        self.protocolVersion = protocolVersion
        self.macKeyAgreementPublicKey = macKeyAgreementPublicKey
        self.macSigningPublicKey = macSigningPublicKey
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.serviceName = serviceName
    }

    /// `tolerance` is the clock difference accepted between the issuer and the checker:
    /// the phone passes the handshake policy's skew when it checks a Mac's challenge; the
    /// Mac checks its own challenge against its own clock and passes nothing.
    public func validate(at now: Date = .now, tolerance: TimeInterval = 0) throws {
        guard protocolVersion == PairingPayload.currentProtocolVersion else {
            throw PairingError.unsupportedProtocol
        }
        guard macKeyAgreementPublicKey.count == 32,
              macSigningPublicKey.count == 32 else {
            throw PairingError.invalidPublicKey
        }
        guard (16...64).contains(nonce.count) else {
            throw PairingError.invalidNonce
        }
        guard (1...63).contains(serviceName.utf8.count) else {
            throw PairingError.invalidServiceName
        }
        guard issuedAt <= now.addingTimeInterval(tolerance),
              expiresAt > now.addingTimeInterval(-tolerance),
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= Self.maximumLifetime else {
            throw PairingError.expired
        }
    }

    fileprivate func canonicalData() throws -> Data {
        try ReconnectCoding.encoder.encode(self)
    }
}

public struct SignedReconnectChallenge: Codable, Equatable, Sendable {
    public let payload: ReconnectChallengePayload
    public let signature: Data

    public init(payload: ReconnectChallengePayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public static func sign(
        _ payload: ReconnectChallengePayload,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        guard privateKey.publicKey.rawRepresentation == payload.macSigningPublicKey else {
            throw PairingError.invalidPublicKey
        }
        return Self(
            payload: payload,
            signature: try privateKey.signature(for: payload.canonicalData())
        )
    }

    @discardableResult
    public func verify(
        expectedSigningPublicKey: Data,
        expectedServiceName: String,
        at now: Date = .now
    ) throws -> Bool {
        try payload.validate(at: now, tolerance: ReconnectHandshakePolicy.clockSkewTolerance)
        guard payload.macSigningPublicKey == expectedSigningPublicKey else {
            throw PairingError.invalidPublicKey
        }
        guard payload.serviceName == expectedServiceName else {
            throw PairingError.invalidServiceName
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: expectedSigningPublicKey)
        } catch {
            throw PairingError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signature, for: try payload.canonicalData()) else {
            throw PairingError.invalidSignature
        }
        return true
    }
}

public struct ReconnectRequestPayload: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let challengeNonce: Data
    public let clientKeyAgreementPublicKey: Data
    public let clientSigningPublicKey: Data
    public let deviceName: String
    public let serviceName: String
    public let requestedCapabilities: Set<SessionCapability>
    public let createdAt: Date

    public init(
        protocolVersion: UInt16 = PairingPayload.currentProtocolVersion,
        challengeNonce: Data,
        clientKeyAgreementPublicKey: Data,
        clientSigningPublicKey: Data,
        deviceName: String,
        serviceName: String,
        requestedCapabilities: Set<SessionCapability>,
        createdAt: Date = .now
    ) {
        self.protocolVersion = protocolVersion
        self.challengeNonce = challengeNonce
        self.clientKeyAgreementPublicKey = clientKeyAgreementPublicKey
        self.clientSigningPublicKey = clientSigningPublicKey
        self.deviceName = deviceName
        self.serviceName = serviceName
        self.requestedCapabilities = requestedCapabilities
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case challengeNonce
        case clientKeyAgreementPublicKey
        case clientSigningPublicKey
        case deviceName
        case serviceName
        case requestedCapabilities
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(UInt16.self, forKey: .protocolVersion)
        challengeNonce = try container.decode(Data.self, forKey: .challengeNonce)
        clientKeyAgreementPublicKey = try container.decode(
            Data.self,
            forKey: .clientKeyAgreementPublicKey
        )
        clientSigningPublicKey = try container.decode(
            Data.self,
            forKey: .clientSigningPublicKey
        )
        deviceName = try container.decode(String.self, forKey: .deviceName)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        requestedCapabilities = Set(
            try container.decode([SessionCapability].self, forKey: .requestedCapabilities)
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(challengeNonce, forKey: .challengeNonce)
        try container.encode(
            clientKeyAgreementPublicKey,
            forKey: .clientKeyAgreementPublicKey
        )
        try container.encode(clientSigningPublicKey, forKey: .clientSigningPublicKey)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(
            requestedCapabilities.sorted { $0.rawValue < $1.rawValue },
            forKey: .requestedCapabilities
        )
        try container.encode(createdAt, forKey: .createdAt)
    }

    fileprivate func canonicalData() throws -> Data {
        try ReconnectCoding.encoder.encode(self)
    }
}

public struct SignedReconnectRequest: Codable, Equatable, Sendable {
    public let payload: ReconnectRequestPayload
    public let signature: Data

    public init(payload: ReconnectRequestPayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public static func sign(
        _ payload: ReconnectRequestPayload,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        guard privateKey.publicKey.rawRepresentation == payload.clientSigningPublicKey else {
            throw PairingError.invalidPublicKey
        }
        return Self(
            payload: payload,
            signature: try privateKey.signature(for: payload.canonicalData())
        )
    }

    @discardableResult
    public func verify(
        challenge: ReconnectChallengePayload,
        expectedClientSigningPublicKey: Data,
        at now: Date = .now
    ) throws -> Bool {
        try challenge.validate(at: now)
        guard payload.protocolVersion == PairingPayload.currentProtocolVersion else {
            throw PairingError.unsupportedProtocol
        }
        guard payload.challengeNonce == challenge.nonce else {
            throw PairingError.invalidNonce
        }
        guard payload.clientSigningPublicKey == expectedClientSigningPublicKey,
              payload.clientSigningPublicKey.count == 32,
              payload.clientKeyAgreementPublicKey.count == 32 else {
            throw PairingError.invalidPublicKey
        }
        guard payload.serviceName == challenge.serviceName,
              (1...63).contains(payload.deviceName.utf8.count) else {
            throw PairingError.invalidServiceName
        }
        let skew = ReconnectHandshakePolicy.clockSkewTolerance
        guard payload.createdAt >= challenge.issuedAt.addingTimeInterval(-skew),
              payload.createdAt <= now.addingTimeInterval(skew),
              payload.createdAt < challenge.expiresAt.addingTimeInterval(skew) else {
            throw PairingError.expired
        }
        guard !payload.requestedCapabilities.isEmpty,
              payload.requestedCapabilities.isSubset(of: SessionCapability.approvable) else {
            throw PeerSessionError.capabilityDenied
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: expectedClientSigningPublicKey)
        } catch {
            throw PairingError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signature, for: try payload.canonicalData()) else {
            throw PairingError.invalidSignature
        }
        return true
    }
}

public enum ReconnectCapabilityDecision: Equatable, Sendable {
    case autoApprove
    case requiresApproval

    public static func evaluate(
        requested: Set<SessionCapability>,
        approved: Set<SessionCapability>
    ) throws -> Self {
        guard !requested.isEmpty,
              requested.isSubset(of: SessionCapability.approvable),
              !approved.isEmpty,
              approved.isSubset(of: SessionCapability.approvable) else {
            throw PeerSessionError.capabilityDenied
        }
        return requested.isSubset(of: approved) ? .autoApprove : .requiresApproval
    }
}

public enum ReconnectAuthorization {
    /// Resolves the saved peer allowed to resume a session for `request`, binding
    /// the request to a stored signing *and* key-agreement identity, and to the
    /// service the trust was granted on, before its signature is checked.
    /// Unknown, revoked, renamed, or tampered clients fail closed.
    public static func authorize(
        request: SignedReconnectRequest,
        challenge: ReconnectChallengePayload,
        trustedPeers: [TrustedPeerRecord],
        at now: Date = .now
    ) throws -> TrustedPeerRecord {
        guard let trustedPeer = trustedPeers.first(where: {
            $0.signingPublicKey == request.payload.clientSigningPublicKey
        }) else {
            throw PairingError.invalidPublicKey
        }
        try trustedPeer.validate()
        guard trustedPeer.serviceName == challenge.serviceName else {
            throw PairingError.invalidServiceName
        }
        guard trustedPeer.keyAgreementPublicKey
            == request.payload.clientKeyAgreementPublicKey else {
            throw PairingError.invalidPublicKey
        }
        try request.verify(
            challenge: challenge,
            expectedClientSigningPublicKey: trustedPeer.signingPublicKey,
            at: now
        )
        return trustedPeer
    }
}

public actor ReconnectReplayProtector {
    private var consumedNonces: [Data: Date] = [:]

    public init() {}

    public func consume(
        _ challenge: ReconnectChallengePayload,
        at now: Date = .now
    ) throws {
        try challenge.validate(at: now)
        consumedNonces = consumedNonces.filter { $0.value > now }
        guard consumedNonces[challenge.nonce] == nil else {
            throw PairingError.replayed
        }
        consumedNonces[challenge.nonce] = challenge.expiresAt
    }
}

public enum ReconnectHandshakeCodec {
    public static let maximumBytes = 8 * 1_024

    public static func encode(_ challenge: SignedReconnectChallenge) throws -> Data {
        try encodeValue(challenge)
    }

    public static func encode(_ request: SignedReconnectRequest) throws -> Data {
        try encodeValue(request)
    }

    public static func decodeChallenge(_ framed: Data) throws -> SignedReconnectChallenge {
        try decodeValue(SignedReconnectChallenge.self, from: framed)
    }

    public static func decodeRequest(_ framed: Data) throws -> SignedReconnectRequest {
        try decodeValue(SignedReconnectRequest.self, from: framed)
    }

    private static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let payload = try ReconnectCoding.encoder.encode(value)
        guard payload.count <= maximumBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        var size = UInt32(payload.count).bigEndian
        var framed = Data(capacity: 4 + payload.count)
        Swift.withUnsafeBytes(of: &size) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    private static func decodeValue<T: Decodable>(
        _ type: T.Type,
        from framed: Data
    ) throws -> T {
        guard framed.count >= 4 else { throw PeerSessionError.invalidPacket }
        var size: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &size) {
            framed.copyBytes(to: $0, from: 0..<4)
        }
        let count = Int(UInt32(bigEndian: size))
        guard count <= maximumBytes else { throw PeerSessionError.payloadTooLarge }
        guard framed.count == count + 4 else { throw PeerSessionError.invalidPacket }
        do {
            return try ReconnectCoding.decoder.decode(type, from: Data(framed.dropFirst(4)))
        } catch let error as PeerSessionError {
            throw error
        } catch {
            throw PeerSessionError.invalidPacket
        }
    }
}

private enum ReconnectCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
