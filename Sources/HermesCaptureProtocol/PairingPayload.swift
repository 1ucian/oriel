import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case invalidEncoding
    case unsupportedProtocol
    case invalidPublicKey
    case invalidNonce
    case invalidServiceName
    case expired
    case invalidSignature
    case replayed
}

public struct PairingPayload: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt16 = 1

    public let protocolVersion: UInt16
    public let macPublicKey: Data
    public let nonce: Data
    public let expiresAt: Date
    public let serviceName: String
    public let relayRoute: RelayRoute?

    public init(
        protocolVersion: UInt16 = Self.currentProtocolVersion,
        macPublicKey: Data,
        nonce: Data,
        expiresAt: Date,
        serviceName: String,
        relayRoute: RelayRoute? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.macPublicKey = macPublicKey
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.serviceName = serviceName
        self.relayRoute = relayRoute
    }

    public init(qrEncodedString: String) throws {
        guard let data = Data(base64URLEncoded: qrEncodedString) else {
            throw PairingError.invalidEncoding
        }
        do {
            self = try Self.decoder.decode(Self.self, from: data)
        } catch {
            throw PairingError.invalidEncoding
        }
    }

    public func qrEncodedString() throws -> String {
        try canonicalData().base64URLEncodedString()
    }

    public func validate(at now: Date = .now) throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw PairingError.unsupportedProtocol
        }
        guard macPublicKey.count == 32 else {
            throw PairingError.invalidPublicKey
        }
        guard (16...64).contains(nonce.count) else {
            throw PairingError.invalidNonce
        }
        guard (1...63).contains(serviceName.utf8.count) else {
            throw PairingError.invalidServiceName
        }
        guard expiresAt > now else {
            throw PairingError.expired
        }
        if let relayRoute {
            do {
                try relayRoute.validate(at: now)
                guard relayRoute.expiresAt <= expiresAt else {
                    throw PairingError.expired
                }
            } catch RelayError.expired {
                throw PairingError.expired
            } catch {
                throw PairingError.invalidEncoding
            }
        }
    }

    fileprivate func canonicalData() throws -> Data {
        try Self.encoder.encode(self)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct SignedPairingPayload: Codable, Equatable, Sendable {
    public let payload: PairingPayload
    public let signature: Data
    public let signingPublicKey: Data

    public init(
        payload: PairingPayload,
        signature: Data,
        signingPublicKey: Data = Data()
    ) {
        self.payload = payload
        self.signature = signature
        self.signingPublicKey = signingPublicKey
    }

    public static func sign(
        _ payload: PairingPayload,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        let signature = try privateKey.signature(for: payload.canonicalData())
        return Self(
            payload: payload,
            signature: signature,
            signingPublicKey: privateKey.publicKey.rawRepresentation
        )
    }

    public init(qrEncodedString: String) throws {
        guard let data = Data(base64URLEncoded: qrEncodedString) else {
            throw PairingError.invalidEncoding
        }
        if CompactPairingOfferCodec.isCompact(data) {
            self = try CompactPairingOfferCodec.decode(data)
            return
        }
        do {
            self = try Self.decoder.decode(Self.self, from: data)
        } catch {
            throw PairingError.invalidEncoding
        }
    }

    public func qrEncodedString() throws -> String {
        try CompactPairingOfferCodec.encode(self).base64URLEncodedString()
    }

    @discardableResult
    public func verifyEmbedded(at now: Date = .now) throws -> Bool {
        try payload.validate(at: now)
        guard signingPublicKey.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: signingPublicKey
              ) else {
            throw PairingError.invalidPublicKey
        }
        return try verify(with: publicKey)
    }

    @discardableResult
    public func verify(
        with publicKey: Curve25519.Signing.PublicKey
    ) throws -> Bool {
        guard publicKey.isValidSignature(
            signature,
            for: try payload.canonicalData()
        ) else {
            throw PairingError.invalidSignature
        }
        return true
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public actor PairingReplayProtector {
    private var consumedNonces: [Data: Date] = [:]

    public init() {}

    public func consume(
        _ payload: PairingPayload,
        at now: Date = .now
    ) throws {
        try payload.validate(at: now)
        consumedNonces = consumedNonces.filter { $0.value > now }
        guard consumedNonces[payload.nonce] == nil else {
            throw PairingError.replayed
        }
        consumedNonces[payload.nonce] = payload.expiresAt
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
