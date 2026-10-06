import CoreVideo

public struct CaptureFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let metadata: CaptureFrameMetadata

    public init(pixelBuffer: CVPixelBuffer, metadata: CaptureFrameMetadata) {
        self.pixelBuffer = pixelBuffer
        self.metadata = metadata
    }
}

public protocol CaptureService: AnyObject, Sendable {
    var frames: AsyncStream<CaptureFrame> { get }

    func start(displayID: UInt32) async throws
    func stop() async
}
