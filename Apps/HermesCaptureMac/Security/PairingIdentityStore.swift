import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct PairingIdentity {
    let signingKey: Curve25519.Signing.PrivateKey
    let keyAgreementKey: Curve25519.KeyAgreement.PrivateKey
}

enum PairingIdentityStoreError: Error {
    case keychain(OSStatus)
    case invalidStoredKey
}

final class PairingIdentityStore {
    static let service = "com.67enterprise.oriel.pairing-identity.v2"

    private static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static func itemQuery(account: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account)
        query[kSecUseAuthenticationContext] = context
        return query
    }

    static func newItemQuery(account: String, data: Data) -> [CFString: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    func loadOrCreate() throws -> PairingIdentity {
        return PairingIdentity(
            signingKey: try loadOrCreateSigningKey(),
            keyAgreementKey: try loadOrCreateAgreementKey()
        )
    }

    private func loadOrCreateSigningKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try load(account: "mac-signing-v1") {
            guard let key = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: data
            ) else {
                throw PairingIdentityStoreError.invalidStoredKey
            }
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try save(key.rawRepresentation, account: "mac-signing-v1")
        return key
    }

    private func loadOrCreateAgreementKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = try load(account: "mac-key-agreement-v1") {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: data
            ) else {
                throw PairingIdentityStoreError.invalidStoredKey
            }
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try save(key.rawRepresentation, account: "mac-key-agreement-v1")
        return key
    }

    private func load(account: String) throws -> Data? {
        var query = Self.itemQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingIdentityStoreError.keychain(status)
        }
        return data
    }

    private func save(_ data: Data, account: String) throws {
        let query = Self.newItemQuery(account: account, data: data)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PairingIdentityStoreError.keychain(status)
        }
    }
}
