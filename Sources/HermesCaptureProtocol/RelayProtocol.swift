import CryptoKit
import Foundation
@preconcurrency import Network

public enum RelayError: Error, Equatable, Sendable {
    case invalidRoute
    case expired
    case invalidFrame
    case unsupportedProtocol
    case invalidSignature
    case roleMismatch
    case routeMismatch
    case replayed
}

public enum RelayWireTransport: String, Codable, Equatable, Sendable {
    case tlsTCP
    case secureWebSocket

    static func endpointURL(for route: RelayRoute) -> URL? {
        guard route.transport == .secureWebSocket else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = route.host
        components.port = Int(route.port)
        components.path = "/oriel"
        return components.url
    }

    public func makeConnection(route: RelayRoute) throws -> NWConnection {
        switch self {
        case .tlsTCP:
            let parameters = NWParameters(
                tls: NWProtocolTLS.Options(),
                tcp: NWProtocolTCP.Options()
            )
            parameters.allowLocalEndpointReuse = false
            guard let port = NWEndpoint.Port(rawValue: route.port) else {
                throw RelayError.invalidRoute
            }
            return NWConnection(
                host: NWEndpoint.Host(route.host),
                port: port,
                using: parameters
            )
        case .secureWebSocket:
            guard let url = Self.endpointURL(for: route) else {
                throw RelayError.invalidRoute
            }
            let parameters = NWParameters.tls
            parameters.allowLocalEndpointReuse = false
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(
                webSocket,
                at: 0
            )
            return NWConnection(to: .url(url), using: parameters)
        }
    }

    public func makeSendContext() -> NWConnection.ContentContext {
        guard self == .secureWebSocket else { return .defaultMessage }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        return NWConnection.ContentContext(
            identifier: "oriel.websocket.binary",
            metadata: [metadata]
        )
    }

    public func isExpectedMessage(
        _ context: NWConnection.ContentContext?
    ) -> Bool {
        classify(context) == .payload
    }

    /// What a received message is to the wire protocol. Over TLS/TCP every byte is
    /// protocol; over a WebSocket only binary messages are, while ping and pong frames are
    /// keepalive traffic to read past and a close frame ends the connection.
    public func classify(
        _ context: NWConnection.ContentContext?
    ) -> RelayMessageKind {
        guard self == .secureWebSocket else { return .payload }
        guard let metadata = context?.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata else { return .unexpected }
        switch metadata.opcode {
        case .binary:
            return .payload
        case .ping, .pong:
            return .control
        case .close:
            return .closed
        default:
            return .unexpected
        }
    }

    /// A ping frame to send while a registration waits at the relay. Cloudflare drops a
    /// proxied WebSocket that carries no frame for 100 seconds; the relay answers pings
    /// itself and never sees them as data.
    public func makeKeepaliveContext() -> NWConnection.ContentContext? {
        guard self == .secureWebSocket else { return nil }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        return NWConnection.ContentContext(
            identifier: "oriel.websocket.ping",
            metadata: [metadata]
        )
    }

    /// Well inside the 100 second proxy idle limit.
    public static let keepaliveInterval: TimeInterval = 40
}

public enum RelayMessageKind: Equatable, Sendable {
    /// Protocol bytes.
    case payload
    /// Ping or pong: keep receiving.
    case control
    /// The peer closed the WebSocket.
    case closed
    /// Text or an unknown opcode: not ours.
    case unexpected
}

public struct PairingAttemptGeneration: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public mutating func cancel() {
        generation &+= 1
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

public enum RelayConnectionPreference {
    public static func shouldRetryViaRelay(
        usedRelay: Bool,
        hasRelayRoute: Bool
    ) -> Bool {
        !usedRelay && hasRelayRoute
    }

    public static func shouldForceRelay(
        environment: [String: String],
        hasRelayRoute: Bool
    ) -> Bool {
        #if DEBUG
        return hasRelayRoute && environment["ORIEL_FORCE_RELAY"] == "1"
        #else
        return false
        #endif
    }

