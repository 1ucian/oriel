import Testing
@testable import HermesCaptureCore

struct VideoEncoderConfigurationTests {
    @Test func acceptsLowLatencyPhaseOneDefaults() throws {
        let configuration = try VideoEncoderConfiguration(
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            averageBitRate: 6_000_000
        )
        #expect(configuration.keyFrameInterval == 60)
    }

    @Test func rejectsUnsafeDimensionsAndRates() {
        #expect(throws: VideoEncoderConfigurationError.invalidDimensions) {
            try VideoEncoderConfiguration(
                width: 0,
                height: 1_080,
                framesPerSecond: 30,
                averageBitRate: 6_000_000
            )
        }
        #expect(throws: VideoEncoderConfigurationError.invalidFrameRate) {
            try VideoEncoderConfiguration(
                width: 1_920,
                height: 1_080,
                framesPerSecond: 120,
                averageBitRate: 6_000_000
            )
        }
        #expect(throws: VideoEncoderConfigurationError.invalidBitRate) {
            try VideoEncoderConfiguration(
                width: 1_920,
                height: 1_080,
                framesPerSecond: 30,
                averageBitRate: 99
            )
        }
    }
}
