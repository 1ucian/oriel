import CoreVideo
import Foundation
import Testing
@testable import HermesCaptureCore

struct LegacySharedFrameWriterTests {
    @Test func headerMatchesPythonHRC1Fixture() throws {
        let header = LegacyFrameHeader(
            sequence: 0x0102_0304_0506_0708,
            width: 1920,
            height: 1080,
            bytesPerRow: 7680
        )

        let data = header.encoded()

        #expect(data.count == 64)
        #expect(Array(data.prefix(24)) == [
            0x31, 0x43, 0x52, 0x48,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x80, 0x07, 0x00, 0x00,
            0x38, 0x04, 0x00, 0x00,
            0x00, 0x1E, 0x00, 0x00,
        ])
        #expect(data.dropFirst(24).allSatisfy { $0 == 0 })
    }

    @Test func writerPublishesPixelsBeforeHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("frame.raw")
        let writer = try LegacySharedFrameWriter(url: url)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey: 8] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let byteCount = CVPixelBufferGetBytesPerRow(buffer) * 2
        memset(CVPixelBufferGetBaseAddress(buffer), 0xAB, byteCount)
        CVPixelBufferUnlockBaseAddress(buffer, [])

        try writer.write(buffer)
        let data = try Data(contentsOf: url)
        let header = try LegacyFrameHeader.decode(data.prefix(64))

        #expect(header.sequence == 1)
        #expect(header.width == 2)
        #expect(header.height == 2)
        #expect(data.dropFirst(64).allSatisfy { $0 == 0xAB })
    }
}
