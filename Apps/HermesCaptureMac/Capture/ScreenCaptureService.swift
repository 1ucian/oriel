import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import HermesCaptureCore
import ScreenCaptureKit

final class ScreenCaptureService: NSObject, CaptureService, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum ServiceError: Error {
        case displayNotFound(CGDirectDisplayID)
        case alreadyRunning
    }

    var frames: AsyncStream<CaptureFrame> { frameStream.values }

    private let frameStream = RestartableAsyncStream<CaptureFrame>(
        bufferingPolicy: .bufferingNewest(3)
    )
    private let sampleQueue = DispatchQueue(
        label: "com.67enterprise.hermescapture.capture",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private let compatibilityWriter: LegacySharedFrameWriter?

    private var currentStream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var activeDisplayID: CGDirectDisplayID?
    private var frameSequence: UInt64 = 0
    private var compatibilityWritingEnabled = false

    override convenience init() {
        self.init(compatibilityWriter: nil)
    }

    init(compatibilityWriter: LegacySharedFrameWriter?) {
        self.compatibilityWriter = compatibilityWriter
        super.init()
    }

    func start(displayID: UInt32) async throws {
        let isAlreadyRunning = stateLock.withLock { self.currentStream != nil }
        guard !isAlreadyRunning else {
            throw ServiceError.alreadyRunning
        }

        guard let display = try await DisplayCatalog.findDisplay(id: displayID) else {
            throw ServiceError.displayNotFound(displayID)
        }

        frameStream.restart()

        let configuration = makeConfiguration(
            display: display,
            cadence: .interactive
        )
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        try await stream.startCapture()

        stateLock.withLock {
            self.currentStream = stream
            self.configuration = configuration
            activeDisplayID = displayID
            frameSequence = 0
        }
    }

    func stop() async {
        let stream = stateLock.withLock {
            let streamToStop = self.currentStream
            self.currentStream = nil
            self.configuration = nil
            self.activeDisplayID = nil
            return streamToStop
        }

        try? await stream?.stopCapture()
        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
        }
        frameStream.finish()
    }

    func updateCadence(_ cadence: CaptureCadence) async throws {
        try await updateFramesPerSecond(cadence.framesPerSecond)
    }

    func updateFramesPerSecond(_ framesPerSecond: Int32) async throws {
        let (stream, configuration) = stateLock.withLock {
            (self.currentStream, self.configuration)
        }

        guard let stream, let configuration else {
            return
        }
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: max(5, min(60, framesPerSecond))
        )
        try await stream.updateConfiguration(configuration)
    }

    func setCompatibilityWritingEnabled(_ enabled: Bool) {
        stateLock.withLock {
            compatibilityWritingEnabled = enabled
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let (sequence, displayID, shouldWriteCompatibilityFrame) = stateLock.withLock {
            self.frameSequence &+= 1
            return (
                self.frameSequence,
                self.activeDisplayID ?? 0,
                self.compatibilityWritingEnabled
            )
        }

        let metadata = CaptureFrameMetadata(
            sequence: sequence,
            monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
            pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
            scaleFactor: 1,
            displayID: displayID,
            damageRegion: .zero
        )
        frameStream.yield(
            CaptureFrame(pixelBuffer: pixelBuffer, metadata: metadata)
        )
        if shouldWriteCompatibilityFrame, let compatibilityWriter {
            try? compatibilityWriter.write(pixelBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateLock.withLock {
            self.currentStream = nil
            self.configuration = nil
            self.activeDisplayID = nil
        }
    }

    private func makeConfiguration(
        display: SCDisplay,
        cadence: CaptureCadence
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: cadence.framesPerSecond
        )
        configuration.queueDepth = 5
        configuration.showsCursor = true
        return configuration
    }
}
