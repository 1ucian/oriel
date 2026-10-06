import CryptoKit
import Foundation
@preconcurrency import Network
import Testing
@testable import HermesCaptureProtocol

struct RelayProtocolTests {
    /// The iOS app is not in the open-source tree; its contract checks run only where it is.
    static let iOSCoordinatorPath = "Apps/HermesCaptureIOS/Pairing/PairingClientCoordinator.swift"
    static var iOSSourcesPresent: Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(iOSCoordinatorPath).path
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    private func route() -> RelayRoute {
        RelayRoute(
            host: "relay.example.com",
            port: 443,
            roomID: Data(repeating: 0x11, count: 24),
            accessKey: Data(repeating: 0x22, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_300)
        )
    }

    @Test func pairingPayloadCarriesSignedRelayRouteAndLegacyPayloadStillDecodes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = PairingPayload(
            macPublicKey: Data(repeating: 7, count: 32),
            nonce: Data(repeating: 9, count: 24),
            expiresAt: Date(timeIntervalSince1970: 1_300),
            serviceName: "Studio-Mac",
            relayRoute: route()
        )
        let signed = try SignedPairingPayload.sign(payload, with: key)
        let decoded = try SignedPairingPayload(
            qrEncodedString: signed.qrEncodedString()
        )

        #expect(decoded == signed)
        #expect(try decoded.verifyEmbedded(at: now))
        #expect(decoded.payload.relayRoute == route())

