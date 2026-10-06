import Testing
@testable import HermesCaptureCore

struct VideoOutputDimensionsTests {
    @Test func capsUltrawideSourceAtNetworkEnvelopeWithoutDistortion() throws {
        let dimensions = try VideoOutputDimensions.networkAspectFit(
            sourceWidth: 5_120,
            sourceHeight: 1_440
        )

        #expect(dimensions.width == 1_920)
        #expect(dimensions.height == 540)
    }

    @Test func preservesSourceAlreadyInsideNetworkEnvelope() throws {
        let dimensions = try VideoOutputDimensions.networkAspectFit(
            sourceWidth: 1_280,
            sourceHeight: 720
        )

        #expect(dimensions.width == 1_280)
        #expect(dimensions.height == 720)
    }
}
