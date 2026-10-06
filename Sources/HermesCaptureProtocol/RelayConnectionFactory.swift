@preconcurrency import Network
import CryptoKit
import Foundation
import Security

public enum RelayConnectionFactory {
    public static func connect(
        route: RelayRoute,
        pairingNonce: Data,
        role: RelayPeerRole,
        signingKey: Curve25519.Signing.PrivateKey,
        queue: DispatchQueue = DispatchQueue(
            label: "com.67enterprise.oriel.relay-connection",
            qos: .userInitiated
        ),
        registrationLifetime: TimeInterval = 60
    ) async throws -> NWConnection {
        try route.validate()
        let registration = try RelayRegistration.sign(
            role: role,
            route: route,
            pairingNonce: pairingNonce,
            signingKey: signingKey,
            connectionNonce: try secureRandomData(count: 24),
            expiresAt: min(
                route.expiresAt,
                Date.now.addingTimeInterval(registrationLifetime)
            )
        )

        let connection = try route.transport.makeConnection(route: route)

        return try await withTaskCancellationHandler {
            do {
                try await startAndWaitUntilReady(connection, queue: queue)
                try await send(
                    RelayHandshakeCodec.encode(registration),
                    over: connection,
                    contentContext: route.transport.makeSendContext()
                )
                let keepalive = startKeepalive(over: connection, transport: route.transport)
                defer { keepalive.cancel() }
                let acknowledgement = try await receiveExactly(
                    RelayHandshakeCodec.acknowledgement.count,
                    over: connection,
                    transport: route.transport
                )
                guard acknowledgement == RelayHandshakeCodec.acknowledgement else {
                    throw RelayError.invalidFrame
                }
                return connection
            } catch {
                connection.cancel()
                throw error
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// A host can wait minutes for a peer. Pings keep the proxied WebSocket open; the
    /// task ends with the wait. Over TLS/TCP there is nothing to send.
    private static func startKeepalive(
        over connection: NWConnection,
        transport: RelayWireTransport
    ) -> Task<Void, any Error> {
        Task {
            guard let context = transport.makeKeepaliveContext() else { return }
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(RelayWireTransport.keepaliveInterval))
                try await send(Data(), over: connection, contentContext: context)
            }
        }
    }

    private static func startAndWaitUntilReady(
        _ connection: NWConnection,
        queue: DispatchQueue
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let waiter = RelayConnectionReadyWaiter(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = waiter.handle
            connection.start(queue: queue)
        }
    }

    private static func send(
        _ data: Data,
        over connection: NWConnection,
        contentContext: NWConnection.ContentContext
    ) async throws {
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
            })
        }
    }

    private static func receiveExactly(
        _ byteCount: Int,
        over connection: NWConnection,
        transport: RelayWireTransport
    ) async throws -> Data {
        let receiver = RelayAcknowledgementReceiver(
            expectedBytes: byteCount
        ) { maximumLength, completion in
            if transport == .secureWebSocket {
                connection.receiveMessage { data, context, complete, error in
                    if let error {
                        completion(nil, complete, error)
                        return
                    }
                    switch transport.classify(context) {
                    case .payload where (data?.count ?? 0) <= maximumLength:
                        completion(data, complete, nil)
                    case .control:
                        completion(nil, false, nil)
                    case .closed:
                        completion(nil, true, PeerSessionChannelError.connectionClosed)
                    case .payload, .unexpected:
                        completion(nil, complete, RelayError.invalidFrame)
                    }
                }
            } else {
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: maximumLength
                ) { data, _, complete, error in
                    completion(data, complete, error)
                }
            }
        }
        return try await receiver.receive()
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw RelayError.invalidRoute }
        return data
    }
}

enum RelayConnectionStateTransition {
    case ready
    case failed(any Error)
    case ignore
}

enum RelayConnectionStatePolicy {
    static func transition(
        for state: NWConnection.State
    ) -> RelayConnectionStateTransition {
        switch state {
        case .ready:
            return .ready
        case let .waiting(error), let .failed(error):
            return .failed(error)
        case .cancelled:
            return .failed(PeerSessionChannelError.connectionClosed)
        default:
            return .ignore
        }
    }
}

private final class RelayConnectionReadyWaiter: @unchecked Sendable {
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
        switch RelayConnectionStatePolicy.transition(for: state) {
        case .ready:
            finish(.success(()))
        case let .failed(error):
            finish(.failure(error))
        case .ignore:
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
            continuation.resume(throwing: error)
        }
    }
}

final class RelayAcknowledgementReceiver: @unchecked Sendable {
    typealias ReceiveCompletion = @Sendable (
        Data?,
        Bool,
        (any Error)?
    ) -> Void
    typealias ReceiveOperation = @Sendable (
        Int,
        @escaping ReceiveCompletion
    ) -> Void

    private let expectedBytes: Int
    private let receiveOperation: ReceiveOperation
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var terminalResult: Result<Data, any Error>?

    init(
        expectedBytes: Int,
        receive: @escaping ReceiveOperation
    ) {
        self.expectedBytes = expectedBytes
        receiveOperation = receive
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult = lock.withLock {
                    () -> Result<Data, any Error>? in
                    if let terminalResult { return terminalResult }
                    guard self.continuation == nil else {
                        return .failure(RelayError.invalidFrame)
                    }
                    self.continuation = continuation
                    return nil
                }
                if let immediateResult {
                    resume(continuation, with: immediateResult)
                } else {
                    receiveMore()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func receiveMore() {
        let maximumLength = lock.withLock { () -> Int? in
            guard terminalResult == nil else { return nil }
            return expectedBytes - buffer.count
        }
        guard let maximumLength, maximumLength > 0 else { return }
        receiveOperation(maximumLength) { [self] data, complete, error in
            handle(data: data, complete: complete, error: error)
        }
    }

    private func handle(
        data: Data?,
        complete: Bool,
        error: (any Error)?
    ) {
        let action = lock.withLock {
            () -> (Result<Data, any Error>?, Bool) in
            guard terminalResult == nil else { return (nil, false) }
            if let error { return (.failure(error), false) }
            if let data { buffer.append(data) }
            if buffer.count == expectedBytes {
                return (.success(buffer), false)
            }
            if complete || buffer.count > expectedBytes {
                return (.failure(RelayError.invalidFrame), false)
            }
            return (nil, true)
        }
        if let result = action.0 {
            finish(result)
        } else if action.1 {
            receiveMore()
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<Data, any Error>? in
            guard terminalResult == nil else { return nil }
            terminalResult = result
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<Data, any Error>,
        with result: Result<Data, any Error>
    ) {
        switch result {
        case let .success(data):
            continuation.resume(returning: data)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
