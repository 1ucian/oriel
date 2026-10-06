import Foundation
import HermesCaptureProtocol
import Security

/// The Mac's standing relay rendezvous, kept in the keychain next to the pairing identity.
/// Phones approved after it exists receive it and can reconnect through the relay.
final class ReconnectRouteStore {
    private let account: String

    /// One route per advertised name: a development copy running beside the installed
    /// companion keeps its own relay room.
    init(serviceName: String) {
        account = "reconnect-route-v1-" + serviceName
    }

    func load() -> ReconnectRoute? {
        var query = PairingIdentityStore.itemQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let route = try? JSONDecoder().decode(ReconnectRoute.self, from: data),
              (try? route.validate()) != nil else { return nil }
        return route
    }

    /// The stored route when it points at the configured relay, otherwise a fresh one.
    func loadOrCreate(host: String, port: UInt16, transport: RelayWireTransport) throws -> ReconnectRoute {
        if let route = load(), route.host == host, route.port == port, route.transport == transport {
            return route
        }
        let route = ReconnectRoute(
            host: host,
            port: port,
            transport: transport,
            roomID: try Self.random(24),
            accessKey: try Self.random(32),
            nonce: try Self.random(32)
        )
        try route.validate()
        let data = try JSONEncoder().encode(route)
        SecItemDelete(PairingIdentityStore.itemQuery(account: account) as CFDictionary)
        let status = SecItemAdd(PairingIdentityStore.newItemQuery(account: account, data: data) as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingIdentityStoreError.keychain(status) }
        return route
    }

    private static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw PairingIdentityStoreError.keychain(status) }
        return data
    }
}
