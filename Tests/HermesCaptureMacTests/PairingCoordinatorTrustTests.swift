import CryptoKit
import Foundation
import Testing
import HermesCaptureProtocol
@testable import HermesCaptureMac

/// What Stop Control and Revoke do to the list of trusted phones, on the coordinator itself.
@MainActor
struct PairingCoordinatorTrustTests {
    @Test func stopControlKeepsThePhoneTrusted() throws {
        let store = TrustedClientStore(storage: TrustMemoryStorage())
        let phone = Self.record("Alex\u{2019}s iPhone")
        try store.save(phone)
        let coordinator = PairingCoordinator(trustedClientStore: store)

        coordinator.stopControl()

        #expect(try store.records() == [phone])
        coordinator.refreshPairedDevices()
        #expect(coordinator.pairedDevices == [phone])
    }

    @Test func revokeRemovesThePhoneFromTheStoreAndTheList() throws {
        let store = TrustedClientStore(storage: TrustMemoryStorage())
        let phone = Self.record("Alex\u{2019}s iPhone", pairedAt: 2_000)
        let tablet = Self.record("Alex\u{2019}s iPad", pairedAt: 1_000)
        try store.save(phone)
        try store.save(tablet)
        let coordinator = PairingCoordinator(trustedClientStore: store)
        coordinator.refreshPairedDevices()
        #expect(coordinator.pairedDevices == [phone, tablet])

        coordinator.revokePeer(signingPublicKey: phone.signingPublicKey)

        #expect(try store.records() == [tablet])
        #expect(coordinator.pairedDevices == [tablet])
        #expect(coordinator.pairedDevicesError == nil)
    }

    private static func record(_ name: String, pairedAt: TimeInterval = 1_000) -> TrustedPeerRecord {
        TrustedPeerRecord(
            signingPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            keyAgreementPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            serviceName: "Studio-Mac",
            displayName: name,
            approvedCapabilities: SessionCapability.assistantDefaults,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000 + pairedAt)
        )
    }
}

private final class TrustMemoryStorage: TrustedClientStorage {
    private var data: Data?

    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}
