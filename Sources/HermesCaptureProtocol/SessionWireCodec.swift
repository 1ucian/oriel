import Foundation

public enum SessionWireCodec {
    public static let maximumFrameBytes = SessionPacket.maximumEncodedBytes + 64

    public static func encode(
        _ envelope: EncryptedSessionEnvelope
    ) throws -> Data {
        let bodyLength = MemoryLayout<UInt64>.size + envelope.sealedData.count
        guard bodyLength <= maximumFrameBytes else {
            throw PeerSessionError.payloadTooLarge
        }
        var length = UInt32(bodyLength).bigEndian
        var counter = envelope.counter.littleEndian
        var data = Data(capacity: MemoryLayout<UInt32>.size + bodyLength)
        Swift.withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &counter) { data.append(contentsOf: $0) }
        data.append(envelope.sealedData)
        return data
    }
}

public struct SessionWireDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append<D: DataProtocol>(
        _ bytes: D
    ) throws -> [EncryptedSessionEnvelope] {
        buffer.append(contentsOf: bytes)
        guard buffer.count <= SessionWireCodec.maximumFrameBytes * 2 else {
            buffer.removeAll(keepingCapacity: false)
            throw PeerSessionError.payloadTooLarge
        }

        var envelopes: [EncryptedSessionEnvelope] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = readLengthPrefix()
            guard length <= SessionWireCodec.maximumFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw PeerSessionError.payloadTooLarge
            }
            let totalLength = MemoryLayout<UInt32>.size + length
            guard buffer.count >= totalLength else { break }
            guard length >= MemoryLayout<UInt64>.size else {
                buffer.removeAll(keepingCapacity: false)
                throw PeerSessionError.invalidPacket
            }

            let bodyStart = MemoryLayout<UInt32>.size
            var counter: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &counter) { destination in
                buffer.copyBytes(
                    to: destination,
                    from: bodyStart..<(bodyStart + MemoryLayout<UInt64>.size)
                )
            }
            counter = UInt64(littleEndian: counter)
            let sealedStart = bodyStart + MemoryLayout<UInt64>.size
            let sealedData = Data(buffer[sealedStart..<totalLength])
            envelopes.append(
                EncryptedSessionEnvelope(
                    counter: counter,
                    sealedData: sealedData
                )
            )
            buffer = Data(buffer.dropFirst(totalLength))
        }
        return envelopes
    }

    private func readLengthPrefix() -> Int {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            buffer.copyBytes(
                to: destination,
                from: 0..<MemoryLayout<UInt32>.size
            )
        }
        return Int(UInt32(bigEndian: value))
    }
}
