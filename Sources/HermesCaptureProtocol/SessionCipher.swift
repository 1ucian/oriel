import CryptoKit
import Foundation

public enum SessionPeerRole: Sendable {
    case mac
    case client
}

public struct EncryptedSessionEnvelope: Codable, Equatable, Sendable {
    public let counter: UInt64
    public let sealedData: Data

    public init(counter: UInt64, sealedData: Data) {
        self.counter = counter
        self.sealedData = sealedData
    }
}

public final class SessionCipher: @unchecked Sendable {
    private let outboundKey: SymmetricKey
    private let inboundKey: SymmetricKey
    private let lock = NSLock()
    private var outboundCounter: UInt64 = 0
    private var lastInboundCounter: UInt64?

    public init(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data,
        pairingNonce: Data,
        role: SessionPeerRole
    ) throws {
        guard pairingNonce.count >= 16, pairingNonce.count <= 64 else {
            throw PeerSessionError.invalidPairingNonce
        }
        let remoteKey: Curve25519.KeyAgreement.PublicKey
        do {
            remoteKey = try .init(rawRepresentation: remotePublicKey)
        } catch {
            throw PeerSessionError.invalidPeerKey
        }
        let secret = try localPrivateKey.sharedSecretFromKeyAgreement(
            with: remoteKey
        )
        let root = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingNonce,
            sharedInfo: Data("HermesCapture/v1/session".utf8),
            outputByteCount: 64
        )
        let rootData = root.withUnsafeBytes { Data($0) }
        let first = SymmetricKey(data: rootData.prefix(32))
        let second = SymmetricKey(data: rootData.suffix(32))
        switch role {
        case .mac:
            outboundKey = first
            inboundKey = second
        case .client:
            outboundKey = second
            inboundKey = first
        }
    }

    public func seal(_ packet: SessionPacket) throws -> EncryptedSessionEnvelope {
        try lock.withLock {
            let plaintext = try SessionPacketCodec.encode(packet)
            let nextCounter = outboundCounter &+ 1
            let box = try ChaChaPoly.seal(
                plaintext,
                using: outboundKey,
                authenticating: associatedData(for: nextCounter)
            )
            outboundCounter = nextCounter
            return EncryptedSessionEnvelope(
                counter: nextCounter,
                sealedData: box.combined
            )
        }
    }

    public func open(_ envelope: EncryptedSessionEnvelope) throws -> SessionPacket {
        try lock.withLock {
            guard envelope.sealedData.count <= SessionPacket.maximumEncodedBytes + 64 else {
                throw PeerSessionError.payloadTooLarge
            }
            if let lastInboundCounter, envelope.counter <= lastInboundCounter {
                throw PeerSessionError.replayedPacket
            }
            let box: ChaChaPoly.SealedBox
            do {
                box = try .init(combined: envelope.sealedData)
                let plaintext = try ChaChaPoly.open(
                    box,
                    using: inboundKey,
                    authenticating: associatedData(for: envelope.counter)
                )
                let packet = try SessionPacketCodec.decode(plaintext)
                lastInboundCounter = envelope.counter
                return packet
            } catch let error as PeerSessionError {
                throw error
            } catch {
                throw PeerSessionError.authenticationFailed
            }
        }
    }

    private func associatedData(for counter: UInt64) -> Data {
        var version = PairingPayload.currentProtocolVersion.littleEndian
        var counter = counter.littleEndian
        var data = Data("HermesCapture/session-envelope".utf8)
        Swift.withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &counter) { data.append(contentsOf: $0) }
        return data
    }
}
