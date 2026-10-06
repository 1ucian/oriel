@preconcurrency import Network
import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

struct PeerSessionLoopbackTests {
    @Test func encryptedLoopbackRejectsPreapprovalThenCarriesInput() async throws {
        let queue = DispatchQueue(label: "hermescapture.loopback-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = ConnectionHolder()
        let listenerState = ListenerStateHolder()
        listener.newConnectionHandler = { accepted.store($0) }
        listener.stateUpdateHandler = { listenerState.store($0) }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let port = try await waitForPort(listener, state: listenerState)
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data(repeating: 19, count: 24)

        let clientConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let client = try PeerSessionChannel(
            connection: clientConnection,
            cipher: SessionCipher(
                localPrivateKey: clientKey,
                remotePublicKey: macKey.publicKey.rawRepresentation,
                pairingNonce: nonce,
                role: .client
            ),
            queue: queue
        )
        client.start()

        let serverConnection = try await waitForConnection(accepted)
        let server = try PeerSessionChannel(
            connection: serverConnection,
            cipher: SessionCipher(
                localPrivateKey: macKey,
                remotePublicKey: clientKey.publicKey.rawRepresentation,
                pairingNonce: nonce,
                role: .mac
            ),
            queue: queue
        )
        server.start()

        try await waitUntil {
            client.currentState == .authenticating
                && server.currentState == .authenticating
        }
        try client.markPeerAuthenticated()
        try server.markPeerAuthenticated()

        #expect(throws: PeerSessionError.controlNotAuthorized) {
            try client.send(
                .input(.pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)))
            )
        }

        let received = PacketHolder()
        server.onPacket = { received.store($0) }
        let clientStates = StateLog()
        client.onStateChange = { clientStates.append($0) }
        try server.approve(capabilities: SessionCapability.phaseOneDefaults)
        try await waitUntil {
            client.currentState == .active && server.currentState == .active
        }

        let event = RemoteInputEvent.pointerMove(
            try NormalizedPoint(x: 0.25, y: 0.75)
        )
        try client.send(.input(event))
        try await waitUntil {
            received.packet == .input(event)
        }

        // Heartbeats keep an active session active; listeners hear about it once (the phone
        // saves its trusted-Mac record on every "active" it hears).
        try await Task.sleep(for: .seconds(4.5))
        #expect(client.currentState == .active)
        #expect(clientStates.states.filter { $0 == .active }.count == 1, "heard: \(clientStates.states)")

        client.close(reason: "test-complete")
        try await waitUntil { server.currentState == .closed }
        #expect(server.currentState == .closed)
        #expect(server.peerCloseReason == "test-complete")
        server.close(reason: "test-complete")
    }

    @Test func startingAfterCloseDoesNotScheduleHeartbeat() throws {
        let queue = DispatchQueue(label: "hermescapture.closed-start-test")
        let localKey = Curve25519.KeyAgreement.PrivateKey()
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: 9,
            using: .tcp
        )
        let channel = try PeerSessionChannel(
            connection: connection,
            cipher: SessionCipher(
                localPrivateKey: localKey,
                remotePublicKey: remoteKey.publicKey.rawRepresentation,
                pairingNonce: Data(repeating: 29, count: 24),
                role: .client
            ),
            queue: queue
        )

        channel.close(reason: "closed-before-start")
        channel.start()

        #expect(channel.currentState == .closed)
        #expect(channel.heartbeatTimerIsScheduled == false)
    }

    @Test func adoptedChannelClosesAfterAbruptPeerCancellation() async throws {
        let queue = DispatchQueue(label: "hermescapture.adopted-close-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = ConnectionHolder()
        let listenerState = ListenerStateHolder()
        listener.newConnectionHandler = { accepted.store($0) }
        listener.stateUpdateHandler = { listenerState.store($0) }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let port = try await waitForPort(listener, state: listenerState)
        let clientConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let clientState = ConnectionStateHolder()
        clientConnection.stateUpdateHandler = { clientState.store($0) }
        clientConnection.start(queue: queue)
        defer { clientConnection.cancel() }

        let serverConnection = try await waitForConnection(accepted)
        let serverState = ConnectionStateHolder()
        serverConnection.stateUpdateHandler = { serverState.store($0) }
        serverConnection.start(queue: queue)
        try await waitUntil {
            clientState.isReady && serverState.isReady
        }

        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let channel = try PeerSessionChannel(
            connection: serverConnection,
            cipher: SessionCipher(
                localPrivateKey: serverKey,
                remotePublicKey: clientKey.publicKey.rawRepresentation,
                pairingNonce: Data(repeating: 23, count: 24),
                role: .mac
            ),
            queue: queue
        )
        let closed = StateHolder()
        channel.onStateChange = { closed.store($0) }
        try channel.adoptEstablishedConnection()
        #expect(channel.currentState == .authenticating)

        clientConnection.cancel()
        try await waitUntil {
            channel.currentState == .closed && closed.lastState == .closed
        }
    }

    @Test func silentApprovedPeerTimesOutAndStopsHeartbeat() async throws {
        let queue = DispatchQueue(label: "oriel.silent-peer-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = ConnectionHolder()
        let listenerState = ListenerStateHolder()
        listener.newConnectionHandler = { accepted.store($0) }
        listener.stateUpdateHandler = { listenerState.store($0) }
        listener.start(queue: queue)
        defer { listener.cancel() }
        let port = try await waitForPort(listener, state: listenerState)
        let rawPeer = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        rawPeer.start(queue: queue)
        defer { rawPeer.cancel() }
        let connection = try await waitForConnection(accepted)
        let localKey = Curve25519.KeyAgreement.PrivateKey()
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        let channel = try PeerSessionChannel(
            connection: connection,
            cipher: SessionCipher(
                localPrivateKey: localKey,
                remotePublicKey: remoteKey.publicKey.rawRepresentation,
                pairingNonce: Data(repeating: 31, count: 24),
                role: .mac
            ),
            queue: queue
        )
        channel.start()
        defer { channel.close(reason: "test-cleanup") }
        try await waitUntil { channel.currentState == .authenticating }
        try channel.markPeerAuthenticated()
        try channel.approve(capabilities: SessionCapability.phaseOneDefaults)
        #expect(channel.currentState == .active)
        // The raw peer stays connected but deliberately sends no packets.
        try await Task.sleep(for: .seconds(7))
        #expect(channel.currentState == .stale)
        try await Task.sleep(for: .seconds(10))
        #expect(channel.currentState == .closed)
        #expect(channel.heartbeatTimerIsScheduled == false)
    }

    private func waitForPort(
        _ listener: NWListener,
        state: ListenerStateHolder
    ) async throws -> NWEndpoint.Port {
        var attempts = 0
        while attempts < 100 {
            if let error = state.error { throw error }
            if state.isReady, let port = listener.port { return port }
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PeerSessionChannelError.connectionFailed("listener-not-ready")
    }

    private func waitForConnection(
        _ holder: ConnectionHolder
    ) async throws -> NWConnection {
        var attempts = 0
        while attempts < 200 {
            if let connection = holder.connection { return connection }
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PeerSessionChannelError.connectionFailed("connection-not-accepted")
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        var attempts = 0
        while attempts < 200 {
            if condition() { return }
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PeerSessionChannelError.connectionFailed("condition-timed-out")
    }
}

private final class ListenerStateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var storedError: NWError?

    var isReady: Bool { lock.withLock { ready } }
    var error: NWError? { lock.withLock { storedError } }

    func store(_ state: NWListener.State) {
        lock.withLock {
            switch state {
            case .ready:
                ready = true
            case let .failed(error):
                storedError = error
            default:
                break
            }
        }
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PeerSessionState] = []

    var states: [PeerSessionState] { lock.withLock { stored } }

    func append(_ state: PeerSessionState) {
        lock.withLock { stored.append(state) }
    }
}

private final class ConnectionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConnection: NWConnection?

    var connection: NWConnection? {
        lock.withLock { storedConnection }
    }

    func store(_ connection: NWConnection) {
        lock.withLock { storedConnection = connection }
    }
}

private final class PacketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPacket: SessionPacket?

    var packet: SessionPacket? {
        lock.withLock { storedPacket }
    }

    func store(_ packet: SessionPacket) {
        lock.withLock { storedPacket = packet }
    }
}

private final class ConnectionStateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool { lock.withLock { ready } }

    func store(_ state: NWConnection.State) {
        if case .ready = state {
            lock.withLock { ready = true }
        }
    }
}

private final class StateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var state: PeerSessionState?

    var lastState: PeerSessionState? { lock.withLock { state } }

    func store(_ state: PeerSessionState) {
        lock.withLock { self.state = state }
    }
}
