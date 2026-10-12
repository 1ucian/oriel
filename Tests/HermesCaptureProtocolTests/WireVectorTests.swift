import CryptoKit
import Foundation
import Testing
@testable import HermesCaptureProtocol

/// Byte-level vectors for the wire protocol, so a second implementation (Oriel for Windows) can prove it
/// speaks the same bytes as this one.
///
/// `ORIEL_WRITE_WIRE_VECTORS=1 swift test --filter WireVectorTests` rewrites `Tests/Fixtures/wire-v1.json`
/// from fixed keys, nonces and clocks. Every other run checks that the checked-in file still holds against
/// this code, and checks `Tests/Fixtures/wire-v1-windows.json` (written by the Windows tests) when present.
/// CryptoKit signs with randomness and seals with random nonces, so the file is the contract, not a rerun.
struct WireVectorTests {
    @Test func swiftVectorsMatchThisImplementation() throws {
        if ProcessInfo.processInfo.environment["ORIEL_WRITE_WIRE_VECTORS"] == "1" {
            let fixture = try WireVectorFixture.generate()
            try WireVectorFixture.write(fixture, to: WireVectorFixture.swiftURL)
        }
        let fixture = try WireVectorFixture.read(WireVectorFixture.swiftURL)
        try WireVectorFixture.verifySwiftFixture(fixture)
    }

    @Test func windowsVectorsVerifyHere() throws {
        guard FileManager.default.fileExists(atPath: WireVectorFixture.windowsURL.path) else { return }
        let fixture = try WireVectorFixture.read(WireVectorFixture.windowsURL)
        try WireVectorFixture.verifyWindowsFixture(fixture)
    }
}

enum WireVectorInputs {
    static let macSigningSeed = Data((1...32).map(UInt8.init))
    static let macAgreementSeed = Data((33...64).map(UInt8.init))
    static let phoneSigningSeed = Data((65...96).map(UInt8.init))
    static let phoneAgreementSeed = Data((97...128).map(UInt8.init))
    static let pairingNonce = Data((160...183).map(UInt8.init))
    static let challengeNonce = Data((192...215).map(UInt8.init))
    static let serviceName = "Example-PC"
    /// iOS writes a typographic apostrophe in device names, so the request carries non-ASCII bytes.
    static let deviceName = "Test\u{2019}s iPhone"
    static let offerExpiresAt = Date(timeIntervalSince1970: 1_791_680_400)
    /// Phones sign `Date.now`, which has sub-millisecond digits.
    static let requestCreatedAt = Date(timeIntervalSince1970: 1_791_676_800.123456)
    static let pairingVerifyAt = Date(timeIntervalSince1970: 1_791_676_805)
    static let challengeIssuedAt = Date(timeIntervalSince1970: 1_791_676_860)
    static let challengeExpiresAt = Date(timeIntervalSince1970: 1_791_676_890)
    static let reconnectCreatedAt = Date(timeIntervalSince1970: 1_791_676_861.5)
    static let reconnectVerifyAt = Date(timeIntervalSince1970: 1_791_676_862)
    static let approvalExpiresAt = Date(timeIntervalSince1970: 1_791_680_405)

    static var macSigningKey: Curve25519.Signing.PrivateKey {
        get throws { try .init(rawRepresentation: macSigningSeed) }
    }
    static var macAgreementKey: Curve25519.KeyAgreement.PrivateKey {
        get throws { try .init(rawRepresentation: macAgreementSeed) }
    }
    static var phoneSigningKey: Curve25519.Signing.PrivateKey {
        get throws { try .init(rawRepresentation: phoneSigningSeed) }
    }
    static var phoneAgreementKey: Curve25519.KeyAgreement.PrivateKey {
        get throws { try .init(rawRepresentation: phoneAgreementSeed) }
    }

