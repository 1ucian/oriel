import Foundation
import HermesCaptureProtocol
import LocalAuthentication
import Security

enum TrustedClientStoreError: Error {
    case keychain(OSStatus)
    case invalidStoredRecord
}

/// Where the list of trusted devices is kept: one keychain item in the app, memory in tests.
protocol TrustedClientStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

final class TrustedClientStore: @unchecked Sendable {
    static let service = "com.67enterprise.oriel.trusted-ios-peers.v1"
    static let account = "trusted-peers"

    private let storage: any TrustedClientStorage

    init(storage: any TrustedClientStorage = KeychainTrustedClientStorage()) {
        self.storage = storage
    }

    fileprivate static func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static func itemQuery() -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery()
        query[kSecUseAuthenticationContext] = context
        return query
    }

    static func newItemQuery(data: Data) -> [CFString: Any] {
        var query = baseQuery()
        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    static func upserting(
        _ record: TrustedPeerRecord,
        into records: [TrustedPeerRecord]
    ) -> [TrustedPeerRecord] {
        (records.filter { $0.signingPublicKey != record.signingPublicKey } + [record])
            .sorted { $0.id < $1.id }
    }

    static func removing(
        signingPublicKey: Data,
        from records: [TrustedPeerRecord]
    ) -> [TrustedPeerRecord] {
        records.filter { $0.signingPublicKey != signingPublicKey }
    }

    func records() throws -> [TrustedPeerRecord] {
        guard let data = try storage.read() else { return [] }
        do {
            let records = try Self.decoder.decode([TrustedPeerRecord].self, from: data)
            try records.forEach { try $0.validate() }
            return records
        } catch {
            throw TrustedClientStoreError.invalidStoredRecord
        }
    }

    func record(signingPublicKey: Data) throws -> TrustedPeerRecord? {
        try records().first { $0.signingPublicKey == signingPublicKey }
    }

    func save(_ record: TrustedPeerRecord) throws {
        try record.validate()
        try write(Self.upserting(record, into: records()))
    }

    func revoke(signingPublicKey: Data) throws {
        try write(Self.removing(signingPublicKey: signingPublicKey, from: records()))
    }

    func forget(signingPublicKey: Data) throws {
        try revoke(signingPublicKey: signingPublicKey)
    }

    private func write(_ records: [TrustedPeerRecord]) throws {
        try storage.write(Self.encoder.encode(records))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// The list as one data-protection keychain item that never prompts.
final class KeychainTrustedClientStorage: TrustedClientStorage {
    func read() throws -> Data? {
        var query = TrustedClientStore.itemQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TrustedClientStoreError.keychain(status)
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(TrustedClientStore.baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(TrustedClientStore.newItemQuery(data: data) as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TrustedClientStoreError.keychain(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw TrustedClientStoreError.keychain(status)
        }
    }
}
