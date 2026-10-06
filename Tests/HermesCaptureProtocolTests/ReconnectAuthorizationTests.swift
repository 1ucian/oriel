import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

/// Covers the Mac-side authorization gate for a direct reconnect: the saved peer
/// lookup, stable identity binding, and signed-request verification that decide
/// whether an already-paired client may resume without a new QR or approval.
struct ReconnectAuthorizationTests {
    private let now = Date(timeIntervalSince1970: 20_000)

    private struct Peer {
        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()

        var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
        var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }
    }

    private func record(
        for peer: Peer,
        approved: Set<SessionCapability> = [.viewScreen, .controlPointer]
    ) -> TrustedPeerRecord {
        TrustedPeerRecord(
            signingPublicKey: peer.signingPublicKey,
            keyAgreementPublicKey: peer.agreementPublicKey,
            serviceName: "Studio-Mac",
            displayName: "Capybara",
            approvedCapabilities: approved,
            createdAt: now
        )
    }

    private func challenge(mac: Peer) -> ReconnectChallengePayload {
        ReconnectChallengePayload(
            macKeyAgreementPublicKey: mac.agreementPublicKey,
            macSigningPublicKey: mac.signingPublicKey,
            nonce: Data(repeating: 0x61, count: 24),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            serviceName: "Studio-Mac"
        )
    }

    private func signedRequest(
        from client: Peer,
        challenge: ReconnectChallengePayload,
        requested: Set<SessionCapability> = [.viewScreen],
        declaringAgreementKey overrideAgreementKey: Data? = nil,
        createdAt: Date? = nil
    ) throws -> SignedReconnectRequest {
        try SignedReconnectRequest.sign(
            ReconnectRequestPayload(
                challengeNonce: challenge.nonce,
                clientKeyAgreementPublicKey: overrideAgreementKey
                    ?? client.agreementPublicKey,
                clientSigningPublicKey: client.signingPublicKey,
                deviceName: "Capybara",
                serviceName: challenge.serviceName,
                requestedCapabilities: requested,
                createdAt: createdAt ?? now.addingTimeInterval(1)
            ),
            with: client.signingKey
        )
    }

    @Test func authorizeToleratesPhoneClockWithinSkewAndRejectsBeyond() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        // Phone clock 20 seconds ahead of the Mac's: the request looks future-dated.
        let ahead = try signedRequest(from: client, challenge: challenge, createdAt: now.addingTimeInterval(22))
        let authorized = try ReconnectAuthorization.authorize(
            request: ahead,
            challenge: challenge,
            trustedPeers: [record(for: client)],
            at: now.addingTimeInterval(2)
        )
        #expect(authorized.signingPublicKey == client.signingPublicKey)

        // Beyond the tolerance it is still expired.
        let farAhead = try signedRequest(from: client, challenge: challenge, createdAt: now.addingTimeInterval(33))
        #expect(throws: PairingError.expired) {
            try ReconnectAuthorization.authorize(
                request: farAhead,
                challenge: challenge,
                trustedPeers: [record(for: client)],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeReturnsSavedPeerForValidSignedRequest() throws {
        let mac = Peer()
        let client = Peer()
        let saved = record(for: client)
        let challenge = challenge(mac: mac)
        let request = try signedRequest(from: client, challenge: challenge)

        let authorized = try ReconnectAuthorization.authorize(
            request: request,
            challenge: challenge,
            trustedPeers: [record(for: Peer()), saved],
            at: now.addingTimeInterval(2)
        )

        #expect(authorized == saved)
    }

    @Test func authorizeRejectsClientMissingFromTrustedPeers() throws {
        let mac = Peer()
        let stranger = Peer()
        let challenge = challenge(mac: mac)
        let request = try signedRequest(from: stranger, challenge: challenge)

        #expect(throws: PairingError.invalidPublicKey) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: challenge,
                trustedPeers: [record(for: Peer())],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeRejectsEmptyTrustStoreSoRevokedPeerCannotResume() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        let request = try signedRequest(from: client, challenge: challenge)

        #expect(throws: PairingError.invalidPublicKey) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: challenge,
                trustedPeers: [],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeRejectsSavedSigningKeyPresentingDifferentAgreementKey() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        let request = try signedRequest(
            from: client,
            challenge: challenge,
            declaringAgreementKey: Curve25519.KeyAgreement.PrivateKey()
                .publicKey.rawRepresentation
        )

        #expect(throws: PairingError.invalidPublicKey) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: challenge,
                trustedPeers: [record(for: client)],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeRejectsRequestBoundToADifferentChallengeNonce() throws {
        let mac = Peer()
        let client = Peer()
        let issued = challenge(mac: mac)
        let request = try signedRequest(from: client, challenge: issued)
        let replacement = ReconnectChallengePayload(
            macKeyAgreementPublicKey: mac.agreementPublicKey,
            macSigningPublicKey: mac.signingPublicKey,
            nonce: Data(repeating: 0x62, count: 24),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            serviceName: "Studio-Mac"
        )

        #expect(throws: PairingError.invalidNonce) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: replacement,
                trustedPeers: [record(for: client)],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeRejectsExpiredChallenge() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        let request = try signedRequest(from: client, challenge: challenge)

        #expect(throws: PairingError.expired) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: challenge,
                trustedPeers: [record(for: client)],
                at: now.addingTimeInterval(31)
            )
        }
    }

    @Test func authorizeRejectsSavedPeerForDifferentServiceName() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        let request = try signedRequest(from: client, challenge: challenge)
        let savedForAnotherMac = TrustedPeerRecord(
            signingPublicKey: client.signingPublicKey,
            keyAgreementPublicKey: client.agreementPublicKey,
            serviceName: "Other-Mac",
            displayName: "Capybara",
            approvedCapabilities: [.viewScreen],
            createdAt: now
        )

        #expect(throws: PairingError.invalidServiceName) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: challenge,
                trustedPeers: [savedForAnotherMac],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeRejectsTamperedRequestSignature() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        let honest = try signedRequest(from: client, challenge: challenge)
        let tampered = SignedReconnectRequest(
            payload: ReconnectRequestPayload(
                challengeNonce: honest.payload.challengeNonce,
                clientKeyAgreementPublicKey: honest.payload.clientKeyAgreementPublicKey,
                clientSigningPublicKey: honest.payload.clientSigningPublicKey,
                deviceName: "Impostor",
                serviceName: honest.payload.serviceName,
                requestedCapabilities: honest.payload.requestedCapabilities,
                createdAt: honest.payload.createdAt
            ),
            signature: honest.signature
        )

        #expect(throws: PairingError.invalidSignature) {
            try ReconnectAuthorization.authorize(
                request: tampered,
                challenge: challenge,
                trustedPeers: [record(for: client)],
                at: now.addingTimeInterval(2)
            )
        }
    }

    @Test func authorizeRejectsCapabilitiesOutsidePhaseOneEvenForSavedPeer() throws {
        let mac = Peer()
        let client = Peer()
        let challenge = challenge(mac: mac)
        let request = try signedRequest(
            from: client,
            challenge: challenge,
            requested: [.viewScreen, .enterSecrets]
        )

        #expect(throws: PeerSessionError.capabilityDenied) {
            try ReconnectAuthorization.authorize(
                request: request,
                challenge: challenge,
                trustedPeers: [record(for: client)],
                at: now.addingTimeInterval(2)
            )
        }
    }
}
