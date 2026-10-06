import Foundation
import LocalAuthentication
import Security
import Testing
@testable import HermesCaptureMac

struct PairingIdentityStoreTests {
    @Test func usesFreshOrielKeychainServiceNamespace() {
        #expect(PairingIdentityStore.service == "com.67enterprise.oriel.pairing-identity.v2")
    }

    @Test func keychainLookupCannotPresentAuthenticationUI() {
        let query = PairingIdentityStore.itemQuery(account: "test-account")
        let context = query[kSecUseAuthenticationContext] as? LAContext

        #expect(context?.interactionNotAllowed == true)
    }

    @Test func keychainLookupUsesDataProtectionKeychain() {
        let query = PairingIdentityStore.itemQuery(account: "test-account")

        #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
    }

    @Test func keychainWriteUsesDataProtectionKeychain() {
        let data = Data([0x01, 0x02])
        let query = PairingIdentityStore.newItemQuery(
            account: "test-account",
            data: data
        )

        #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(query[kSecValueData] as? Data == data)
        #expect(
            query[kSecAttrAccessible] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }
}
