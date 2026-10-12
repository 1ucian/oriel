import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

/// Fixed vectors for the pairing confirmation code, on the wire vectors' keys (`WireVectorInputs`), so a
/// second implementation can check its digits. The expected outputs were computed outside CryptoKit (X25519
/// and HKDF-SHA256 from Python's `cryptography` package), from the same seeds and nonces:
///
/// | inputs                                      | HKDF output (8 bytes) | code    |
/// |---------------------------------------------|-----------------------|---------|
/// | wire keys, pairing nonce 160...183          | 715f808246a75cc2      | 846 274 |
/// | wire keys, challenge nonce 192...215        | 405e23ca699be7ad      | 380 589 |
/// | phone signing seed 129...160 instead        | 910daa0394640a03      | 997 187 |
/// | phone agreement seed 129...160 instead      | 9daacb9838cfdcb0      | 111 536 |
struct PairingConfirmationCodeTests {
    private static let otherSeed = Data((129...160).map(UInt8.init))

    private func offer(nonce: Data = WireVectorInputs.pairingNonce) throws -> SignedPairingPayload {
        try SignedPairingPayload.sign(
            PairingPayload(
                macPublicKey: WireVectorInputs.macAgreementKey.publicKey.rawRepresentation,
                nonce: nonce,
                expiresAt: WireVectorInputs.offerExpiresAt,
                serviceName: WireVectorInputs.serviceName
            ),
            with: WireVectorInputs.macSigningKey
        )
    }

    private func request(
        nonce: Data = WireVectorInputs.pairingNonce,
        phoneSigningPublicKey: Data,
        phoneAgreementPublicKey: Data
    ) -> PairingRequestPayload {
        PairingRequestPayload(
            pairingNonce: nonce,
            clientKeyAgreementPublicKey: phoneAgreementPublicKey,
            clientSigningPublicKey: phoneSigningPublicKey,
            deviceName: WireVectorInputs.deviceName,
            requestedCapabilities: SessionCapability.assistantDefaults,
            createdAt: WireVectorInputs.requestCreatedAt
        )
    }

