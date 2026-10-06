public enum VideoEncoderConfigurationError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidFrameRate
    case invalidBitRate
}

public struct VideoEncoderConfiguration: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let averageBitRate: Int
    public let keyFrameInterval: Int

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        averageBitRate: Int,
        keyFrameInterval: Int? = nil
    ) throws {
        guard (16...8_192).contains(width),
              (16...8_192).contains(height) else {
            throw VideoEncoderConfigurationError.invalidDimensions
        }
        guard (1...60).contains(framesPerSecond) else {
            throw VideoEncoderConfigurationError.invalidFrameRate
        }
        guard (100_000...100_000_000).contains(averageBitRate) else {
            throw VideoEncoderConfigurationError.invalidBitRate
        }
        let interval = keyFrameInterval ?? framesPerSecond * 2
        guard interval > 0, interval <= framesPerSecond * 10 else {
            throw VideoEncoderConfigurationError.invalidFrameRate
        }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.averageBitRate = averageBitRate
        self.keyFrameInterval = interval
    }
}
