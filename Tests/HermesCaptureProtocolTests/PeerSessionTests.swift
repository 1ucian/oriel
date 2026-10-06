import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

struct PeerSessionTests {
    @Test func sessionRefusesControlUntilAuthenticatedAndApproved() throws {
        var machine = PeerSessionStateMachine()
        #expect(throws: PeerSessionError.invalidTransition) {
            try machine.handle(.controlReceived)
        }

        try machine.handle(.connectionEstablished)
        try machine.handle(.peerAuthenticated)
        #expect(machine.state == .awaitingApproval)
        #expect(throws: PeerSessionError.controlNotAuthorized) {
            try machine.handle(.controlReceived)
        }

        try machine.handle(.approved(capabilities: [.viewScreen, .controlPointer]))
        try machine.handle(.controlReceived)
        #expect(machine.state == .active)
    }

    @Test func revocationClosesSessionImmediately() throws {
        var machine = PeerSessionStateMachine()
        try machine.handle(.connectionEstablished)
        try machine.handle(.peerAuthenticated)
        try machine.handle(.approved(capabilities: [.viewScreen]))
        try machine.handle(.revoked)
        #expect(machine.state == .closed)
        #expect(machine.capabilities.isEmpty)
    }

    @Test func directionalCipherRoundTripsAndRejectsReplay() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data(repeating: 0xA7, count: 32)
        let mac = try SessionCipher(
            localPrivateKey: macKey,
            remotePublicKey: clientKey.publicKey.rawRepresentation,
            pairingNonce: nonce,
            role: .mac
        )
        let client = try SessionCipher(
            localPrivateKey: clientKey,
            remotePublicKey: macKey.publicKey.rawRepresentation,
            pairingNonce: nonce,
            role: .client
        )
        let packet = SessionPacket.heartbeat(monotonicNanoseconds: 42)

        let envelope = try mac.seal(packet)
        #expect(try client.open(envelope) == packet)
        #expect(throws: PeerSessionError.replayedPacket) {
            try client.open(envelope)
        }
    }

    @Test func tamperedCiphertextFailsClosed() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data(repeating: 0x11, count: 32)
        let mac = try SessionCipher(
            localPrivateKey: macKey,
            remotePublicKey: clientKey.publicKey.rawRepresentation,
            pairingNonce: nonce,
            role: .mac
        )
        let client = try SessionCipher(
            localPrivateKey: clientKey,
            remotePublicKey: macKey.publicKey.rawRepresentation,
            pairingNonce: nonce,
            role: .client
        )
        let envelope = try mac.seal(.heartbeat(monotonicNanoseconds: 1))
        var bytes = envelope.sealedData
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xFF

        #expect(throws: PeerSessionError.authenticationFailed) {
            try client.open(.init(counter: envelope.counter, sealedData: bytes))
        }
    }

    @Test func packetCodecRejectsOversizedVideo() {
        let packet = SessionPacket.video(
            .init(
                sequence: 1,
                presentationTimeNanoseconds: 1,
                isKeyFrame: true,
                payload: Data(count: SessionPacket.maximumVideoBytes + 1)
            )
        )
        #expect(throws: PeerSessionError.payloadTooLarge) {
            try SessionPacketCodec.encode(packet)
        }
    }
}