    /// The code the Mac shows and the code the phone shows, each from its own private key.
    private func codes(
        nonce: Data = WireVectorInputs.pairingNonce,
        phoneSigningKey: Curve25519.Signing.PrivateKey,
        phoneAgreementKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> (mac: PairingConfirmationCode, phone: PairingConfirmationCode) {
        let mac = try PairingConfirmationCode(
            macAgreementKey: WireVectorInputs.macAgreementKey,
            macSigningPublicKey: WireVectorInputs.macSigningKey.publicKey.rawRepresentation,
            request: request(
                nonce: nonce,
                phoneSigningPublicKey: phoneSigningKey.publicKey.rawRepresentation,
                phoneAgreementPublicKey: phoneAgreementKey.publicKey.rawRepresentation
            )
        )
        let phone = try PairingConfirmationCode(
            phoneAgreementKey: phoneAgreementKey,
            phoneSigningPublicKey: phoneSigningKey.publicKey.rawRepresentation,
            offer: offer(nonce: nonce)
        )
        return (mac, phone)
    }

    @Test func macAndPhoneShowTheFixedVector() throws {
        let codes = try codes(
            phoneSigningKey: WireVectorInputs.phoneSigningKey,
            phoneAgreementKey: WireVectorInputs.phoneAgreementKey
        )

        #expect(codes.mac.digits == "846274")
        #expect(codes.phone == codes.mac)
        #expect(codes.mac.formatted == "846 274")
        #expect(codes.mac.spokenDigits == "8 4 6, 2 7 4")
    }

    @Test func eachInputChangesTheCodeOnBothSides() throws {
        let challengeNonce = try codes(
            nonce: WireVectorInputs.challengeNonce,
            phoneSigningKey: WireVectorInputs.phoneSigningKey,
            phoneAgreementKey: WireVectorInputs.phoneAgreementKey
        )
        let otherSigningKey = try codes(
            phoneSigningKey: .init(rawRepresentation: Self.otherSeed),
            phoneAgreementKey: WireVectorInputs.phoneAgreementKey
        )
        let otherAgreementKey = try codes(
            phoneSigningKey: WireVectorInputs.phoneSigningKey,
            phoneAgreementKey: .init(rawRepresentation: Self.otherSeed)
        )

        #expect(challengeNonce.mac.digits == "380589")
        #expect(challengeNonce.phone == challengeNonce.mac)
        #expect(otherSigningKey.mac.digits == "997187")
        #expect(otherSigningKey.phone == otherSigningKey.mac)
        #expect(otherAgreementKey.mac.digits == "111536")
        #expect(otherAgreementKey.phone == otherAgreementKey.mac)
    }

    /// Someone who rewrites the phone's request with a signing key of their own, keeping the phone's
    /// agreement key so the session secret still matches, gets a code on the Mac the phone does not show.
    @Test func aRequestWithASwappedSigningKeyShowsADifferentCode() throws {
        let phoneShows = try PairingConfirmationCode(
            phoneAgreementKey: WireVectorInputs.phoneAgreementKey,
            phoneSigningPublicKey: WireVectorInputs.phoneSigningKey.publicKey.rawRepresentation,
            offer: offer()
        )
        let macShows = try PairingConfirmationCode(
            macAgreementKey: WireVectorInputs.macAgreementKey,
            macSigningPublicKey: WireVectorInputs.macSigningKey.publicKey.rawRepresentation,
            request: request(
                phoneSigningPublicKey: Curve25519.Signing.PrivateKey(rawRepresentation: Self.otherSeed)
                    .publicKey.rawRepresentation,
                phoneAgreementPublicKey: WireVectorInputs.phoneAgreementKey.publicKey.rawRepresentation
            )
        )

        #expect(phoneShows.digits == "846274")
        #expect(macShows.digits == "997187")
    }

    @Test func digitsKeepLeadingZerosAndReadOneAtATime() {
        #expect(PairingConfirmationCode.digits(from: 42_117) == "042117")
        #expect(PairingConfirmationCode.digits(from: 1_000_000) == "000000")
        #expect(PairingConfirmationCode.digits(from: .max) == "551615")
        let code = PairingConfirmationCode(digits: "042117")
        #expect(code.formatted == "042 117")
        #expect(code.spokenDigits == "0 4 2, 1 1 7")
        #expect(code.description == "042 117")
    }

    @Test func malformedInputsAreRefused() throws {
        let phoneSigning = try WireVectorInputs.phoneSigningKey.publicKey.rawRepresentation
        let phoneAgreement = try WireVectorInputs.phoneAgreementKey.publicKey.rawRepresentation
        let macSigning = try WireVectorInputs.macSigningKey.publicKey.rawRepresentation

        #expect(throws: PeerSessionError.invalidPairingNonce) {
            try PairingConfirmationCode(
                macAgreementKey: WireVectorInputs.macAgreementKey,
                macSigningPublicKey: macSigning,
                request: request(nonce: Data(repeating: 7, count: 8), phoneSigningPublicKey: phoneSigning, phoneAgreementPublicKey: phoneAgreement)
            )
        }
        #expect(throws: PeerSessionError.invalidPeerKey) {
            try PairingConfirmationCode(
                macAgreementKey: WireVectorInputs.macAgreementKey,
                macSigningPublicKey: macSigning.prefix(31),
                request: request(phoneSigningPublicKey: phoneSigning, phoneAgreementPublicKey: phoneAgreement)
            )
        }
        #expect(throws: PeerSessionError.invalidPeerKey) {
            try PairingConfirmationCode(
                macAgreementKey: WireVectorInputs.macAgreementKey,
                macSigningPublicKey: macSigning,
                request: request(phoneSigningPublicKey: phoneSigning, phoneAgreementPublicKey: phoneAgreement.prefix(31))
            )
        }
        let unsignedOffer = SignedPairingPayload(payload: try offer().payload, signature: Data())
        #expect(throws: PeerSessionError.invalidPeerKey) {
            try PairingConfirmationCode(
                phoneAgreementKey: WireVectorInputs.phoneAgreementKey,
                phoneSigningPublicKey: phoneSigning,
                offer: unsignedOffer
            )
        }
    }
}
