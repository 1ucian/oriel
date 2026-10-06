import CoreVideo
import Foundation
import HermesCaptureCore
import Testing
@testable import HermesCaptureMac

@MainActor
struct LocalCaptureBridgeTests {
    @Test func defaultCacheDirectoryUsesDedicatedOrielNamespace() {
        #expect(LocalCaptureBridge.defaultCacheDirectory.lastPathComponent == "oriel")
        #expect(LocalCaptureBridge.defaultCacheDirectory.deletingLastPathComponent().lastPathComponent == "cache")
    }

    @Test func startClaimsCacheAndUsesIdleExactFPSWithRawWritingDisabled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try await fixture.bridge.start()
        defer { Task { await fixture.bridge.stop() } }

        #expect(fixture.service.startedDisplayIDs == [42])
        #expect(fixture.service.framesPerSecond == [5])
        #expect(fixture.service.compatibilityWritingStates == [false])
        #expect(
            try String(contentsOf: fixture.directory.appendingPathComponent("pid"), encoding: .utf8)
                == "12345"
        )
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("frame.raw").path))
    }

    @Test func controlsPreserveExactFPSAndGateRawWritesOnFreshConsumerRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.bridge.start()
        defer { Task { await fixture.bridge.stop() } }

        fixture.service.send(frame: try makeFrame())
        try "17".write(
            to: fixture.directory.appendingPathComponent("fps"),
            atomically: true,
            encoding: .utf8
        )
        try "1".write(
            to: fixture.directory.appendingPathComponent("raw"),
            atomically: true,
            encoding: .utf8
        )
        try "capture".write(
            to: fixture.directory.appendingPathComponent("req"),
            atomically: true,
            encoding: .utf8
        )

        try await waitUntil {
            fixture.encoder.encodedURLs.contains(fixture.directory.appendingPathComponent("latest.png"))
                && fixture.service.framesPerSecond.contains(17)
                && fixture.service.compatibilityWritingStates.last == true
        }
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("latest.png").path))
    }

    @Test func liveDifferentPIDOwnsCacheAndPreventsCaptureStartup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: fixture.directory.appendingPathComponent("pid"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: LocalCaptureBridge.BridgeError.self) {
            try await fixture.bridge.start()
        }

        #expect(fixture.service.startedDisplayIDs.isEmpty)
        #expect(
            try String(contentsOf: fixture.directory.appendingPathComponent("pid"), encoding: .utf8)
                == String(ProcessInfo.processInfo.processIdentifier)
        )
    }

    @Test func partialStartupFailureStopsCaptureAndReleasesOwnedPID() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.service.failFPSUpdate = true

        await #expect(throws: FakeError.self) {
            try await fixture.bridge.start()
        }

        #expect(fixture.service.stopCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pid").path))
    }

    @Test func stopReleasesOnlyItsOwnPIDAndStopsCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.bridge.start()

        await fixture.bridge.stop()

        #expect(fixture.service.stopCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pid").path))
    }

    private struct Fixture {
        let directory: URL
        let service: FakeLocalCaptureService
        let encoder: FakeFrameImageEncoder
        let bridge: LocalCaptureBridge

        @MainActor
        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            service = FakeLocalCaptureService()
            encoder = FakeFrameImageEncoder()
            bridge = LocalCaptureBridge(
                cacheDirectory: directory,
                displayID: 42,
                processIdentifier: 12345,
                pollInterval: .milliseconds(10),
                service: service,
                imageEncoder: encoder
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFrame() throws -> CaptureFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        return CaptureFrame(
            pixelBuffer: pixelBuffer,
            metadata: CaptureFrameMetadata(
                sequence: 1,
                monotonicTimestampNanoseconds: 1,
                pixelWidth: 2,
                pixelHeight: 2,
                scaleFactor: 1,
                displayID: 7,
                damageRegion: .zero
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for bridge state")
    }
}

private enum FakeError: Error {
    case fpsUpdate
}

@MainActor
private final class FakeLocalCaptureService: LocalCaptureServicing {
    let frames: AsyncStream<CaptureFrame>
    private let continuation: AsyncStream<CaptureFrame>.Continuation
    private(set) var startedDisplayIDs: [UInt32] = []
    private(set) var framesPerSecond: [Int32] = []
    private(set) var compatibilityWritingStates: [Bool] = []
    private(set) var stopCount = 0
    var failFPSUpdate = false

    init() {
        let channel = AsyncStream.makeStream(of: CaptureFrame.self)
        frames = channel.stream
        continuation = channel.continuation
    }

    func start(displayID: UInt32) async throws {
        startedDisplayIDs.append(displayID)
    }

    func stop() async {
        stopCount += 1
    }

    func updateFramesPerSecond(_ framesPerSecond: Int32) async throws {
        if failFPSUpdate { throw FakeError.fpsUpdate }
        self.framesPerSecond.append(framesPerSecond)
    }

    func setCompatibilityWritingEnabled(_ enabled: Bool) {
        compatibilityWritingStates.append(enabled)
    }

    func send(frame: CaptureFrame) {
        continuation.yield(frame)
    }
}

@MainActor
private final class FakeFrameImageEncoder: FrameImageEncoding {
    private(set) var encodedURLs: [URL] = []

    func encodePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        try Data("png".utf8).write(to: url, options: .atomic)
        encodedURLs.append(url)
    }
}