    public static func shouldAdvertiseDirect(
        environment: [String: String],
        hasRelayRoute: Bool
    ) -> Bool {
        !shouldForceRelay(
            environment: environment,
            hasRelayRoute: hasRelayRoute
        )
    }
}

public enum PairingOfferPolicy {
    public static let lifetime: TimeInterval = 60 * 60
}

public struct RelayRoute: Codable, Equatable, Sendable {
    public static let maximumLifetime: TimeInterval = PairingOfferPolicy.lifetime

    public let host: String
    public let port: UInt16
    public let roomID: Data
    public let accessKey: Data
    public let expiresAt: Date
    public let transport: RelayWireTransport

    public init(
        host: String,
        port: UInt16,
        roomID: Data,
        accessKey: Data,
        expiresAt: Date,
        transport: RelayWireTransport = .tlsTCP
    ) {
        self.host = host
        self.port = port
        self.roomID = roomID
        self.accessKey = accessKey
        self.expiresAt = expiresAt
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case roomID
        case accessKey
        case expiresAt
        case transport
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        roomID = try container.decode(Data.self, forKey: .roomID)
        accessKey = try container.decode(Data.self, forKey: .accessKey)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        transport = try container.decodeIfPresent(
            RelayWireTransport.self,
            forKey: .transport
        ) ?? .tlsTCP
    }

    public func validate(at now: Date = .now) throws {
        let hostBytes = host.utf8
        guard (1...253).contains(hostBytes.count),
              hostBytes.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
              !host.contains("/"),
              !host.contains(":"),
              port > 0,
              (16...64).contains(roomID.count),
              (32...64).contains(accessKey.count) else {
            throw RelayError.invalidRoute
        }
        guard expiresAt > now,
              expiresAt.timeIntervalSince(now) <= Self.maximumLifetime else {
            throw RelayError.expired
        }
    }

    public func rendezvousTag(pairingNonce: Data) throws -> Data {
        guard (16...64).contains(pairingNonce.count) else {
            throw RelayError.invalidRoute
        }
        var context = Data("Oriel/relay/v1/rendezvous".utf8)
        context.append(roomID)
        context.append(Data(SHA256.hash(data: pairingNonce)))
        let authentication = HMAC<SHA256>.authenticationCode(
            for: context,
            using: SymmetricKey(data: accessKey)
        )
        return Data(authentication)
    }
}

public enum RelayPeerRole: String, Codable, Equatable, Sendable {
    case host
    case client
}

public struct EncryptedRelayPairingRequest: Codable, Equatable, Sendable {
    public let clientKeyAgreementPublicKey: Data
    public let sealedRequest: Data