        let legacyJSON = #"{"expiresAt":1300000,"macPublicKey":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=","nonce":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJ","protocolVersion":1,"serviceName":"Studio-Mac"}"#
        let legacy = try PairingPayload(
            qrEncodedString: Data(legacyJSON.utf8).base64URLEncodedForTest()
        )
        #expect(legacy.relayRoute == nil)
        try legacy.validate(at: now)
    }

    @Test func relayRouteRejectsExpiredAndMalformedCapabilities() {
        #expect(throws: RelayError.expired) {
            try route().validate(at: Date(timeIntervalSince1970: 1_301))
        }
        #expect(throws: RelayError.invalidRoute) {
            try RelayRoute(
                host: "",
                port: 443,
                roomID: Data(repeating: 1, count: 24),
                accessKey: Data(repeating: 2, count: 32),
                expiresAt: Date(timeIntervalSince1970: 1_300)
            ).validate(at: now)
        }
    }

    @Test func registrationsAreIdentitySignedRoleBoundAndFramed() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let pairingNonce = Data(repeating: 0x33, count: 24)
        let registration = try RelayRegistration.sign(
            role: .host,
            route: route(),
            pairingNonce: pairingNonce,
            signingKey: signingKey,
            connectionNonce: Data(repeating: 0x44, count: 24),
            expiresAt: Date(timeIntervalSince1970: 1_200)
        )

        #expect(
            try registration.verify(
                route: route(),
                pairingNonce: pairingNonce,
                expectedRole: .host,
                at: now
            )
        )
        #expect(throws: RelayError.roleMismatch) {
            try registration.verify(
                route: route(),
                pairingNonce: pairingNonce,
                expectedRole: .client,
                at: now
            )
        }

        let framed = try RelayHandshakeCodec.encode(registration)
        #expect(try RelayHandshakeCodec.decode(framed) == registration)
        #expect(throws: RelayError.invalidFrame) {
            try RelayHandshakeCodec.decode(framed + Data([0]))
        }
    }

    @Test func relayPairingRequestIsEncryptedEndToEndAndTamperingFails() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let clientSigningKey = Curve25519.Signing.PrivateKey()
        let pairingNonce = Data(repeating: 0x77, count: 24)
        let requestPayload = PairingRequestPayload(
            pairingNonce: pairingNonce,
            clientKeyAgreementPublicKey: clientKey.publicKey.rawRepresentation,
            clientSigningPublicKey: clientSigningKey.publicKey.rawRepresentation,
            deviceName: "Private iPhone Name",
            requestedCapabilities: SessionCapability.phaseOneDefaults,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let request = try SignedPairingRequest.sign(
            requestPayload,
            with: clientSigningKey
        )

        let encrypted = try RelayPairingHandshake.seal(
            request,
            clientPrivateKey: clientKey,
            macPublicKey: macKey.publicKey.rawRepresentation,
            pairingNonce: pairingNonce
        )
        let framed = try RelayPairingHandshakeCodec.encode(encrypted)
        #expect(!framed.contains(Data("Private iPhone Name".utf8)))
        #expect(
            try RelayPairingHandshake.open(
                encrypted,
                macPrivateKey: macKey,
                expectedClientPublicKey: clientKey.publicKey.rawRepresentation,
                pairingNonce: pairingNonce
            ) == request
        )

        var damaged = encrypted.sealedRequest
        damaged[damaged.startIndex] ^= 1
        let tampered = EncryptedRelayPairingRequest(
            clientKeyAgreementPublicKey: encrypted.clientKeyAgreementPublicKey,
            sealedRequest: damaged
        )
        #expect(throws: PeerSessionError.authenticationFailed) {
            try RelayPairingHandshake.open(
                tampered,
                macPrivateKey: macKey,
                expectedClientPublicKey: clientKey.publicKey.rawRepresentation,
                pairingNonce: pairingNonce
            )
        }
    }

    @Test func registrationTamperingAndConnectionNonceReplayFailClosed() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let pairingNonce = Data(repeating: 0x55, count: 24)
        let registration = try RelayRegistration.sign(
            role: .client,
            route: route(),
            pairingNonce: pairingNonce,
            signingKey: signingKey,
            connectionNonce: Data(repeating: 0x66, count: 24),
            expiresAt: Date(timeIntervalSince1970: 1_200)
        )
        let tampered = RelayRegistration(
            payload: RelayRegistrationPayload(
                protocolVersion: registration.payload.protocolVersion,
                role: .host,
                roomID: registration.payload.roomID,
                rendezvousTag: registration.payload.rendezvousTag,
                pairingNonceDigest: registration.payload.pairingNonceDigest,
                signingPublicKey: registration.payload.signingPublicKey,
                connectionNonce: registration.payload.connectionNonce,
                expiresAt: registration.payload.expiresAt
            ),
            signature: registration.signature
        )
        #expect(throws: RelayError.invalidSignature) {
            try tampered.verify(at: now)
        }

        let protector = RelayRegistrationReplayProtector()
        try await protector.consume(registration, at: now)
        do {
            try await protector.consume(registration, at: now)
            Issue.record("Expected relay registration replay rejection")
        } catch let error as RelayError {
            #expect(error == .replayed)
        }
    }

    @Test func secureWebSocketRouteRoundTripsAndLegacyRoutesDefaultToTLSTCP() throws {
        let wssRoute = RelayRoute(
            host: "relay.example.com",
            port: 443,
            roomID: Data(repeating: 0x11, count: 24),
            accessKey: Data(repeating: 0x22, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_300),
            transport: .secureWebSocket
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(wssRoute)
        #expect(try decoder.decode(RelayRoute.self, from: encoded) == wssRoute)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "transport")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        #expect(
            try decoder.decode(RelayRoute.self, from: legacyData).transport == .tlsTCP
        )
    }

    @Test func secureWebSocketTransportUsesWSSURLAndBinaryMessageMetadata() throws {
        let route = RelayRoute(
            host: "relay.example.com",
            port: 443,
            roomID: Data(repeating: 0x11, count: 24),
            accessKey: Data(repeating: 0x22, count: 32),
            expiresAt: Date(timeIntervalSince1970: 1_300),
            transport: .secureWebSocket
        )
        #expect(RelayWireTransport.endpointURL(for: route)?.absoluteString == "wss://relay.example.com:443/oriel")
        let context = RelayWireTransport.secureWebSocket.makeSendContext()
        let metadata = context.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata
        #expect(metadata?.opcode == .binary)
    }

    @Test func webSocketMessagesAreClassifiedByOpcode() {
        func context(_ opcode: NWProtocolWebSocket.Opcode) -> NWConnection.ContentContext {
            NWConnection.ContentContext(
                identifier: "test",
                metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)]
            )
        }
        let webSocket = RelayWireTransport.secureWebSocket
        #expect(webSocket.classify(context(.binary)) == .payload)
        #expect(webSocket.classify(context(.ping)) == .control)
        #expect(webSocket.classify(context(.pong)) == .control)
        #expect(webSocket.classify(context(.close)) == .closed)
        #expect(webSocket.classify(context(.text)) == .unexpected)
        #expect(webSocket.classify(nil) == .unexpected)
        #expect(webSocket.isExpectedMessage(context(.binary)))
        #expect(!webSocket.isExpectedMessage(context(.pong)))
        // TLS/TCP has no framing: every read is protocol bytes.
        #expect(RelayWireTransport.tlsTCP.classify(nil) == .payload)
        #expect(RelayWireTransport.tlsTCP.classify(context(.text)) == .payload)
    }

    @Test func keepalivePingsExistOnlyForWebSocketsAndBeatTheProxyIdleLimit() throws {
        #expect(RelayWireTransport.tlsTCP.makeKeepaliveContext() == nil)
        let context = try #require(RelayWireTransport.secureWebSocket.makeKeepaliveContext())
        let metadata = context.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata
        #expect(metadata?.opcode == .ping)
        // Cloudflare closes a proxied WebSocket after 100 idle seconds.
        #expect(RelayWireTransport.keepaliveInterval < 100)
        #expect(RelayWireTransport.keepaliveInterval >= 15)
    }

    @Test func everyWebSocketReceiverReadsPastKeepaliveFrames() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let receivers = [
            "Sources/HermesCaptureProtocol/RelayConnectionFactory.swift",
            "Sources/HermesCaptureProtocol/PeerSessionChannel.swift",
            "Apps/HermesCaptureMac/Pairing/ReconnectServer.swift",
            "Apps/HermesCaptureMac/Pairing/PairingServer.swift",
        ] + (Self.iOSSourcesPresent ? [Self.iOSCoordinatorPath] : [])
        for path in receivers {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains(".classify(context)"), "\(path) must classify WebSocket messages")
            #expect(source.contains("case .control"), "\(path) must read past ping and pong frames")
        }
        let factory = try String(contentsOf: root.appendingPathComponent(receivers[0]), encoding: .utf8)
        #expect(factory.contains("startKeepalive(over: connection, transport: route.transport)"))
        #expect(factory.contains("keepalive.cancel()"))
    }

    @Test func secureWebSocketUsesNWParametersTLSPresetForURLConnections() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/HermesCaptureProtocol/RelayProtocol.swift"
        ), encoding: .utf8)
        let secureBranch = try #require(
            source.components(separatedBy: "case .secureWebSocket:").last
        )

        #expect(secureBranch.contains("let parameters = NWParameters.tls"))
    }

    @Test func waitingRelayConnectionStateTriggersRetry() {
        let transition = RelayConnectionStatePolicy.transition(
            for: .waiting(.posix(.ETIMEDOUT))
        )

        guard case .failed = transition else {
            Issue.record("Waiting relay connection state must fail the current attempt")
            return
        }
    }

    @Test func acknowledgementReceiverSurvivesFragmentationAndDuplicateCompletion() async throws {
        let script = RelayReceiveScript([
            .success((Data("OR".utf8), false)),
            .success((Data("OK".utf8), false)),
        ])
        let receiver = RelayAcknowledgementReceiver(
            expectedBytes: 4,
            receive: script.receive
        )

        let acknowledgement = try await receiver.receive()
        script.completeAgainAfterSuccess()

        #expect(acknowledgement == Data("OROK".utf8))
        #expect(script.receiveCount == 2)
    }

    @Test func acknowledgementReceiverCancellationResumesWithoutNetworkCallback() async {
        let script = RelayReceiveScript([])
        let receiver = RelayAcknowledgementReceiver(
            expectedBytes: 4,
            receive: script.receive
        )
        let task = Task { try await receiver.receive() }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected acknowledgement wait cancellation")
        } catch is CancellationError {
            #expect(Bool(true))
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func pairingAttemptGenerationRejectsStaleAndCancelledAttempts() {
        var attempts = PairingAttemptGeneration()
        let first = attempts.begin()
        let second = attempts.begin()

        #expect(!attempts.isCurrent(first))
        #expect(attempts.isCurrent(second))
        attempts.cancel()
        #expect(!attempts.isCurrent(second))
    }

    @Test func relayWebSocketTransportIsWiredThroughEverySwiftPacketBoundary() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let factory = try String(contentsOf: root.appendingPathComponent(
            "Sources/HermesCaptureProtocol/RelayConnectionFactory.swift"
        ), encoding: .utf8)
        let channel = try String(contentsOf: root.appendingPathComponent(
            "Sources/HermesCaptureProtocol/PeerSessionChannel.swift"
        ), encoding: .utf8)
        let macServer = try String(contentsOf: root.appendingPathComponent(
            "Apps/HermesCaptureMac/Pairing/PairingServer.swift"
        ), encoding: .utf8)
        let iosCoordinator = Self.iOSSourcesPresent
            ? try String(contentsOf: root.appendingPathComponent(Self.iOSCoordinatorPath), encoding: .utf8)
            : "wireTransport: wireTransport"

        #expect(factory.contains("route.transport.makeConnection(route: route)"))
        #expect(factory.contains("contentContext: route.transport.makeSendContext()"))
        #expect(factory.contains("transport: route.transport"))
        #expect(channel.contains("wireTransport.makeSendContext()"))
        #expect(channel.contains("connection.receiveMessage"))
        #expect(macServer.contains("wireTransport: RelayWireTransport"))
        #expect(iosCoordinator.contains("wireTransport: wireTransport"))
    }

    @Test(.enabled(if: RelayProtocolTests.iOSSourcesPresent))
    func iOSPairingAttemptsAreGenerationBoundAndDirectWaitIsCancellationAware() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent(
            Self.iOSCoordinatorPath
        ), encoding: .utf8)

        #expect(source.contains("private var pairingGeneration"))
        #expect(source.contains("pairingGeneration.isCurrent(generation)"))
        #expect(source.contains("try Task.checkCancellation()"))
        #expect(source.contains("withTaskCancellationHandler"))
        #expect(source.contains("connection.cancel()"))
    }

    @Test func forceRelayPreferenceRequiresDebugEnvironmentFlagAndRelayRoute() {
        #expect(
            RelayConnectionPreference.shouldForceRelay(
                environment: ["ORIEL_FORCE_RELAY": "1"],
                hasRelayRoute: true
            )
        )
        #expect(
            !RelayConnectionPreference.shouldForceRelay(
                environment: ["ORIEL_FORCE_RELAY": "1"],
                hasRelayRoute: false
            )
        )
        #expect(
            !RelayConnectionPreference.shouldForceRelay(
                environment: [:],
                hasRelayRoute: true
            )
        )
    }

    @Test func directClosureRetriesSignedRelayAtMostOnce() {
        #expect(
            RelayConnectionPreference.shouldRetryViaRelay(
                usedRelay: false,
                hasRelayRoute: true
            )
        )
        #expect(
            !RelayConnectionPreference.shouldRetryViaRelay(
                usedRelay: true,
                hasRelayRoute: true
            )
        )
        #expect(
            !RelayConnectionPreference.shouldRetryViaRelay(
                usedRelay: false,
                hasRelayRoute: false
            )
        )
    }

    @Test func forcedRelaySuppressesDirectAdvertisementOnlyWhenRouteExists() {
        #expect(
            !RelayConnectionPreference.shouldAdvertiseDirect(
                environment: ["ORIEL_FORCE_RELAY": "1"],
                hasRelayRoute: true
            )
        )
        #expect(
            RelayConnectionPreference.shouldAdvertiseDirect(
                environment: ["ORIEL_FORCE_RELAY": "1"],
                hasRelayRoute: false
            )
        )
        #expect(
            RelayConnectionPreference.shouldAdvertiseDirect(
                environment: [:],
                hasRelayRoute: true
            )
        )
    }

    @Test func macPairingUsesForcedRelayPolicyToGateDirectAdvertisement() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent(
            "Apps/HermesCaptureMac/Pairing/PairingCoordinator.swift"
        ), encoding: .utf8)

        #expect(source.contains("RelayConnectionPreference.shouldAdvertiseDirect("))
        #expect(source.contains("if shouldAdvertiseDirect {"))
    }

}

private final class RelayReceiveScript: @unchecked Sendable {
    typealias Event = Result<(Data?, Bool), any Error>

    private let lock = NSLock()
    private var events: [Event]
    private var lastCompletion: RelayAcknowledgementReceiver.ReceiveCompletion?
    private(set) var receiveCount = 0

    init(_ events: [Event]) {
        self.events = events
    }

    func receive(
        _ maximumLength: Int,
        _ completion: @escaping RelayAcknowledgementReceiver.ReceiveCompletion
    ) {
        let event = lock.withLock { () -> Event? in
            receiveCount += 1
            lastCompletion = completion
            return events.isEmpty ? nil : events.removeFirst()
        }
        guard let event else { return }
        switch event {
        case let .success((data, complete)):
            #expect((data?.count ?? 0) <= maximumLength)
            completion(data, complete, nil)
        case let .failure(error):
            completion(nil, false, error)
        }
    }

    func completeAgainAfterSuccess() {
        let completion = lock.withLock { lastCompletion }
        completion?(nil, true, RelayError.invalidFrame)
    }
}

private extension Data {
    func base64URLEncodedForTest() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
