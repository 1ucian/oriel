import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
import HermesCaptureProtocol
@testable import HermesCaptureMac

struct TrustedClientStoreTests {
    @Test func keychainQueriesUseDataProtectionAndNeverPrompt() {
        let lookup = TrustedClientStore.itemQuery()
        let context = lookup[kSecUseAuthenticationContext] as? LAContext
        #expect(lookup[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(context?.interactionNotAllowed == true)

        let write = TrustedClientStore.newItemQuery(data: Data([1, 2]))
        #expect(write[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(write[kSecAttrAccessible] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func upsertAndRevokeAreKeyedByStableSigningIdentity() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let original = TrustedPeerRecord(
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            keyAgreementPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            serviceName: "Capybara",
            displayName: "Capybara",
            approvedCapabilities: [.viewScreen]
        )
        let updated = TrustedPeerRecord(
            signingPublicKey: original.signingPublicKey,
            keyAgreementPublicKey: original.keyAgreementPublicKey,
            serviceName: original.serviceName,
            displayName: original.displayName,
            approvedCapabilities: [.viewScreen, .controlPointer]
        )

        let merged = TrustedClientStore.upserting(updated, into: [original])
        #expect(merged == [updated])
        #expect(TrustedClientStore.removing(
            signingPublicKey: original.signingPublicKey,
            from: merged
        ).isEmpty)
    }

    @Test func revokeRemovesTheIdentityAndKeepsTheOtherPhones() throws {
        let store = TrustedClientStore(storage: MemoryStorage())
        let phone = Phone()
        let other = Phone()
        try store.save(phone.record())
        try store.save(other.record(name: "Other iPad"))

        try store.revoke(signingPublicKey: phone.signingPublicKey)

        #expect(try store.record(signingPublicKey: phone.signingPublicKey) == nil)
        #expect(try store.records().map(\.signingPublicKey) == [other.signingPublicKey])
    }

    @Test func aRevokedIdentityCannotReconnect() throws {
        let store = TrustedClientStore(storage: MemoryStorage())
        let mac = Curve25519.Signing.PrivateKey()
        let phone = Phone()
        try store.save(phone.record())
        let now = Date.now
        let challenge = ReconnectChallengePayload(
            macKeyAgreementPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            macSigningPublicKey: mac.publicKey.rawRepresentation,
            nonce: Data(repeating: 0x5A, count: 24),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            serviceName: Phone.serviceName
        )
        let request = try SignedReconnectRequest.sign(
            ReconnectRequestPayload(
                challengeNonce: challenge.nonce,
                clientKeyAgreementPublicKey: phone.agreementPublicKey,
                clientSigningPublicKey: phone.signingPublicKey,
                deviceName: "Alex\u{2019}s iPhone",
                serviceName: Phone.serviceName,
                requestedCapabilities: [.viewScreen],
                createdAt: now
            ),
            with: phone.signingKey
        )
        let authorized = try ReconnectAuthorization.authorize(
            request: request, challenge: challenge, trustedPeers: store.records(), at: now
        )
        #expect(authorized.signingPublicKey == phone.signingPublicKey)

        try store.revoke(signingPublicKey: phone.signingPublicKey)

        #expect(throws: PairingError.invalidPublicKey) {
            try ReconnectAuthorization.authorize(
                request: request, challenge: challenge, trustedPeers: store.records(), at: now
            )
        }
    }
}

/// A phone's identity, as the Mac saves it after an approval.
private struct Phone {
    static let serviceName = "Studio-Mac"
    let signingKey = Curve25519.Signing.PrivateKey()
    let agreementKey = Curve25519.KeyAgreement.PrivateKey()

    var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
    var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }

    func record(name: String = "Alex\u{2019}s iPhone") -> TrustedPeerRecord {
        TrustedPeerRecord(
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: agreementPublicKey,
            serviceName: Self.serviceName,
            displayName: name,
            approvedCapabilities: SessionCapability.assistantDefaults
        )
    }
}

/// The store's list in memory: the keychain item needs a signed app.
private final class MemoryStorage: TrustedClientStorage {
    private var data: Data?

    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}