    public init(clientKeyAgreementPublicKey: Data, sealedRequest: Data) {
        self.clientKeyAgreementPublicKey = clientKeyAgreementPublicKey
        self.sealedRequest = sealedRequest
    }
}

public enum RelayPairingHandshake {
    public static func seal(
        _ request: SignedPairingRequest,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        macPublicKey: Data,
        pairingNonce: Data
    ) throws -> EncryptedRelayPairingRequest {
        let clientPublicKey = clientPrivateKey.publicKey.rawRepresentation
        guard request.payload.clientKeyAgreementPublicKey == clientPublicKey else {
            throw PeerSessionError.invalidPeerKey
        }
        let remoteKey: Curve25519.KeyAgreement.PublicKey
        do {
            remoteKey = try .init(rawRepresentation: macPublicKey)
        } catch {
            throw PeerSessionError.invalidPeerKey
        }
        let key = try handshakeKey(
            secret: clientPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey),
            pairingNonce: pairingNonce
        )
        let plaintext = try PairingHandshakeCodec.encode(request)
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: associatedData(
                clientPublicKey: clientPublicKey,
                macPublicKey: macPublicKey,
                pairingNonce: pairingNonce
            )
        )
        return EncryptedRelayPairingRequest(
            clientKeyAgreementPublicKey: clientPublicKey,
            sealedRequest: box.combined
        )
    }

    public static func open(
        _ encrypted: EncryptedRelayPairingRequest,
        macPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        expectedClientPublicKey: Data? = nil,
        pairingNonce: Data
    ) throws -> SignedPairingRequest {
        guard encrypted.clientKeyAgreementPublicKey.count == 32,
              expectedClientPublicKey == nil
                || expectedClientPublicKey == encrypted.clientKeyAgreementPublicKey else {
            throw PeerSessionError.invalidPeerKey
        }
        let remoteKey: Curve25519.KeyAgreement.PublicKey
        do {
            remoteKey = try .init(
                rawRepresentation: encrypted.clientKeyAgreementPublicKey
            )
        } catch {
            throw PeerSessionError.invalidPeerKey
        }
        let key = try handshakeKey(
            secret: macPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey),
            pairingNonce: pairingNonce
        )
        do {
            let box = try ChaChaPoly.SealedBox(combined: encrypted.sealedRequest)
            let plaintext = try ChaChaPoly.open(
                box,
                using: key,
                authenticating: associatedData(
                    clientPublicKey: encrypted.clientKeyAgreementPublicKey,
                    macPublicKey: macPrivateKey.publicKey.rawRepresentation,
                    pairingNonce: pairingNonce
                )
            )
            let request = try PairingHandshakeCodec.decode(plaintext)
            guard request.payload.clientKeyAgreementPublicKey
                    == encrypted.clientKeyAgreementPublicKey else {
                throw PeerSessionError.invalidPeerKey
            }
            return request
        } catch let error as PeerSessionError {
            throw error
        } catch {
            throw PeerSessionError.authenticationFailed
        }
    }

    private static func handshakeKey(
        secret: SharedSecret,
        pairingNonce: Data
    ) throws -> SymmetricKey {
        guard (16...64).contains(pairingNonce.count) else {
            throw PeerSessionError.invalidPairingNonce
        }
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingNonce,
            sharedInfo: Data("Oriel/relay/v1/pairing-request".utf8),
            outputByteCount: 32
        )
    }

    private static func associatedData(
        clientPublicKey: Data,
        macPublicKey: Data,
        pairingNonce: Data
    ) -> Data {
        var data = Data("Oriel/relay/v1/pairing-request".utf8)
        data.append(clientPublicKey)
        data.append(macPublicKey)
        data.append(Data(SHA256.hash(data: pairingNonce)))
        return data
    }
}

public enum RelayPairingHandshakeCodec {
    public static let maximumBytes = PairingHandshakeCodec.maximumBytes + 1_024

    public static func encode(
        _ request: EncryptedRelayPairingRequest
    ) throws -> Data {
        let payload = try RelayJSON.encoder.encode(request)
        guard payload.count <= maximumBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(capacity: payload.count + 4)
        Swift.withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    public static func decode(_ framed: Data) throws -> EncryptedRelayPairingRequest {
        guard framed.count >= 4 else { throw PeerSessionError.invalidPacket }
        var length: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &length) {
            framed.copyBytes(to: $0, from: 0..<4)
        }
        let count = Int(UInt32(bigEndian: length))
        guard count <= maximumBytes,
              framed.count == count + 4 else {
            throw PeerSessionError.invalidPacket
        }
        do {
            let request = try RelayJSON.decoder.decode(
                EncryptedRelayPairingRequest.self,
                from: framed.dropFirst(4)
            )
            guard request.clientKeyAgreementPublicKey.count == 32,
                  request.sealedRequest.count <= PairingHandshakeCodec.maximumBytes + 64 else {
                throw PeerSessionError.payloadTooLarge
            }
            return request
        } catch let error as PeerSessionError {
            throw error
        } catch {
            throw PeerSessionError.invalidPacket
        }
    }
}

public struct RelayRegistrationPayload: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt16 = 1

    public let protocolVersion: UInt16
    public let role: RelayPeerRole
    public let roomID: Data
    public let rendezvousTag: Data
    public let pairingNonceDigest: Data
    public let signingPublicKey: Data
    public let connectionNonce: Data
    public let expiresAt: Date

    public init(
        protocolVersion: UInt16 = Self.currentProtocolVersion,
        role: RelayPeerRole,
        roomID: Data,
        rendezvousTag: Data,
        pairingNonceDigest: Data,
        signingPublicKey: Data,
        connectionNonce: Data,
        expiresAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.roomID = roomID
        self.rendezvousTag = rendezvousTag
        self.pairingNonceDigest = pairingNonceDigest
        self.signingPublicKey = signingPublicKey
        self.connectionNonce = connectionNonce
        self.expiresAt = expiresAt
    }

    fileprivate func canonicalData() throws -> Data {
        try RelayJSON.encoder.encode(self)
    }

    fileprivate func validate(at now: Date) throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw RelayError.unsupportedProtocol
        }
        guard (16...64).contains(roomID.count),
              rendezvousTag.count == 32,
              pairingNonceDigest.count == 32,
              signingPublicKey.count == 32,
              (16...64).contains(connectionNonce.count) else {
            throw RelayError.invalidFrame
        }
        guard expiresAt > now,
              expiresAt.timeIntervalSince(now) <= RelayRoute.maximumLifetime else {
            throw RelayError.expired
        }
    }
}

