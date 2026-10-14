@preconcurrency import Network
import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

/// Voice input on the wire: what each side sends, the limits, and that peers from before it see nothing they would
/// end a session over.
struct SpeechProtocolTests {
    static let utterance = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    static func sampleRequests() throws -> [SpeechRequest] {
        [
            .subscribe,
            .prepare,
            .begin(utteranceID: utterance),
            .audio(try SpeechAudioChunk(utteranceID: utterance, sequence: 0, samples: Data([0x10, 0x00, 0xF0, 0xFF]))),
            .end(utteranceID: utterance),
            .cancel(utteranceID: utterance),
        ]
    }

    static func sampleEvents() throws -> [SpeechEvent] {
        [
            .status(try SpeechModelStatus(state: .downloading, progress: 0.42, modelName: "Whisper large-v3", downloadBytes: 3_083_520_416)),
            .status(try SpeechModelStatus(state: .ready, modelName: "Whisper large-v3")),
            .transcript(try SpeechTranscript(utteranceID: utterance, text: "Open Safari ✓", audioSeconds: 4.5, elapsedSeconds: 0.75)),
            .failure(try SpeechFailure(utteranceID: utterance, reason: .tooLong, message: "Keep it under a minute.")),
        ]
    }

    @Test func everyRequestAndEventRoundTripsThroughTheSessionCodec() throws {
        for request in try Self.sampleRequests() {
            let data = try SessionPacketCodec.encode(.speechRequest(request))
            #expect(try SessionPacketCodec.decode(data) == .speechRequest(request))
            #expect(String(decoding: data, as: UTF8.self).contains("\"version\":1"))
        }
        for event in try Self.sampleEvents() {
            let data = try SessionPacketCodec.encode(.speechEvent(event))
            #expect(try SessionPacketCodec.decode(data) == .speechEvent(event))
        }
    }

