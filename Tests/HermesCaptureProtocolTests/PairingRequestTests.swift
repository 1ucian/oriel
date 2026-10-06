import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

struct PairingRequestTests {
    @Test func signedRequestVerifiesExpectedNonceAndCapabilities() throws {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = Data(repeating: 4, count: 24)
        let payload = PairingRequestPayload(
            pairingNonce: nonce,
            clientKeyAgreementPublicKey: Data(repeating: 5, count: 32),
            clientSigningPublicKey: key.publicKey.rawRepresentation,
            deviceName: "Alex’s iPhone",
            requestedCapabilities: SessionCapability.phaseOneDefaults,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let request = try SignedPairingRequest.sign(payload, with: key)

        #expect(
            try request.verify(
                expectedNonce: nonce,
                at: Date(timeIntervalSince1970: 1_010)
            )
        )
    }

    @Test func handshakeCodecRoundTripsAndRejectsTrailingBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = PairingRequestPayload(
            pairingNonce: Data(repeating: 7, count: 24),
            clientKeyAgreementPublicKey: Data(repeating: 8, count: 32),
            clientSigningPublicKey: key.publicKey.rawRepresentation,
            deviceName: "iPad",
            requestedCapabilities: [.viewScreen],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let request = try SignedPairingRequest.sign(payload, with: key)
        let framed = try PairingHandshakeCodec.encode(request)

        #expect(try PairingHandshakeCodec.decode(framed) == request)
        #expect(throws: PeerSessionError.invalidPacket) {
            try PairingHandshakeCodec.decode(framed + Data([0]))
        }
    }

    @Test func multiCapabilityWireEncodingIsCanonical() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = PairingRequestPayload(
            pairingNonce: Data(repeating: 9, count: 24),
            clientKeyAgreementPublicKey: Data(repeating: 10, count: 32),
            clientSigningPublicKey: key.publicKey.rawRepresentation,
            deviceName: "iPhone",
            requestedCapabilities: SessionCapability.phaseOneDefaults,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let request = try SignedPairingRequest.sign(payload, with: key)
        let framed = try PairingHandshakeCodec.encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: framed.dropFirst(4))
                as? [String: Any]
        )
        let encodedPayload = try #require(object["payload"] as? [String: Any])
        let capabilities = try #require(
            encodedPayload["requestedCapabilities"] as? [String]
        )

        #expect(capabilities == capabilities.sorted())
    }

    @Test func wrongNonceAndSensitiveCapabilityFailClosed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = PairingRequestPayload(
            pairingNonce: Data(repeating: 1, count: 24),
            clientKeyAgreementPublicKey: Data(repeating: 2, count: 32),
            clientSigningPublicKey: key.publicKey.rawRepresentation,
            deviceName: "iPhone",
            requestedCapabilities: [.viewScreen, .enterSecrets],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let request = try SignedPairingRequest.sign(payload, with: key)

        #expect(throws: PairingError.invalidNonce) {
            try request.verify(
                expectedNonce: Data(repeating: 3, count: 24),
                at: Date(timeIntervalSince1970: 1_010)
            )
        }
        #expect(throws: PeerSessionError.capabilityDenied) {
            try request.verify(
                expectedNonce: payload.pairingNonce,
                at: Date(timeIntervalSince1970: 1_010)
            )
        }
    }
}