public struct RelayRegistration: Codable, Equatable, Sendable {
    public let payload: RelayRegistrationPayload
    public let signature: Data

    public init(payload: RelayRegistrationPayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public static func sign(
        role: RelayPeerRole,
        route: RelayRoute,
        pairingNonce: Data,
        signingKey: Curve25519.Signing.PrivateKey,
        connectionNonce: Data,
        expiresAt: Date
    ) throws -> Self {
        let payload = RelayRegistrationPayload(
            role: role,
            roomID: route.roomID,
            rendezvousTag: try route.rendezvousTag(pairingNonce: pairingNonce),
            pairingNonceDigest: Data(SHA256.hash(data: pairingNonce)),
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            connectionNonce: connectionNonce,
            expiresAt: min(expiresAt, route.expiresAt)
        )
        return Self(
            payload: payload,
            signature: try signingKey.signature(for: payload.canonicalData())
        )
    }

    @discardableResult
    public func verify(at now: Date = .now) throws -> Bool {
        try payload.validate(at: now)
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: payload.signingPublicKey)
        } catch {
            throw RelayError.invalidFrame
        }
        guard publicKey.isValidSignature(
            signature,
            for: try payload.canonicalData()
        ) else {
            throw RelayError.invalidSignature
        }
        return true
    }

    @discardableResult
    public func verify(
        route: RelayRoute,
        pairingNonce: Data,
        expectedRole: RelayPeerRole,
        at now: Date = .now
    ) throws -> Bool {
        try verify(at: now)
        try route.validate(at: now)
        guard payload.role == expectedRole else {
            throw RelayError.roleMismatch
        }
        let expectedTag = try route.rendezvousTag(pairingNonce: pairingNonce)
        guard payload.roomID == route.roomID,
              payload.rendezvousTag == expectedTag,
              payload.pairingNonceDigest == Data(
                SHA256.hash(data: pairingNonce)
              ),
              payload.expiresAt <= route.expiresAt else {
            throw RelayError.routeMismatch
        }
        return true
    }
}

public enum RelayHandshakeCodec {
    public static let maximumBytes = 8 * 1_024
    public static let acknowledgement = Data("OROK".utf8)

    public static func encode(_ registration: RelayRegistration) throws -> Data {
        let payload = try RelayJSON.encoder.encode(registration)
        guard payload.count <= maximumBytes else {
            throw RelayError.invalidFrame
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(capacity: 4 + payload.count)
        Swift.withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    public static func decode(_ framed: Data) throws -> RelayRegistration {
        guard framed.count >= 4 else { throw RelayError.invalidFrame }
        var length: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &length) {
            framed.copyBytes(to: $0, from: 0..<4)
        }
        let count = Int(UInt32(bigEndian: length))
        guard count <= maximumBytes,
              framed.count == count + 4 else {
            throw RelayError.invalidFrame
        }
        do {
            return try RelayJSON.decoder.decode(
                RelayRegistration.self,
                from: framed.dropFirst(4)
            )
        } catch {
            throw RelayError.invalidFrame
        }
    }
}

public actor RelayRegistrationReplayProtector {
    private var consumed: [Data: Date] = [:]

    public init() {}

    public func consume(
        _ registration: RelayRegistration,
        at now: Date = .now
    ) throws {
        try registration.verify(at: now)
        consumed = consumed.filter { $0.value > now }
        var replayMaterial = registration.payload.signingPublicKey
        replayMaterial.append(registration.payload.connectionNonce)
        let replayKey = Data(SHA256.hash(data: replayMaterial))
        guard consumed[replayKey] == nil else { throw RelayError.replayed }
        consumed[replayKey] = registration.payload.expiresAt
    }
}

private enum RelayJSON {
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