    @Test func aNewerVersionOrKindReadsAsUnsupportedInsteadOfEndingTheSession() throws {
        let newerRequest = Data(#"{"kind":"speechRequest","speechRequest":{"kind":"stream","version":2,"codec":"opus"}}"#.utf8)
        #expect(try SessionPacketCodec.decode(newerRequest) == .speechRequest(.unsupported(version: 2, kind: "stream")))
        let unknownKind = Data(#"{"kind":"speechRequest","speechRequest":{"kind":"pause","version":1}}"#.utf8)
        #expect(try SessionPacketCodec.decode(unknownKind) == .speechRequest(.unsupported(version: 1, kind: "pause")))
        let newerEvent = Data(#"{"kind":"speechEvent","speechEvent":{"kind":"partial","version":2,"text":"Open"}}"#.utf8)
        #expect(try SessionPacketCodec.decode(newerEvent) == .speechEvent(.unsupported(version: 2, kind: "partial")))
        // What a peer sent is never sent back.
        #expect(throws: (any Error).self) { try SessionPacketCodec.encode(.speechRequest(.unsupported(version: 2, kind: "stream"))) }
    }

    @Test func aPayloadWithoutAVersionIsInvalid() {
        let missing = Data(#"{"kind":"speechRequest","speechRequest":{"kind":"subscribe"}}"#.utf8)
        #expect(throws: PeerSessionError.invalidPacket) { try SessionPacketCodec.decode(missing) }
    }

    @Test func stateAndReasonFromANewerMacReadAsOnesThisPhoneCanShow() throws {
        let status = Data(#"{"kind":"speechEvent","speechEvent":{"kind":"status","status":{"modelName":"Whisper large-v4","state":"warmingUp"},"version":1}}"#.utf8)
        guard case let .speechEvent(.status(decoded)) = try SessionPacketCodec.decode(status) else {
            Issue.record("not a status")
            return
        }
        #expect(decoded.state == .unavailable)
        let failure = Data(#"{"kind":"speechEvent","speechEvent":{"failure":{"message":"No.","reason":"quota"},"kind":"failure","version":1}}"#.utf8)
        guard case let .speechEvent(.failure(reason)) = try SessionPacketCodec.decode(failure) else {
            Issue.record("not a failure")
            return
        }
        #expect(reason.reason == .transcriptionFailed)
    }

    @Test func audioIsBoundedPerChunkAndPerUtterance() throws {
        let id = Self.utterance
        #expect(throws: SpeechProtocolError.invalidChunk) { try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data()) }
        #expect(throws: SpeechProtocolError.invalidChunk) { try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data([1, 2, 3])) }
        #expect(throws: SpeechProtocolError.invalidChunk) {
            try SpeechAudioChunk(utteranceID: id, sequence: 0, samples: Data(count: SpeechProtocol.maximumChunkBytes + 2))
        }
        #expect(throws: SpeechProtocolError.invalidChunk) {
            try SpeechAudioChunk(utteranceID: id, sequence: SpeechProtocol.maximumChunks, samples: Data([0, 0]))
        }
        #expect(throws: SpeechProtocolError.invalidIdentifier) { try SpeechAudioChunk(utteranceID: "a b", sequence: 0, samples: Data([0, 0])) }
        let full = try SpeechAudioChunk(utteranceID: id, sequence: 1, samples: Data(count: SpeechProtocol.maximumChunkBytes))
        #expect(full.seconds == 2.048)
        #expect(SpeechProtocol.maximumUtteranceBytes == 1_920_000)
        // A chunk too large for the protocol is a protocol violation even if it fits in a packet.
        let oversize = Data(count: SpeechProtocol.maximumChunkBytes + 2).base64EncodedString()
        let packet = Data(#"{"kind":"speechRequest","speechRequest":{"audio":{"samples":"\#(oversize)","sequence":0,"utteranceID":"\#(id)"},"kind":"audio","version":1}}"#.utf8)
        #expect(throws: PeerSessionError.invalidPacket) { try SessionPacketCodec.decode(packet) }
        // Sixty seconds of chunks fit the session's packet limit one by one, base64 and all.
        let chunk = try SessionPacketCodec.encode(.speechRequest(.audio(full)))
        #expect(chunk.count < 100_000)
    }

    @Test func transcriptsAndMessagesAreBounded() throws {
        #expect(throws: SpeechProtocolError.invalidText) {
            try SpeechTranscript(utteranceID: Self.utterance, text: String(repeating: "a", count: SpeechProtocol.maximumTextBytes + 1),
                                 audioSeconds: 1, elapsedSeconds: 1)
        }
        #expect(throws: SpeechProtocolError.invalidText) {
            try SpeechFailure(utteranceID: nil, reason: .transcriptionFailed, message: String(repeating: "b", count: 300))
        }
        #expect(throws: SpeechProtocolError.invalidProgress) {
            try SpeechModelStatus(state: .downloading, progress: 1.5, modelName: "Whisper large-v3")
        }
    }

    // MARK: Peers from before voice input

    @Test func olderPhonesReadAnApprovalWithAnOfferAndIgnoreIt() throws {
        let approval = SessionApproval(
            capabilities: SessionCapability.assistantDefaults,
            expiresAt: Date(timeIntervalSince1970: 1_791_680_405),
            speech: .current
        )
        let data = try SessionPacketCodec.encode(.approval(approval))
        #expect(String(decoding: data, as: UTF8.self).contains(#""speech":{"maximumSeconds":60,"sampleRate":16000,"version":1}"#))
        // Oriel for iPhone 1.0 decodes the approval with the synthesized Codable of its struct, which skips keys it
        // does not know.
        let legacy = try LegacyPeer.decodeApproval(data)
        #expect(legacy.capabilities == SessionCapability.assistantDefaults)
        #expect(legacy.expiresAt == approval.expiresAt)
        #expect(try SessionPacketCodec.decode(data) == .approval(approval))
    }

    @Test func anApprovalWithoutAnOfferIsByteForByteWhatOlderMacsSend() throws {
        let approval = SessionApproval(capabilities: [.viewScreen], expiresAt: Date(timeIntervalSince1970: 1_791_680_405))
        let text = String(decoding: try SessionPacketCodec.encode(.approval(approval)), as: UTF8.self)
        #expect(text == #"{"approval":{"capabilities":["viewScreen"],"expiresAt":1791680405000},"kind":"approval"}"#)
        guard case let .approval(decoded) = try SessionPacketCodec.decode(Data(text.utf8)) else {
            Issue.record("not an approval")
            return
        }
        #expect(decoded.speech == nil)
    }

    @Test func anOfferThisPhoneCannotReadLeavesVoiceOffButKeepsTheSession() throws {
        let text = #"{"approval":{"capabilities":["viewScreen"],"expiresAt":1791680405000,"speech":{"version":"two"}},"kind":"approval"}"#
        guard case let .approval(decoded) = try SessionPacketCodec.decode(Data(text.utf8)) else {
            Issue.record("not an approval")
            return
        }
        #expect(decoded.speech == nil)
        #expect(decoded.capabilities == [.viewScreen])
        // An offer in another audio format is read, but this phone does not use it.
        let other = try SpeechTranscriptionOffer(version: 3, sampleRate: 24_000, maximumSeconds: 120)
        #expect(other.negotiatedVersion == nil)
        #expect(try SpeechTranscriptionOffer(version: 3).negotiatedVersion == 1)
        #expect(try SpeechTranscriptionOffer(maximumSeconds: 120).negotiatedMaximumSeconds == 60)
    }

    @Test func olderMacsAndThePCWouldEndTheSessionOnASpeechPacket() throws {
        // Why the phone sends nothing without an offer: Oriel for Mac 1.0 and 1.0.1, and the Windows companion
        // (SessionPackets.cs), read an unknown kind as an invalid packet and close the session.
        for request in try Self.sampleRequests() {
            #expect(throws: LegacyPeer.Error.unknownKind) { try LegacyPeer.decodeKind(SessionPacketCodec.encode(.speechRequest(request))) }
        }
        for event in try Self.sampleEvents() {
            #expect(throws: LegacyPeer.Error.unknownKind) { try LegacyPeer.decodeKind(SessionPacketCodec.encode(.speechEvent(event))) }
        }
        #expect(try LegacyPeer.decodeKind(SessionPacketCodec.encode(.heartbeat(monotonicNanoseconds: 1))) == "heartbeat")
    }

    // MARK: The channel keeps speech packets from peers that did not ask for them

    @Test func thePhoneSendsSpeechOnlyToAMacThatOfferedIt() async throws {
        let pair = try await LoopbackPair.make()
        defer { pair.close() }
        try pair.server.approve(capabilities: SessionCapability.assistantDefaults)
        try await waitUntil { pair.client.currentState == .active }
        #expect(pair.client.speechOffer == nil)
        #expect(throws: PeerSessionError.capabilityDenied) { try pair.client.send(.speechRequest(.subscribe)) }
        #expect(throws: PeerSessionError.capabilityDenied) {
            try pair.server.send(.speechEvent(.status(try SpeechModelStatus(state: .ready, modelName: "Whisper large-v3"))))
        }
    }

    @Test func theMacAnswersOnlyAPhoneThatHasAsked() async throws {
        let pair = try await LoopbackPair.make()
        defer { pair.close() }
        let atMac = PacketLog()
        let atPhone = PacketLog()
        pair.server.onPacket = { atMac.append($0) }
        pair.client.onPacket = { atPhone.append($0) }
        try pair.server.approve(capabilities: SessionCapability.assistantDefaults, speech: .current)
        try await waitUntil { pair.client.currentState == .active && pair.client.speechOffer != nil }
        #expect(pair.client.speechOffer == .current)

        let status = SpeechEvent.status(try SpeechModelStatus(state: .installed, modelName: "Whisper large-v3"))
        // Offered, but the phone has not shown it speaks the packets yet: it might be an older phone.
        #expect(throws: PeerSessionError.capabilityDenied) { try pair.server.send(.speechEvent(status)) }

        try pair.client.send(.speechRequest(.subscribe))
        try await waitUntil { atMac.packets.contains(.speechRequest(.subscribe)) }
        try pair.server.send(.speechEvent(status))
        try await waitUntil { atPhone.packets.contains(.speechEvent(status)) }
        #expect(pair.server.currentState == .active && pair.client.currentState == .active)
    }

    @Test func aMacEndsASessionThatSendsSpeechItDidNotOffer() async throws {
        let pair = try await LoopbackPair.make(rawClient: true)
        defer { pair.close() }
        let errors = ErrorLog()
        pair.server.onError = { errors.append($0) }
        try pair.server.approve(capabilities: SessionCapability.phaseOneDefaults)
        try pair.sendRaw(.speechRequest(.subscribe))
        try await waitUntil { pair.server.currentState == .closed }
        #expect(errors.errors.contains { if case .protocolViolation(.capabilityDenied) = $0 { true } else { false } })
    }
}

// MARK: Helpers

/// How Oriel for Mac 1.0 and 1.0.1 and Oriel for iPhone 1.0 read packets (SessionPacket.swift at b4cdd6c): the kinds
/// they know, and the approval as their synthesized Codable reads it.
enum LegacyPeer {
    enum Error: Swift.Error { case unknownKind }

