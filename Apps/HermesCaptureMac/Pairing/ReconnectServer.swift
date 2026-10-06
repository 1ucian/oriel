@preconcurrency import Network
import CryptoKit
import Foundation
import HermesCaptureProtocol
import Security

enum ReconnectServerError: Error {
    case handshakeTimedOut
}

struct AcceptedReconnect: @unchecked Sendable {
    let channel: PeerSessionChannel
    let sessionID: String
    let deviceID: String
    let deviceName: String
    let requestedCapabilities: Set<SessionCapability>
    let trustedPeer: TrustedPeerRecord
    let decision: ReconnectCapabilityDecision
}

actor ReconnectServer {
    private let replayProtector = ReconnectReplayProtector()
    private let queue = DispatchQueue(
        label: "com.67enterprise.oriel.reconnect-server",
        qos: .userInitiated
    )

    func accept(
        connection: NWConnection,
        identity: PairingIdentity,
        serviceName: String,
        trustedPeers: [TrustedPeerRecord],
        connectionIsEstablished: Bool = false,
        wireTransport: RelayWireTransport = .tlsTCP
    ) async throws -> AcceptedReconnect {
        if !connectionIsEstablished {
            try await startAndWaitUntilReady(connection)
        }
        let now = Date.now
        let challengePayload = ReconnectChallengePayload(
            macKeyAgreementPublicKey: identity.keyAgreementKey.publicKey.rawRepresentation,
            macSigningPublicKey: identity.signingKey.publicKey.rawRepresentation,
            nonce: try secureRandomData(count: 24),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            serviceName: serviceName
        )
        let challenge = try SignedReconnectChallenge.sign(
            challengePayload,
            with: identity.signingKey
        )
        try await send(
            ReconnectHandshakeCodec.encode(challenge),
            over: connection,
            contentContext: wireTransport.makeSendContext()
        )
        let requestData = try await receiveFrameBeforeDeadline(
            over: connection,
            maximumBytes: ReconnectHandshakeCodec.maximumBytes,
            wireTransport: wireTransport
        )
        let request = try ReconnectHandshakeCodec.decodeRequest(requestData)
        let trustedPeer = try ReconnectAuthorization.authorize(
            request: request,
            challenge: challengePayload,
            trustedPeers: trustedPeers
        )
        try await replayProtector.consume(challengePayload)
        let decision = try ReconnectCapabilityDecision.evaluate(
            requested: request.payload.requestedCapabilities,
            approved: trustedPeer.approvedCapabilities
        )
        let cipher = try SessionCipher(
            localPrivateKey: identity.keyAgreementKey,
            remotePublicKey: trustedPeer.keyAgreementPublicKey,
            pairingNonce: challengePayload.nonce,
            role: .mac
        )
        let channel = PeerSessionChannel(connection: connection, cipher: cipher, wireTransport: wireTransport)
        try channel.adoptEstablishedConnection()
        try channel.markPeerAuthenticated()
        return AcceptedReconnect(
            channel: channel,
            sessionID: UUID().uuidString,
            deviceID: trustedPeer.id,
            deviceName: request.payload.deviceName,
            requestedCapabilities: request.payload.requestedCapabilities,
            trustedPeer: trustedPeer,
            decision: decision
        )
    }

    private func startAndWaitUntilReady(_ connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = ReconnectConnectionReadyWaiter(
                    connection: connection,
                    continuation: continuation
                )
                connection.stateUpdateHandler = waiter.handle
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func send(
        _ data: Data,
        over connection: NWConnection,
        contentContext: NWConnection.ContentContext = .defaultMessage
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: data,
                    contentContext: contentContext,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func receiveFrameBeforeDeadline(
        over connection: NWConnection,
        maximumBytes: Int,
        wireTransport: RelayWireTransport = .tlsTCP
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [self] in
                try await receiveFrame(
                    over: connection,
                    maximumBytes: maximumBytes,
                    wireTransport: wireTransport
                )
            }
            group.addTask {
                try await Task.sleep(
                    for: .seconds(ReconnectHandshakePolicy.timeoutSeconds)
                )
                throw ReconnectServerError.handshakeTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ReconnectServerError.handshakeTimedOut
            }
            return first
        }
    }

    private func receiveFrame(
        over connection: NWConnection,
        maximumBytes: Int,
        wireTransport: RelayWireTransport = .tlsTCP
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                ReconnectFrameReceiver(
                    connection: connection,
                    maximumBytes: maximumBytes,
                    wireTransport: wireTransport,
                    continuation: continuation
                ).receiveMore()
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PairingIdentityStoreError.keychain(status)
        }
        return data
    }
}

private final class ReconnectConnectionReadyWaiter: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, any Error>
    private let lock = NSLock()
    private var finished = false

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finish(.success(()))
        case let .failed(error):
            finish(.failure(error))
        case .cancelled:
            finish(.failure(PeerSessionChannelError.connectionClosed))
        default:
            break
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            connection.cancel()
            continuation.resume(throwing: error)
        }
    }
}

private final class ReconnectFrameReceiver: @unchecked Sendable {
    private let connection: NWConnection
    private let maximumBytes: Int
    private let wireTransport: RelayWireTransport
    private let continuation: CheckedContinuation<Data, any Error>
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init(
        connection: NWConnection,
        maximumBytes: Int,
        wireTransport: RelayWireTransport = .tlsTCP,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        self.connection = connection
        self.maximumBytes = maximumBytes
        self.wireTransport = wireTransport
        self.continuation = continuation
    }

    func receiveMore() {
        if wireTransport == .secureWebSocket {
            // Over the relay each handshake frame arrives as one WebSocket message.
            connection.receiveMessage { [self] data, context, complete, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                switch wireTransport.classify(context) {
                case .control:
                    receiveMore()
                    return
                case .closed:
                    finish(.failure(PeerSessionChannelError.connectionClosed))
                    return
                case .unexpected:
                    finish(.failure(RelayError.invalidFrame))
                    return
                case .payload:
                    break
                }
                if let data { buffer.append(data) }
                do {
                    if let frame = try completeFrameIfAvailable() {
                        finish(.success(frame))
                        return
                    }
                } catch {
                    finish(.failure(error))
                    return
                }
                if complete {
                    finish(.failure(PeerSessionError.invalidPacket))
                } else {
                    receiveMore()
                }
            }
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumBytes + 4
        ) { [self] data, _, complete, error in
            if let error {
                finish(.failure(error))
                return
            }
            if let data { buffer.append(data) }
            do {
                if let frame = try completeFrameIfAvailable() {
                    finish(.success(frame))
                    return
                }
            } catch {
                finish(.failure(error))
                return
            }
            if complete {
                finish(.failure(PeerSessionError.invalidPacket))
            } else {
                receiveMore()
            }
        }
    }

    private func completeFrameIfAvailable() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        var size: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &size) {
            buffer.copyBytes(to: $0, from: 0..<4)
        }
        let payloadSize = Int(UInt32(bigEndian: size))
        guard payloadSize <= maximumBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        guard buffer.count >= payloadSize + 4 else { return nil }
        guard buffer.count == payloadSize + 4 else {
            throw PeerSessionError.invalidPacket
        }
        return buffer
    }

    private func finish(_ result: Result<Data, any Error>) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        switch result {
        case let .success(data):
            continuation.resume(returning: data)
        case let .failure(error):
            connection.cancel()
            continuation.resume(throwing: error)
        }
    }
}
