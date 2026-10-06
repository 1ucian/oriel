import Foundation
import Testing
@testable import HermesCaptureProtocol

struct ReconnectRouteTests {
    private func makeRoute() -> ReconnectRoute {
        ReconnectRoute(
            host: "relay.example.com",
            port: 443,
            transport: .secureWebSocket,
            roomID: Data(repeating: 1, count: 24),
            accessKey: Data(repeating: 2, count: 32),
            nonce: Data(repeating: 3, count: 32)
        )
    }

    @Test func routeValidatesAndDerivesAShortLivedRelayRoute() throws {
        let route = makeRoute()
        try route.validate()
        let now = Date()
        let relay = route.relayRoute(now: now)
        #expect(relay.host == "relay.example.com")
        #expect(relay.roomID == route.roomID)
        #expect(relay.accessKey == route.accessKey)
        #expect(relay.expiresAt.timeIntervalSince(now) <= ReconnectRoute.routeLifetime)
        #expect(relay.expiresAt > now)
        try relay.validate(at: now)
        // Both ends land in the same relay room from the same route and nonce.
        #expect(try relay.rendezvousTag(pairingNonce: route.nonce) == (try route.relayRoute(now: now).rendezvousTag(pairingNonce: route.nonce)))
    }

    @Test func badNonceOrRoomIsRejected() {
        let short = ReconnectRoute(host: "relay.example.com", port: 443, transport: .secureWebSocket,
                                   roomID: Data(repeating: 1, count: 24), accessKey: Data(repeating: 2, count: 32),
                                   nonce: Data(repeating: 3, count: 4))
        #expect(throws: RelayError.self) { try short.validate() }
        let badRoom = ReconnectRoute(host: "relay.example.com", port: 443, transport: .secureWebSocket,
                                     roomID: Data(repeating: 1, count: 4), accessKey: Data(repeating: 2, count: 32),
                                     nonce: Data(repeating: 3, count: 32))
        #expect(throws: RelayError.self) { try badRoom.validate() }
    }

    @Test func trustedRecordCarriesTheRouteAndStillReadsOldRecords() throws {
        let route = makeRoute()
        let record = TrustedPeerRecord(
            signingPublicKey: Data(repeating: 4, count: 32),
            keyAgreementPublicKey: Data(repeating: 5, count: 32),
            serviceName: "Oriel-Dev",
            displayName: "Oriel-Dev",
            approvedCapabilities: SessionCapability.assistantDefaults,
            reconnectRoute: route
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TrustedPeerRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.reconnectRoute == route)

        // A record written before routes existed has no key and decodes as nil.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "reconnectRoute")
        let old = try JSONDecoder().decode(TrustedPeerRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.reconnectRoute == nil)
        #expect(old.serviceName == "Oriel-Dev")
    }

    @Test func approvalCarriesTheRouteOptionally() throws {
        let route = makeRoute()
        let with = SessionApproval(capabilities: [.viewScreen], expiresAt: Date(), reconnectRoute: route)
        let without = SessionApproval(capabilities: [.viewScreen], expiresAt: Date())
        #expect(try JSONDecoder().decode(SessionApproval.self, from: JSONEncoder().encode(with)).reconnectRoute == route)
        #expect(try JSONDecoder().decode(SessionApproval.self, from: JSONEncoder().encode(without)).reconnectRoute == nil)
    }
}