    /// What the PC sends: the order matters, counters run 1, 2, 3...
    static func macPackets() throws -> [(name: String, packet: SessionPacket)] {
        [
            ("approval", .approval(SessionApproval(
                capabilities: SessionCapability.phaseOneDefaults,
                expiresAt: approvalExpiresAt
            ))),
            ("heartbeat", .heartbeat(monotonicNanoseconds: 123_456_789_012)),
            ("video-key", .video(VideoFramePacket(
                sequence: 1,
                presentationTimeNanoseconds: 1_000_000_000,
                isKeyFrame: true,
                payload: Data([0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x33]),
                parameterSets: H264ParameterSets(
                    sequenceParameterSet: Data([0x67, 0x4D, 0x40, 0x28, 0x95, 0xA0, 0x1E, 0x00, 0x89, 0xF9, 0x70]),
                    pictureParameterSet: Data([0x68, 0xEE, 0x3C, 0x80])
                )
            ))),
            ("video-delta", .video(VideoFramePacket(
                sequence: 2,
                presentationTimeNanoseconds: 1_033_333_333,
                isKeyFrame: false,
                payload: Data([0, 0, 0, 4, 0x41, 0x9A, 0x02, 0x04])
            ))),
            ("close", .close(reason: "stopped-on-mac")),
            ("close-escapes", .close(reason: "q\"b\\s/t\tn\nc\u{01}\u{1F}\u{7F}é✓")),
        ]
    }

    /// What a phone sends.
    static func phonePackets() throws -> [(name: String, packet: SessionPacket)] {
        [
            ("heartbeat", .heartbeat(monotonicNanoseconds: 987_654_321)),
            ("pointer", .input(.pointerMove(try NormalizedPoint(x: 0.25, y: 0.75)))),
            ("pointer-edge", .input(.pointerMove(try NormalizedPoint(x: 0.123456789, y: 1)))),
            ("click", .input(.mouseButton(.left, .click))),
            ("right-down", .input(.mouseButton(.right, .down))),
            ("center-double", .input(.mouseButton(.center, .doubleClick))),
            ("scroll", .input(try .scroll(deltaX: -12.5, deltaY: 3))),
            ("key-press", .input(.key(code: 48, phase: .press, modifiers: [.command]))),
            ("key-down", .input(.key(code: 0, phase: .down, modifiers: [.shift, .option, .control]))),
            ("key-up", .input(.key(code: 53, phase: .up, modifiers: []))),
            ("text", .input(try .text("Hello, PC ✓\n"))),
            ("close", .close(reason: "disconnected-on-ios")),
        ]
    }
}

enum WireVectorFixture {
    typealias Object = [String: Any]

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
    static var swiftURL: URL { fixturesDirectory.appendingPathComponent("wire-v1.json") }
    static var windowsURL: URL { fixturesDirectory.appendingPathComponent("wire-v1-windows.json") }

