@preconcurrency import Network
import CryptoKit
import Foundation
import HermesCaptureProtocol

struct PendingPairing: @unchecked Sendable {
    let channel: PeerSessionChannel
    let sessionID: String
    let deviceID: String
    let deviceName: String
    let requestedCapabilities: Set<SessionCapability>
    let clientSigningPublicKey: Data
    let clientKeyAgreementPublicKey: Data
    let serviceName: String
    let isReconnect: Bool
}

actor PairingServer {
    private let replayProtector = PairingReplayProtector()
    private let queue = DispatchQueue(
        label: "com.67enterprise.hermescapture.pairing-server"
    )

    func accept(
        connection: NWConnection,
        offer: SignedPairingPayload,
        identity: PairingIdentity,
        connectionIsEstablished: Bool = false,
        wireTransport: RelayWireTransport = .tlsTCP
    ) async throws -> PendingPairing {
        let request = try await receiveRequest(
            connection: connection,
            connectionIsEstablished: connectionIsEstablished,
            wireTransport: wireTransport,
            offer: offer,
            identity: identity
        )
        try request.verify(expectedNonce: offer.payload.nonce)
        try await replayProtector.consume(offer.payload)

        let cipher = try SessionCipher(
            localPrivateKey: identity.keyAgreementKey,
            remotePublicKey: request.payload.clientKeyAgreementPublicKey,
            pairingNonce: offer.payload.nonce,
            role: .mac
        )
        let channel = PeerSessionChannel(
            connection: connection,
            cipher: cipher,
            wireTransport: wireTransport
        )
        try channel.adoptEstablishedConnection()
        try channel.markPeerAuthenticated()
        return PendingPairing(
            channel: channel,
            sessionID: UUID().uuidString,
            deviceID: SHA256.hash(
                data: request.payload.clientSigningPublicKey
            ).map { String(format: "%02x", $0) }.joined(),
            deviceName: request.payload.deviceName,
            requestedCapabilities: request.payload.requestedCapabilities,
            clientSigningPublicKey: request.payload.clientSigningPublicKey,
            clientKeyAgreementPublicKey: request.payload.clientKeyAgreementPublicKey,
            serviceName: offer.payload.serviceName,
            isReconnect: false
        )
    }

    private func receiveRequest(
        connection: NWConnection,
        connectionIsEstablished: Bool,
        wireTransport: RelayWireTransport,
        offer: SignedPairingPayload,
        identity: PairingIdentity
    ) async throws -> SignedPairingRequest {
        try await withCheckedThrowingContinuation { continuation in
            let maximumPayloadBytes: Int
            let decode: (Data) throws -> SignedPairingRequest
            if connectionIsEstablished {
                maximumPayloadBytes = RelayPairingHandshakeCodec.maximumBytes
                decode = { framed in
                    let encrypted = try RelayPairingHandshakeCodec.decode(framed)
                    return try RelayPairingHandshake.open(
                        encrypted,
                        macPrivateKey: identity.keyAgreementKey,
                        pairingNonce: offer.payload.nonce
                    )
                }
            } else {
                maximumPayloadBytes = PairingHandshakeCodec.maximumBytes
                decode = PairingHandshakeCodec.decode
            }
            let receiver = PairingRequestReceiver(
                connection: connection,
                maximumPayloadBytes: maximumPayloadBytes,
                wireTransport: wireTransport,
                decode: decode,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                receiver.handle(state)
            }
            if connectionIsEstablished {
                receiver.receiveMore()
            } else {
                connection.start(queue: queue)
            }
        }
    }
}

private final class PairingRequestReceiver: @unchecked Sendable {
    private let connection: NWConnection
    private let maximumPayloadBytes: Int
    private let wireTransport: RelayWireTransport
    private let decode: (Data) throws -> SignedPairingRequest
    private let continuation: CheckedContinuation<SignedPairingRequest, any Error>
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init(
        connection: NWConnection,
        maximumPayloadBytes: Int,
        wireTransport: RelayWireTransport,
        decode: @escaping (Data) throws -> SignedPairingRequest,
        continuation: CheckedContinuation<SignedPairingRequest, any Error>
    ) {
        self.connection = connection
        self.maximumPayloadBytes = maximumPayloadBytes
        self.wireTransport = wireTransport
        self.decode = decode
        self.continuation = continuation
    }

    func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receiveMore()
        case let .failed(error):
            finish(.failure(error))
        case .cancelled:
            finish(.failure(PeerSessionChannelError.connectionClosed))
        default:
            break
        }
    }

    func receiveMore() {
        if wireTransport == .secureWebSocket {
            connection.receiveMessage { [self] data, context, complete, error in
                if let error {
                    handle(data: data, complete: complete, error: error)
                    return
                }
                switch wireTransport.classify(context) {
                case .control:
                    receiveMore()
                case .closed:
                    finish(.failure(PeerSessionChannelError.connectionClosed))
                case .payload where complete:
                    handle(data: data, complete: true, error: nil)
                case .payload, .unexpected:
                    finish(.failure(PeerSessionError.invalidPacket))
                }
            }
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumPayloadBytes + 4
        ) { [self] data, _, complete, error in
            handle(data: data, complete: complete, error: error)
        }
    }

    private func handle(data: Data?, complete: Bool, error: NWError?) {
        if let error {
            finish(.failure(error))
            return
        }
        if let data { buffer.append(data) }
        do {
            if let request = try completeRequestIfAvailable() {
                finish(.success(request))
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

    private func completeRequestIfAvailable() throws -> SignedPairingRequest? {
        guard buffer.count >= 4 else { return nil }
        var size: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &size) {
            buffer.copyBytes(to: $0, from: 0..<4)
        }
        let payloadSize = Int(UInt32(bigEndian: size))
        guard payloadSize <= maximumPayloadBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        guard buffer.count >= payloadSize + 4 else { return nil }
        guard buffer.count == payloadSize + 4 else {
            throw PeerSessionError.invalidPacket
        }
        return try decode(buffer)
    }

    private func finish(
        _ result: Result<SignedPairingRequest, any Error>
    ) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        switch result {
        case let .success(request):
            continuation.resume(returning: request)
        case let .failure(error):
            connection.cancel()
            continuation.resume(throwing: error)
        }
    }
}
