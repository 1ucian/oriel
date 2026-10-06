import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

struct ReconnectProtocolTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func unauthenticatedHandshakeHasBoundedDeadline() {
        #expect(ReconnectHandshakePolicy.timeoutSeconds == 10)
        #expect(
            TimeInterval(ReconnectHandshakePolicy.timeoutSeconds)
                < ReconnectChallengePayload.maximumLifetime
        )
    }

    private func challenge(
        signingKey: Curve25519.Signing.PrivateKey,
        agreementKey: Curve25519.KeyAgreement.PrivateKey,
        serviceName: String = "Studio-Mac"
    ) throws -> SignedReconnectChallenge {
        try SignedReconnectChallenge.sign(
            ReconnectChallengePayload(
                macKeyAgreementPublicKey: agreementKey.publicKey.rawRepresentation,
                macSigningPublicKey: signingKey.publicKey.rawRepresentation,
                nonce: Data(repeating: 0x41, count: 24),
                issuedAt: now,
                expiresAt: now.addingTimeInterval(30),
                serviceName: serviceName
            ),
            with: signingKey
        )
    }

    @Test func challengeRequiresSavedMacSigningKeyAndExactServiceName() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let signed = try challenge(signingKey: signingKey, agreementKey: agreementKey)

        #expect(try signed.verify(
            expectedSigningPublicKey: signingKey.publicKey.rawRepresentation,
            expectedServiceName: "Studio-Mac",
            at: now.addingTimeInterval(1)
        ))
        #expect(throws: PairingError.invalidPublicKey) {
            try signed.verify(
                expectedSigningPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                expectedServiceName: "Studio-Mac",
                at: now.addingTimeInterval(1)
            )
        }
        #expect(throws: PairingError.invalidServiceName) {
            try signed.verify(
                expectedSigningPublicKey: signingKey.publicKey.rawRepresentation,
                expectedServiceName: "Different-Mac",
                at: now.addingTimeInterval(1)
            )
        }
    }

    @Test func challengeRejectsExpiryAndFutureIssueTime() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let signed = try challenge(signingKey: signingKey, agreementKey: agreementKey)

        // A phone clock within the skew tolerance of the Mac's still verifies.
        #expect(try signed.verify(
            expectedSigningPublicKey: signingKey.publicKey.rawRepresentation,
            expectedServiceName: "Studio-Mac",
            at: now.addingTimeInterval(-20)
        ))
        #expect(throws: PairingError.expired) {
            try signed.verify(
                expectedSigningPublicKey: signingKey.publicKey.rawRepresentation,
                expectedServiceName: "Studio-Mac",
                at: now.addingTimeInterval(61)
            )
        }
        #expect(throws: PairingError.expired) {
            try signed.verify(
                expectedSigningPublicKey: signingKey.publicKey.rawRepresentation,
                expectedServiceName: "Studio-Mac",
                at: now.addingTimeInterval(-31)
            )
        }
    }

    @Test func signedRequestBindsClientIdentityChallengeServiceAndCapabilities() throws {
        let macSigningKey = Curve25519.Signing.PrivateKey()
        let macAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let clientSigningKey = Curve25519.Signing.PrivateKey()
        let clientAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let signedChallenge = try challenge(
            signingKey: macSigningKey,
            agreementKey: macAgreementKey
        )
        let payload = ReconnectRequestPayload(
            challengeNonce: signedChallenge.payload.nonce,
            clientKeyAgreementPublicKey: clientAgreementKey.publicKey.rawRepresentation,
            clientSigningPublicKey: clientSigningKey.publicKey.rawRepresentation,
            deviceName: "Capybara",
            serviceName: signedChallenge.payload.serviceName,
            requestedCapabilities: [.viewScreen],
            createdAt: now.addingTimeInterval(1)
        )
        let request = try SignedReconnectRequest.sign(payload, with: clientSigningKey)

        #expect(try request.verify(
            challenge: signedChallenge.payload,
            expectedClientSigningPublicKey: clientSigningKey.publicKey.rawRepresentation,
            at: now.addingTimeInterval(2)
        ))
        #expect(throws: PairingError.invalidNonce) {
            let wrongChallenge = ReconnectChallengePayload(
                macKeyAgreementPublicKey: macAgreementKey.publicKey.rawRepresentation,
                macSigningPublicKey: macSigningKey.publicKey.rawRepresentation,
                nonce: Data(repeating: 0x42, count: 24),
                issuedAt: now,
                expiresAt: now.addingTimeInterval(30),
                serviceName: "Studio-Mac"
            )
            try request.verify(
                challenge: wrongChallenge,
                expectedClientSigningPublicKey: clientSigningKey.publicKey.rawRepresentation,
                at: now.addingTimeInterval(2)
            )
        }
        #expect(throws: PairingError.invalidPublicKey) {
            try request.verify(
                challenge: signedChallenge.payload,
                expectedClientSigningPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func capabilityDecisionAutoApprovesOnlyUnchangedOrSubset() throws {
        let approved: Set<SessionCapability> = [.viewScreen, .controlPointer]

        #expect(try ReconnectCapabilityDecision.evaluate(
            requested: [.viewScreen],
            approved: approved
        ) == .autoApprove)
        #expect(try ReconnectCapabilityDecision.evaluate(
            requested: approved,
            approved: approved
        ) == .autoApprove)
        #expect(try ReconnectCapabilityDecision.evaluate(
            requested: SessionCapability.phaseOneDefaults,
            approved: approved
        ) == .requiresApproval)
        #expect(try ReconnectCapabilityDecision.evaluate(
            requested: [.viewScreen, .runAgentActions],
            approved: approved
        ) == .requiresApproval)
        for sensitiveCapability in [
            SessionCapability.enterSecrets,
            .approveSensitiveAction,
        ] {
            #expect(throws: PeerSessionError.capabilityDenied) {
                try ReconnectCapabilityDecision.evaluate(
                    requested: [.viewScreen, sensitiveCapability],
                    approved: approved
                )
            }
        }
    }

    @Test func reconnectFramesRoundTripAndRejectTrailingBytes() throws {
        let macSigningKey = Curve25519.Signing.PrivateKey()
        let macAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let signedChallenge = try challenge(
            signingKey: macSigningKey,
            agreementKey: macAgreementKey
        )
        let challengeFrame = try ReconnectHandshakeCodec.encode(signedChallenge)
        #expect(try ReconnectHandshakeCodec.decodeChallenge(challengeFrame) == signedChallenge)
        #expect(throws: PeerSessionError.invalidPacket) {
            try ReconnectHandshakeCodec.decodeChallenge(challengeFrame + Data([0]))
        }

        let clientSigningKey = Curve25519.Signing.PrivateKey()
        let request = try SignedReconnectRequest.sign(
            ReconnectRequestPayload(
                challengeNonce: signedChallenge.payload.nonce,
                clientKeyAgreementPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                clientSigningPublicKey: clientSigningKey.publicKey.rawRepresentation,
                deviceName: "Capybara",
                serviceName: "Studio-Mac",
                requestedCapabilities: [.viewScreen],
                createdAt: now
            ),
            with: clientSigningKey
        )
        let requestFrame = try ReconnectHandshakeCodec.encode(request)
        #expect(try ReconnectHandshakeCodec.decodeRequest(requestFrame) == request)
    }

    @Test func reconnectChallengeCanBeConsumedOnlyOnce() async throws {
        let signed = try challenge(
            signingKey: Curve25519.Signing.PrivateKey(),
            agreementKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let protector = ReconnectReplayProtector()

        try await protector.consume(signed.payload, at: now.addingTimeInterval(1))
        await #expect(throws: PairingError.replayed) {
            try await protector.consume(signed.payload, at: now.addingTimeInterval(1))
        }
    }

    @Test func stableAgreementKeysDeriveFreshWorkingCipherFromChallengeNonce() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let firstNonce = Data(repeating: 0x51, count: 24)
        let secondNonce = Data(repeating: 0x52, count: 24)
        let firstMac = try SessionCipher(
            localPrivateKey: macKey,
            remotePublicKey: clientKey.publicKey.rawRepresentation,
            pairingNonce: firstNonce,
            role: .mac
        )
        let firstClient = try SessionCipher(
            localPrivateKey: clientKey,
            remotePublicKey: macKey.publicKey.rawRepresentation,
            pairingNonce: firstNonce,
            role: .client
        )
        let secondClient = try SessionCipher(
            localPrivateKey: clientKey,
            remotePublicKey: macKey.publicKey.rawRepresentation,
            pairingNonce: secondNonce,
            role: .client
        )
        let envelope = try firstMac.seal(.heartbeat(monotonicNanoseconds: 1))

        #expect(try firstClient.open(envelope) == .heartbeat(monotonicNanoseconds: 1))
        #expect(throws: PeerSessionError.authenticationFailed) {
            try secondClient.open(envelope)
        }
    }

    @Test func trustedPeerRecordRejectsInvalidKeysNamesAndCapabilities() throws {
        let valid = TrustedPeerRecord(
            signingPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            keyAgreementPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            serviceName: "Studio-Mac",
            displayName: "Studio Mac",
            approvedCapabilities: SessionCapability.phaseOneDefaults,
            createdAt: now
        )
        try valid.validate()

        let invalid = TrustedPeerRecord(
            signingPublicKey: Data(),
            keyAgreementPublicKey: valid.keyAgreementPublicKey,
            serviceName: valid.serviceName,
            displayName: valid.displayName,
            approvedCapabilities: valid.approvedCapabilities,
            createdAt: now
        )
        #expect(throws: PairingError.invalidPublicKey) {
            try invalid.validate()
        }
    }
}