    static let knownKinds: Set<String> = [
        "heartbeat", "video", "input", "approval", "close", "agentInstruction", "agentControl", "agentTrace", "agentStatus",
    ]

    struct Approval: Decodable {
        let capabilities: Set<SessionCapability>
        let expiresAt: Date
        let reconnectRoute: ReconnectRoute?
    }

    private struct Envelope: Decodable {
        let kind: String
        let approval: Approval?
    }

    static func decodeKind(_ data: Data) throws -> String {
        let kind = try JSONDecoder().decode(KindOnly.self, from: data).kind
        guard knownKinds.contains(kind) else { throw Error.unknownKind }
        return kind
    }

    static func decodeApproval(_ data: Data) throws -> Approval {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.kind == "approval", let approval = envelope.approval else { throw Error.unknownKind }
        return approval
    }

    private struct KindOnly: Decodable { let kind: String }
}

/// A Mac channel and a phone channel over loopback TCP, or a Mac channel and a bare connection that writes sealed
/// frames itself (a misbehaving phone).
private final class LoopbackPair: @unchecked Sendable {
    let server: PeerSessionChannel
    let client: PeerSessionChannel
    private let rawConnection: NWConnection?
    private let rawCipher: SessionCipher?
    private let listener: NWListener

    private init(server: PeerSessionChannel, client: PeerSessionChannel, rawConnection: NWConnection?,
                 rawCipher: SessionCipher?, listener: NWListener) {
        self.server = server
        self.client = client
        self.rawConnection = rawConnection
        self.rawCipher = rawCipher
        self.listener = listener
    }

