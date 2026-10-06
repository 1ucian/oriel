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
}
