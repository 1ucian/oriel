import Foundation
import MLX

/// Reads a NumPy `.npz` archive, a zip of `.npy` files, into MLX arrays: the format the
/// mlx-community Whisper weights ship in. Entries must be stored uncompressed, as `mx.savez`
/// and `np.savez` write them. The file is memory-mapped and each array is copied into MLX.
enum WhisperNPZ {
    enum Failure: Error, CustomStringConvertible {
        case notAnArchive
        case compressed(String)
        case malformed(String)

        var description: String {
            switch self {
            case .notAnArchive: "The weights file is not a NumPy archive."
            case let .compressed(name): "The weights entry \(name) is compressed; only stored entries are supported."
            case let .malformed(name): "The weights entry \(name) could not be read."
            }
        }
    }

    /// Every array in the archive by name, without the `.npy` suffix. Entries of a type MLX
    /// cannot hold are left out.
    static func load(_ url: URL) throws -> [String: MLXArray] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var arrays: [String: MLXArray] = [:]
        for entry in try centralDirectory(data) {
            guard entry.method == 0 else { throw Failure.compressed(entry.name) }
            let start = try dataStart(of: entry, in: data)
            guard start + entry.size <= data.count else { throw Failure.malformed(entry.name) }
            let name = entry.name.hasSuffix(".npy") ? String(entry.name.dropLast(4)) : entry.name
            if let array = try npyArray(data, range: start ..< (start + entry.size), name: entry.name) {
                arrays[name] = array
            }
        }
        return arrays
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let size: Int
        let localHeaderOffset: Int
    }

    private static func centralDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
        guard data.count >= 22 else { throw Failure.notAnArchive }
        let lowest = max(0, data.count - 65_557)
        var eocd = -1
        var index = data.count - 22
        while index >= lowest {
            if data.uint32(at: index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw Failure.notAnArchive }
        var count = Int(data.uint16(at: eocd + 10))
        var offset = Int(data.uint32(at: eocd + 16))
        // Zip64: the locator just before the record points at the 64-bit record.
        if count == 0xFFFF || offset == 0xFFFF_FFFF, eocd >= 20, data.uint32(at: eocd - 20) == 0x0706_4B50 {
            let record = Int(data.uint64(at: eocd - 12))
            guard record + 56 <= data.count, data.uint32(at: record) == 0x0606_4B50 else { throw Failure.notAnArchive }
            count = Int(data.uint64(at: record + 32))
            offset = Int(data.uint64(at: record + 48))
        }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var cursor = offset
        for _ in 0 ..< count {
            guard cursor + 46 <= data.count, data.uint32(at: cursor) == 0x0201_4B50 else { throw Failure.notAnArchive }
            let method = data.uint16(at: cursor + 10)
            var size = Int(data.uint32(at: cursor + 24))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            var localOffset = Int(data.uint32(at: cursor + 42))
            guard cursor + 46 + nameLength + extraLength <= data.count else { throw Failure.notAnArchive }
            let name = String(decoding: data[(cursor + 46) ..< (cursor + 46 + nameLength)], as: UTF8.self)
            // Zip64 sizes and offsets live in extra field 0x0001, in this order, when their slots are full.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.uint16(at: extra)
                let length = Int(data.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = Int(data.uint64(at: field)); field += 8 }
                    if Int(data.uint32(at: cursor + 20)) == 0xFFFF_FFFF { field += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = Int(data.uint64(at: field)) }
                }
                extra += 4 + length
            }
            entries.append(Entry(name: name, method: method, size: size, localHeaderOffset: localOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func dataStart(of entry: Entry, in data: Data) throws -> Int {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.uint32(at: header) == 0x0403_4B50 else {
            throw Failure.malformed(entry.name)
        }
        return header + 30 + Int(data.uint16(at: header + 26)) + Int(data.uint16(at: header + 28))
    }

    /// One `.npy` file: magic, version, a little header dictionary, then the raw values.
    private static func npyArray(_ data: Data, range: Range<Int>, name: String) throws -> MLXArray? {
        let start = range.lowerBound
        guard range.count >= 10, data[start] == 0x93,
              String(decoding: data[(start + 1) ..< (start + 6)], as: UTF8.self) == "NUMPY" else {
            throw Failure.malformed(name)
        }
        let major = data[start + 6]
        let headerLength: Int
        let headerStart: Int
        if major == 1 {
            headerLength = Int(data.uint16(at: start + 8))
            headerStart = start + 10
        } else {
            headerLength = Int(data.uint32(at: start + 8))
            headerStart = start + 12
        }
        let valuesStart = headerStart + headerLength
        guard valuesStart <= range.upperBound else { throw Failure.malformed(name) }
        let header = String(decoding: data[headerStart ..< valuesStart], as: UTF8.self)
        guard let descr = capture(#"'descr':\s*'([^']+)'"#, in: header),
              let shapeText = capture(#"'shape':\s*\(([^)]*)\)"#, in: header) else {
            throw Failure.malformed(name)
        }
        if header.contains("'fortran_order': True") { throw Failure.malformed(name) }
        let shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let dtype: DType
        switch descr {
        case "<f2": dtype = .float16
        case "<f4": dtype = .float32
        case "<i4": dtype = .int32
        case "<i8": dtype = .int64
        case "|b1", "<b1": dtype = .bool
        case "|u1": dtype = .uint8
        default: return nil
        }
        let count = shape.reduce(1, *)
        let byteCount = count * dtype.size
        guard valuesStart + byteCount <= range.upperBound else { throw Failure.malformed(name) }
        if count == 0 { return MLXArray.zeros(shape, dtype: dtype) }
        return MLXArray(data[valuesStart ..< (valuesStart + byteCount)], shape, dtype: dtype)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}
