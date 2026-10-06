import Foundation

public enum LegacyFrameError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidMagic
}

public struct LegacyFrameHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x4852_4331
    public static let encodedSize = 64

    public let sequence: UInt64
    public let width: UInt32
    public let height: UInt32
    public let bytesPerRow: UInt32

    public init(
        sequence: UInt64,
        width: UInt32,
        height: UInt32,
        bytesPerRow: UInt32
    ) {
        self.sequence = sequence
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.encodedSize)
        data.appendLittleEndian(Self.magic)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(width)
        data.appendLittleEndian(height)
        data.appendLittleEndian(bytesPerRow)
        data.append(Data(repeating: 0, count: Self.encodedSize - data.count))
        return data
    }

    public static func decode<D: DataProtocol>(_ bytes: D) throws -> Self {
        let data = Data(bytes)
        guard data.count >= encodedSize else {
            throw LegacyFrameError.invalidHeader
        }
        var cursor = 0
        let magic: UInt32 = try data.readLittleEndian(at: &cursor)
        guard magic == Self.magic else {
            throw LegacyFrameError.invalidMagic
        }
        return try Self(
            sequence: data.readLittleEndian(at: &cursor),
            width: data.readLittleEndian(at: &cursor),
            height: data.readLittleEndian(at: &cursor),
            bytesPerRow: data.readLittleEndian(at: &cursor)
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(at cursor: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard cursor + size <= count else {
            throw LegacyFrameError.invalidHeader
        }
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) {
            copyBytes(to: $0, from: cursor..<(cursor + size))
        }
        cursor += size
        return T(littleEndian: value)
    }
}
