import Foundation
import Testing
@testable import HermesCaptureProtocol

struct SessionWireCodecTests {
    @Test func fragmentedFramesDecodeOnlyWhenComplete() throws {
        let envelope = EncryptedSessionEnvelope(
            counter: 7,
            sealedData: Data([1, 2, 3, 4])
        )
        let encoded = try SessionWireCodec.encode(envelope)
        var decoder = SessionWireDecoder()

        #expect(try decoder.append(encoded.prefix(5)).isEmpty)
        #expect(try decoder.append(encoded.dropFirst(5)) == [envelope])
    }

    @Test func multipleFramesDecodeTogether() throws {
        let first = EncryptedSessionEnvelope(counter: 1, sealedData: Data([1]))
        let second = EncryptedSessionEnvelope(counter: 2, sealedData: Data([2, 3]))
        let payload = try SessionWireCodec.encode(first)
            + SessionWireCodec.encode(second)
        var decoder = SessionWireDecoder()
        #expect(try decoder.append(payload) == [first, second])
    }

    @Test func oversizedLengthPrefixFailsClosed() {
        var size = UInt32(SessionWireCodec.maximumFrameBytes + 1).bigEndian
        let prefix = withUnsafeBytes(of: &size) { Data($0) }
        var decoder = SessionWireDecoder()
        #expect(throws: PeerSessionError.payloadTooLarge) {
            try decoder.append(prefix)
        }
    }
}