    static func make(rawClient: Bool = false) async throws -> LoopbackPair {
        let queue = DispatchQueue(label: "oriel.speech-loopback-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = Box<NWConnection>()
        let ready = Box<NWEndpoint.Port>()
        listener.newConnectionHandler = { accepted.set($0) }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port { ready.set(port) }
        }
        listener.start(queue: queue)
        let port = try await wait(for: ready)

        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data(repeating: 41, count: 24)
        let phoneCipher = try SessionCipher(localPrivateKey: phoneKey, remotePublicKey: macKey.publicKey.rawRepresentation,
                                            pairingNonce: nonce, role: .client)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let client = PeerSessionChannel(connection: connection, cipher: phoneCipher, queue: queue)
        if rawClient {
            connection.start(queue: queue)
        } else {
            client.start()
        }
        let serverConnection = try await wait(for: accepted)
        let server = PeerSessionChannel(
            connection: serverConnection,
            cipher: try SessionCipher(localPrivateKey: macKey, remotePublicKey: phoneKey.publicKey.rawRepresentation,
                                      pairingNonce: nonce, role: .mac),
            queue: queue
        )
        server.start()
        try await waitUntil { server.currentState == .authenticating && (rawClient || client.currentState == .authenticating) }
        try server.markPeerAuthenticated()
        if !rawClient { try client.markPeerAuthenticated() }
        return LoopbackPair(
            server: server,
            client: client,
            rawConnection: rawClient ? connection : nil,
            rawCipher: rawClient
                ? try SessionCipher(localPrivateKey: phoneKey, remotePublicKey: macKey.publicKey.rawRepresentation,
                                    pairingNonce: nonce, role: .client)
                : nil,
            listener: listener
        )
    }

    /// Seals and writes a packet the way a phone would, past the phone channel's own checks.
    func sendRaw(_ packet: SessionPacket) throws {
        guard let rawConnection, let rawCipher else { return }
        let frame = try SessionWireCodec.encode(rawCipher.seal(packet))
        rawConnection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        client.close(reason: "test-complete")
        server.close(reason: "test-complete")
        rawConnection?.cancel()
        listener.cancel()
    }

    private static func wait<T>(for box: Box<T>) async throws -> T {
        for _ in 0..<300 {
            if let value = box.value { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PeerSessionChannelError.connectionFailed("loopback-timed-out")
    }
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PeerSessionChannelError.connectionFailed("condition-timed-out")
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { if stored == nil { stored = value } } }
}

private final class PacketLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SessionPacket] = []
    var packets: [SessionPacket] { lock.withLock { stored } }
    func append(_ packet: SessionPacket) { lock.withLock { stored.append(packet) } }
}

private final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PeerSessionChannelError] = []
    var errors: [PeerSessionChannelError] { lock.withLock { stored } }
    func append(_ error: PeerSessionChannelError) { lock.withLock { stored.append(error) } }
}
