import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

struct PairingPayloadTests {
    private func payload(expiresAt: Date = Date(timeIntervalSince1970: 2_000)) -> PairingPayload {
        PairingPayload(
            protocolVersion: 1,
            macPublicKey: Data(repeating: 7, count: 32),
            nonce: Data(repeating: 9, count: 24),
            expiresAt: expiresAt,
            serviceName: "Living-Room-Mac"
        )
    }

    @Test func qrEncodingRoundTrips() throws {
        let original = payload()

        let encoded = try original.qrEncodedString()
        let decoded = try PairingPayload(qrEncodedString: encoded)

        #expect(decoded == original)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test func signedQRCodeRoundTripsAndVerifiesEmbeddedKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try SignedPairingPayload.sign(
            payload(),
            with: privateKey
        )

        let encoded = try signed.qrEncodedString()
        let decoded = try SignedPairingPayload(qrEncodedString: encoded)

        #expect(decoded == signed)
        #expect(
            try decoded.verifyEmbedded(
                at: Date(timeIntervalSince1970: 1_000)
            )
        )
    }

    @Test func expiredPayloadIsRejected() {
        let expired = payload(expiresAt: Date(timeIntervalSince1970: 100))

        #expect(throws: PairingError.expired) {
            try expired.validate(at: Date(timeIntervalSince1970: 101))
        }
    }

    @Test func signatureRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try SignedPairingPayload.sign(
            payload(),
            with: privateKey
        )
        #expect(try signed.verify(with: privateKey.publicKey))

        let tampered = SignedPairingPayload(
            payload: payload(expiresAt: Date(timeIntervalSince1970: 3_000)),
            signature: signed.signature
        )
        #expect(throws: PairingError.invalidSignature) {
            try tampered.verify(with: privateKey.publicKey)
        }
    }

    @Test func compactSignedQRCodeStaysBelowFiveHundredTwelveCharacters() throws {
        let expiresAt = Date(timeIntervalSince1970: 4_600)
        let route = RelayRoute(
            host: "pair.example.com",
            port: 443,
            roomID: Data(repeating: 0x11, count: 24),
            accessKey: Data(repeating: 0x22, count: 32),
            expiresAt: expiresAt,
            transport: .secureWebSocket
        )
        let candidate = PairingPayload(
            macPublicKey: Data(repeating: 7, count: 32),
            nonce: Data(repeating: 9, count: 24),
            expiresAt: expiresAt,
            serviceName: "Living-Room-Mac",
            relayRoute: route
        )
        let signed = try SignedPairingPayload.sign(
            candidate,
            with: Curve25519.Signing.PrivateKey()
        )

        let encoded = try signed.qrEncodedString()
        let decoded = try SignedPairingPayload(qrEncodedString: encoded)

        #expect(encoded.count < 400)
        #expect(decoded == signed)
        #expect(try decoded.verifyEmbedded(at: Date(timeIntervalSince1970: 1_000)))
    }

    @Test func oneHourPairingOfferIsValidButLongerOfferIsRejected() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let oneHour = RelayRoute(
            host: "pair.example.com",
            port: 443,
            roomID: Data(repeating: 0x11, count: 24),
            accessKey: Data(repeating: 0x22, count: 32),
            expiresAt: now.addingTimeInterval(60 * 60),
            transport: .secureWebSocket
        )
        try oneHour.validate(at: now)

        let tooLong = RelayRoute(
            host: oneHour.host,
            port: oneHour.port,
            roomID: oneHour.roomID,
            accessKey: oneHour.accessKey,
            expiresAt: now.addingTimeInterval((60 * 60) + 1),
            transport: oneHour.transport
        )
        #expect(throws: RelayError.expired) {
            try tooLong.validate(at: now)
        }
    }

    @Test func replayProtectorRejectsSecondUse() async throws {
        let protector = PairingReplayProtector()
        let candidate = payload()
        let now = Date(timeIntervalSince1970: 1_000)

        try await protector.consume(candidate, at: now)

        do {
            try await protector.consume(candidate, at: now)
            Issue.record("Expected replay rejection")
        } catch let error as PairingError {
            #expect(error == .replayed)
        }
    }
}