    /// The encoder every signed payload and every packet goes through.
    static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func associatedData(counter: UInt64) -> Data {
        var data = Data("HermesCapture/session-envelope".utf8)
        var version = PairingPayload.currentProtocolVersion.littleEndian
        var counter = counter.littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &counter) { data.append(contentsOf: $0) }
        return data
    }

    static func sessionRoot(nonce: Data) throws -> (secret: Data, root: Data) {
        let secret = try WireVectorInputs.macAgreementKey.sharedSecretFromKeyAgreement(
            with: WireVectorInputs.phoneAgreementKey.publicKey
        )
        let root = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: nonce,
            sharedInfo: Data("HermesCapture/v1/session".utf8),
            outputByteCount: 64
        )
        return (secret.withUnsafeBytes { Data($0) }, root.withUnsafeBytes { Data($0) })
    }

    static func cipher(_ role: SessionPeerRole, nonce: Data) throws -> SessionCipher {
        switch role {
        case .mac:
            return try SessionCipher(
                localPrivateKey: WireVectorInputs.macAgreementKey,
                remotePublicKey: WireVectorInputs.phoneAgreementKey.publicKey.rawRepresentation,
                pairingNonce: nonce,
                role: .mac
            )
        case .client:
            return try SessionCipher(
                localPrivateKey: WireVectorInputs.phoneAgreementKey,
                remotePublicKey: WireVectorInputs.macAgreementKey.publicKey.rawRepresentation,
                pairingNonce: nonce,
                role: .client
            )
        }
    }

    // MARK: Generate

    static func generate() throws -> Object {
        let macSigning = try WireVectorInputs.macSigningKey
        let macAgreement = try WireVectorInputs.macAgreementKey
        let phoneSigning = try WireVectorInputs.phoneSigningKey
        let phoneAgreement = try WireVectorInputs.phoneAgreementKey
        let encoder = canonicalEncoder

        // The pairing offer the PC shows as a QR code and a pasteable code.
        let offerPayload = PairingPayload(
            macPublicKey: macAgreement.publicKey.rawRepresentation,
            nonce: WireVectorInputs.pairingNonce,
            expiresAt: WireVectorInputs.offerExpiresAt,
            serviceName: WireVectorInputs.serviceName
        )
        let offer = try SignedPairingPayload.sign(offerPayload, with: macSigning)
        let offerCanonical = try encoder.encode(offerPayload)
        let qr = try offer.qrEncodedString()

        // The phone's pairing request, as it arrives on the socket.
        let requestPayload = PairingRequestPayload(
            pairingNonce: WireVectorInputs.pairingNonce,
            clientKeyAgreementPublicKey: phoneAgreement.publicKey.rawRepresentation,
            clientSigningPublicKey: phoneSigning.publicKey.rawRepresentation,
            deviceName: WireVectorInputs.deviceName,
            requestedCapabilities: SessionCapability.assistantDefaults,
            createdAt: WireVectorInputs.requestCreatedAt
        )
        let request = try SignedPairingRequest.sign(requestPayload, with: phoneSigning)
        let requestCanonical = try encoder.encode(requestPayload)
        let requestFramed = try PairingHandshakeCodec.encode(request)
        // The six digits both screens show while the PC waits for the owner.
        let confirmation = try PairingConfirmationCode(
            macAgreementKey: macAgreement,
            macSigningPublicKey: macSigning.publicKey.rawRepresentation,
            request: requestPayload
        )

        // Session keys for the pairing nonce, and every packet sealed in each direction.
        let pairingKeys = try sessionRoot(nonce: WireVectorInputs.pairingNonce)
        let macFrames = try sealFrames(WireVectorInputs.macPackets(), role: .mac, nonce: WireVectorInputs.pairingNonce)
        let phoneFrames = try sealFrames(WireVectorInputs.phonePackets(), role: .client, nonce: WireVectorInputs.pairingNonce)

        // Reconnect: the PC's signed challenge, the phone's signed answer, and the session keys they make.
        let challengePayload = ReconnectChallengePayload(
            macKeyAgreementPublicKey: macAgreement.publicKey.rawRepresentation,
            macSigningPublicKey: macSigning.publicKey.rawRepresentation,
            nonce: WireVectorInputs.challengeNonce,
            issuedAt: WireVectorInputs.challengeIssuedAt,
            expiresAt: WireVectorInputs.challengeExpiresAt,
            serviceName: WireVectorInputs.serviceName
        )
        let challenge = try SignedReconnectChallenge.sign(challengePayload, with: macSigning)
        let challengeCanonical = try encoder.encode(challengePayload)
        let challengeFramed = try ReconnectHandshakeCodec.encode(challenge)
        let reconnectPayload = ReconnectRequestPayload(
            challengeNonce: WireVectorInputs.challengeNonce,
            clientKeyAgreementPublicKey: phoneAgreement.publicKey.rawRepresentation,
            clientSigningPublicKey: phoneSigning.publicKey.rawRepresentation,
            deviceName: WireVectorInputs.deviceName,
            serviceName: WireVectorInputs.serviceName,
            requestedCapabilities: SessionCapability.phaseOneDefaults,
            createdAt: WireVectorInputs.reconnectCreatedAt
        )
        let reconnectRequest = try SignedReconnectRequest.sign(reconnectPayload, with: phoneSigning)
        let reconnectCanonical = try encoder.encode(reconnectPayload)
        let reconnectFramed = try ReconnectHandshakeCodec.encode(reconnectRequest)
        let reconnectKeys = try sessionRoot(nonce: WireVectorInputs.challengeNonce)
        let reconnectMacFrames = try sealFrames(
            [("approval", .approval(SessionApproval(
                capabilities: SessionCapability.phaseOneDefaults,
                expiresAt: WireVectorInputs.approvalExpiresAt
            )))],
            role: .mac,
            nonce: WireVectorInputs.challengeNonce
        )

        return [
            "about": "Oriel wire protocol v1 vectors, written by WireVectorTests.swift from fixed keys and clocks.",
            "keys": [
                "macSigningSeed": b64(WireVectorInputs.macSigningSeed),
                "macSigningPublic": b64(macSigning.publicKey.rawRepresentation),
                "macAgreementPrivate": b64(WireVectorInputs.macAgreementSeed),
                "macAgreementPublic": b64(macAgreement.publicKey.rawRepresentation),
                "phoneSigningSeed": b64(WireVectorInputs.phoneSigningSeed),
                "phoneSigningPublic": b64(phoneSigning.publicKey.rawRepresentation),
                "phoneAgreementPrivate": b64(WireVectorInputs.phoneAgreementSeed),
                "phoneAgreementPublic": b64(phoneAgreement.publicKey.rawRepresentation),
            ] as Object,
            "pairing": [
                "serviceName": WireVectorInputs.serviceName,
                "deviceName": WireVectorInputs.deviceName,
                "nonce": b64(WireVectorInputs.pairingNonce),
                "offerExpiresAtSeconds": Int64(WireVectorInputs.offerExpiresAt.timeIntervalSince1970),
                "verifyAtSeconds": Int64(WireVectorInputs.pairingVerifyAt.timeIntervalSince1970),
                "offerCanonical": b64(offerCanonical),
                "offerCanonicalText": String(decoding: offerCanonical, as: UTF8.self),
                "offerSignature": b64(offer.signature),
                "qr": qr,
                "requestCanonical": b64(requestCanonical),
                "requestCanonicalText": String(decoding: requestCanonical, as: UTF8.self),
                "requestSignature": b64(request.signature),
                "requestFramed": b64(requestFramed),
                "confirmationCode": confirmation.digits,
            ] as Object,
            "session": [
                "info": "HermesCapture/v1/session",
                "sharedSecret": b64(pairingKeys.secret),
                "root": b64(pairingKeys.root),
                "reconnectRoot": b64(reconnectKeys.root),
                "aadCounter1": b64(associatedData(counter: 1)),
            ] as Object,
            "macFrames": macFrames,
            "phoneFrames": phoneFrames,
            "reconnect": [
                "nonce": b64(WireVectorInputs.challengeNonce),
                "issuedAtSeconds": Int64(WireVectorInputs.challengeIssuedAt.timeIntervalSince1970),
                "expiresAtSeconds": Int64(WireVectorInputs.challengeExpiresAt.timeIntervalSince1970),
                "verifyAtSeconds": Int64(WireVectorInputs.reconnectVerifyAt.timeIntervalSince1970),
                "challengeCanonical": b64(challengeCanonical),
                "challengeCanonicalText": String(decoding: challengeCanonical, as: UTF8.self),
                "challengeSignature": b64(challenge.signature),
                "challengeFramed": b64(challengeFramed),
                "requestCanonical": b64(reconnectCanonical),
                "requestCanonicalText": String(decoding: reconnectCanonical, as: UTF8.self),
                "requestSignature": b64(reconnectRequest.signature),
                "requestFramed": b64(reconnectFramed),
                "macFrames": reconnectMacFrames,
            ] as Object,
        ]
    }

    static func sealFrames(
        _ packets: [(name: String, packet: SessionPacket)],
        role: SessionPeerRole,
        nonce: Data
    ) throws -> [Object] {
        let cipher = try cipher(role, nonce: nonce)
        return try packets.map { name, packet in
            let envelope = try cipher.seal(packet)
            let frame = try SessionWireCodec.encode(envelope)
            // The exact plaintext that was sealed: decrypt it here rather than encode again, since a Set
            // (approval capabilities, key modifiers) has no fixed order.
            let plaintext = try openRaw(envelope, role: role, nonce: nonce)
            return [
                "name": name,
                "counter": Int64(envelope.counter),
                "plaintext": b64(plaintext),
                "plaintextText": String(decoding: plaintext, as: UTF8.self),
                "frame": b64(frame),
            ]
        }
    }

    /// Opens a sealed envelope with the sender's own key (the test knows both), returning the raw JSON.
    static func openRaw(_ envelope: EncryptedSessionEnvelope, role: SessionPeerRole, nonce: Data) throws -> Data {
        let root = try sessionRoot(nonce: nonce).root
        let key = SymmetricKey(data: role == .mac ? root.prefix(32) : root.suffix(32))
        return try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: envelope.sealedData),
            using: key,
            authenticating: associatedData(counter: envelope.counter)
        )
    }

    // MARK: Verify

    static func verifySwiftFixture(_ fixture: Object) throws {
        let keys = try object(fixture, "keys")
        let macSigning = try WireVectorInputs.macSigningKey
        #expect(try data(keys, "macSigningPublic") == macSigning.publicKey.rawRepresentation)
        #expect(try data(keys, "macAgreementPublic") == WireVectorInputs.macAgreementKey.publicKey.rawRepresentation)
        #expect(try data(keys, "phoneSigningPublic") == WireVectorInputs.phoneSigningKey.publicKey.rawRepresentation)
        #expect(try data(keys, "phoneAgreementPublic") == WireVectorInputs.phoneAgreementKey.publicKey.rawRepresentation)

        let pairing = try object(fixture, "pairing")
        let encoder = canonicalEncoder
        // The QR decodes, verifies with its embedded key, and its canonical bytes are what was signed.
        let offer = try SignedPairingPayload(qrEncodedString: try string(pairing, "qr"))
        try offer.verifyEmbedded(at: WireVectorInputs.pairingVerifyAt)
        let offerCanonical = try data(pairing, "offerCanonical")
        #expect(try encoder.encode(offer.payload) == offerCanonical)
        #expect(macSigning.publicKey.isValidSignature(try data(pairing, "offerSignature"), for: offerCanonical))
        #expect(offer.payload.serviceName == WireVectorInputs.serviceName)
        #expect(offer.payload.expiresAt == WireVectorInputs.offerExpiresAt)

        // The framed request decodes, verifies, and carries the signed canonical bytes inside it.
        let request = try PairingHandshakeCodec.decode(try data(pairing, "requestFramed"))
        try request.verify(expectedNonce: WireVectorInputs.pairingNonce, at: WireVectorInputs.pairingVerifyAt)
        let requestCanonical = try data(pairing, "requestCanonical")
        #expect(try WireVectorInputs.phoneSigningKey.publicKey.isValidSignature(request.signature, for: requestCanonical))
        #expect(try data(pairing, "requestFramed").range(of: requestCanonical) != nil)
        #expect(request.payload.deviceName == WireVectorInputs.deviceName)
        let pcCode = try PairingConfirmationCode(
            macAgreementKey: WireVectorInputs.macAgreementKey,
            macSigningPublicKey: macSigning.publicKey.rawRepresentation,
            request: request.payload
        )
        let phoneCode = try PairingConfirmationCode(
            phoneAgreementKey: WireVectorInputs.phoneAgreementKey,
            phoneSigningPublicKey: WireVectorInputs.phoneSigningKey.publicKey.rawRepresentation,
            offer: offer
        )
        #expect(pcCode == phoneCode)
        #expect(try string(pairing, "confirmationCode") == pcCode.digits)

        let session = try object(fixture, "session")
        #expect(try data(session, "root") == sessionRoot(nonce: WireVectorInputs.pairingNonce).root)
        #expect(try data(session, "reconnectRoot") == sessionRoot(nonce: WireVectorInputs.challengeNonce).root)
        #expect(try data(session, "aadCounter1") == associatedData(counter: 1))

        try openFrames(try objects(fixture, "macFrames"), with: cipher(.client, nonce: WireVectorInputs.pairingNonce),
                       expected: WireVectorInputs.macPackets())
        try openFrames(try objects(fixture, "phoneFrames"), with: cipher(.mac, nonce: WireVectorInputs.pairingNonce),
                       expected: WireVectorInputs.phonePackets())

        let reconnect = try object(fixture, "reconnect")
        let challenge = try ReconnectHandshakeCodec.decodeChallenge(try data(reconnect, "challengeFramed"))
        try challenge.verify(
            expectedSigningPublicKey: macSigning.publicKey.rawRepresentation,
            expectedServiceName: WireVectorInputs.serviceName,
            at: WireVectorInputs.reconnectVerifyAt
        )
        #expect(try encoder.encode(challenge.payload) == data(reconnect, "challengeCanonical"))
        let reconnectRequest = try ReconnectHandshakeCodec.decodeRequest(try data(reconnect, "requestFramed"))
        try reconnectRequest.verify(
            challenge: challenge.payload,
            expectedClientSigningPublicKey: WireVectorInputs.phoneSigningKey.publicKey.rawRepresentation,
            at: WireVectorInputs.reconnectVerifyAt
        )
        #expect(try WireVectorInputs.phoneSigningKey.publicKey.isValidSignature(
            reconnectRequest.signature, for: data(reconnect, "requestCanonical")
        ))
        try openFrames(try objects(reconnect, "macFrames"), with: cipher(.client, nonce: WireVectorInputs.challengeNonce),
                       expected: [("approval", .approval(SessionApproval(
                           capabilities: SessionCapability.phaseOneDefaults,
                           expiresAt: WireVectorInputs.approvalExpiresAt
                       )))])
    }

    /// What the Windows implementation produced from the same inputs: its QR, its signed reconnect challenge,
    /// and every packet it sends, which this side must accept exactly as a phone would.
    static func verifyWindowsFixture(_ fixture: Object) throws {
        let macSigning = try WireVectorInputs.macSigningKey
        let offer = try SignedPairingPayload(qrEncodedString: try string(fixture, "qr"))
        try offer.verifyEmbedded(at: WireVectorInputs.pairingVerifyAt)
        #expect(offer.signingPublicKey == macSigning.publicKey.rawRepresentation)
        #expect(offer.payload == PairingPayload(
            macPublicKey: try WireVectorInputs.macAgreementKey.publicKey.rawRepresentation,
            nonce: WireVectorInputs.pairingNonce,
            expiresAt: WireVectorInputs.offerExpiresAt,
            serviceName: WireVectorInputs.serviceName
        ))

        let challenge = try ReconnectHandshakeCodec.decodeChallenge(try data(fixture, "challengeFramed"))
        try challenge.verify(
            expectedSigningPublicKey: macSigning.publicKey.rawRepresentation,
            expectedServiceName: WireVectorInputs.serviceName,
            at: WireVectorInputs.reconnectVerifyAt
        )
        #expect(challenge.payload.nonce == WireVectorInputs.challengeNonce)
        #expect(challenge.payload.issuedAt == WireVectorInputs.challengeIssuedAt)
        #expect(challenge.payload.expiresAt == WireVectorInputs.challengeExpiresAt)

        try openFrames(try objects(fixture, "macFrames"), with: cipher(.client, nonce: WireVectorInputs.pairingNonce),
                       expected: WireVectorInputs.macPackets())
    }

    static func openFrames(
        _ frames: [Object],
        with cipher: SessionCipher,
        expected: [(name: String, packet: SessionPacket)]
    ) throws {
        #expect(frames.count == expected.count)
        var decoder = SessionWireDecoder()
        for (frame, expectation) in zip(frames, expected) {
            #expect(try string(frame, "name") == expectation.name)
            let envelopes = try decoder.append(try data(frame, "frame"))
            #expect(envelopes.count == 1)
            guard let envelope = envelopes.first else { continue }
            #expect(Int64(envelope.counter) == (frame["counter"] as? NSNumber)?.int64Value)
            let packet = try cipher.open(envelope)
            #expect(packet == expectation.packet, "\(expectation.name)")
            if let plaintext = frame["plaintext"] as? String {
                #expect(try SessionPacketCodec.decode(Data(base64Encoded: plaintext) ?? Data()) == expectation.packet)
            }
        }
    }

    // MARK: File

    static func write(_ fixture: Object, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(
            withJSONObject: fixture,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> Object {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Object else {
            throw FixtureError.malformed(url.lastPathComponent)
        }
        return object
    }

    enum FixtureError: Error {
        case malformed(String)
        case missing(String)
    }

    static func b64(_ data: Data) -> String { data.base64EncodedString() }

    static func object(_ object: Object, _ key: String) throws -> Object {
        guard let value = object[key] as? Object else { throw FixtureError.missing(key) }
        return value
    }

    static func objects(_ object: Object, _ key: String) throws -> [Object] {
        guard let value = object[key] as? [Object] else { throw FixtureError.missing(key) }
        return value
    }

    static func string(_ object: Object, _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw FixtureError.missing(key) }
        return value
    }

    static func data(_ object: Object, _ key: String) throws -> Data {
        guard let value = Data(base64Encoded: try string(object, key)) else { throw FixtureError.malformed(key) }
        return value
    }
}
