import CoreVideo
import Foundation

public final class LegacySharedFrameWriter: @unchecked Sendable {
    public static var developmentURL: URL {
        FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent(
            "com.67enterprise.hermescapture/Compatibility/frame.raw",
            isDirectory: false
        )
    }

    private let url: URL
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var mappedSize = 0
    private var sequence: UInt64 = 0

    public init(url: URL = LegacySharedFrameWriter.developmentURL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? fileHandle?.close()
    }

    public func write(_ pixelBuffer: CVPixelBuffer) throws {
        try lock.withLock {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pixelByteCount = bytesPerRow * height
            let requiredSize = LegacyFrameHeader.encodedSize + pixelByteCount
            let handle = try prepareFile(requiredSize: requiredSize)

            let pixelData = Data(bytes: baseAddress, count: pixelByteCount)
            try handle.seek(toOffset: UInt64(LegacyFrameHeader.encodedSize))
            try handle.write(contentsOf: pixelData)
            try handle.synchronize()

            let nextSequence = sequence &+ 1
            let header = LegacyFrameHeader(
                sequence: nextSequence,
                width: UInt32(width),
                height: UInt32(height),
                bytesPerRow: UInt32(bytesPerRow)
            )
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header.encoded())
            try handle.synchronize()
            sequence = nextSequence
        }
    }

    private func prepareFile(requiredSize: Int) throws -> FileHandle {
        if let fileHandle, mappedSize == requiredSize {
            return fileHandle
        }

        try fileHandle?.close()
        fileHandle = nil
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: UInt64(requiredSize))
        try handle.seek(toOffset: 0)
        try handle.write(
            contentsOf: Data(repeating: 0, count: LegacyFrameHeader.encodedSize)
        )
        try handle.synchronize()
        fileHandle = handle
        mappedSize = requiredSize
        return handle
    }
}
