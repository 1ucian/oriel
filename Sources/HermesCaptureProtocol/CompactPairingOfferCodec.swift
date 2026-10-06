import Foundation

enum CompactPairingOfferCodec {
    private static let magic = Data([0x4f, 0x52, 0x4c, 0x01])
    private static let maximumEncodedBytes = 2_048

    static func isCompact(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func encode(_ signed: SignedPairingPayload) throws -> Data {
        var writer = CompactPairingOfferWriter()
        writer.append(magic)
        writer.append(signed.payload.protocolVersion)
        writer.append(signed.payload.expiresAt.timeIntervalSince1970.bitPattern)
        try writer.appendLengthPrefixed(signed.payload.macPublicKey)
        try writer.appendLengthPrefixed(signed.payload.nonce)
        try writer.appendLengthPrefixed(Data(signed.payload.serviceName.utf8))

        if let route = signed.payload.relayRoute {
            writer.append(UInt8(1))
            try writer.appendLengthPrefixed(Data(route.host.utf8))
            writer.append(route.port)
            try writer.appendLengthPrefixed(route.roomID)
            try writer.appendLengthPrefixed(route.accessKey)
            writer.append(route.expiresAt.timeIntervalSince1970.bitPattern)
            writer.append(route.transport == .secureWebSocket ? UInt8(1) : UInt8(0))
        } else {
            writer.append(UInt8(0))
        }

        try writer.appendLengthPrefixed(signed.signature)
        try writer.appendLengthPrefixed(signed.signingPublicKey)
        guard writer.data.count <= maximumEncodedBytes else {
            throw PairingError.invalidEncoding
        }
        return writer.data
    }

    static func decode(_ data: Data) throws -> SignedPairingPayload {
        guard data.count <= maximumEncodedBytes else {
            throw PairingError.invalidEncoding
        }
        var reader = CompactPairingOfferReader(data)
        guard try reader.readData(count: magic.count) == magic else {
            throw PairingError.invalidEncoding
        }

        let protocolVersion = try reader.readUInt16()
        let expiresAt = Date(
            timeIntervalSince1970: Double(bitPattern: try reader.readUInt64())
        )
        let macPublicKey = try reader.readLengthPrefixedData()
        let nonce = try reader.readLengthPrefixedData()
        guard let serviceName = String(
            data: try reader.readLengthPrefixedData(),
            encoding: .utf8
        ) else {
            throw PairingError.invalidEncoding
        }

        let relayFlag = try reader.readByte()
        let relayRoute: RelayRoute?
        switch relayFlag {
        case 0:
            relayRoute = nil
        case 1:
            guard let host = String(
                data: try reader.readLengthPrefixedData(),
                encoding: .utf8
            ) else {
                throw PairingError.invalidEncoding
            }
            let port = try reader.readUInt16()
            let roomID = try reader.readLengthPrefixedData()
            let accessKey = try reader.readLengthPrefixedData()
            let routeExpiresAt = Date(
                timeIntervalSince1970: Double(bitPattern: try reader.readUInt64())
            )
            let transport: RelayWireTransport
            switch try reader.readByte() {
            case 0:
                transport = .tlsTCP
            case 1:
                transport = .secureWebSocket
            default:
                throw PairingError.invalidEncoding
            }
            relayRoute = RelayRoute(
                host: host,
                port: port,
                roomID: roomID,
                accessKey: accessKey,
                expiresAt: routeExpiresAt,
                transport: transport
            )
        default:
            throw PairingError.invalidEncoding
        }

        let signature = try reader.readLengthPrefixedData()
        let signingPublicKey = try reader.readLengthPrefixedData()
        guard reader.isAtEnd else {
            throw PairingError.invalidEncoding
        }

        return SignedPairingPayload(
            payload: PairingPayload(
                protocolVersion: protocolVersion,
                macPublicKey: macPublicKey,
                nonce: nonce,
                expiresAt: expiresAt,
                serviceName: serviceName,
                relayRoute: relayRoute
            ),
            signature: signature,
            signingPublicKey: signingPublicKey
        )
    }
}

private struct CompactPairingOfferWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func appendLengthPrefixed(_ value: Data) throws {
        guard value.count <= Int(UInt8.max) else {
            throw PairingError.invalidEncoding
        }
        append(UInt8(value.count))
        append(value)
    }
}

private struct CompactPairingOfferReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw PairingError.invalidEncoding
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readByte())
        let low = UInt16(try readByte())
        return (high << 8) | low
    }

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(try readByte())
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count, offset <= bytes.count - count else {
            throw PairingError.invalidEncoding
        }
        let result = Data(bytes[offset..<(offset + count)])
        offset += count
        return result
    }

    mutating func readLengthPrefixedData() throws -> Data {
        try readData(count: Int(readByte()))
    }
}
