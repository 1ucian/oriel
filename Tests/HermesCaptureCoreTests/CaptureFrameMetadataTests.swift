import CoreGraphics
import Testing
@testable import HermesCaptureCore

struct CaptureFrameMetadataTests {
    @Test func newerSequenceIsAccepted() {
        var validator = FrameSequenceValidator()

        let firstAccepted = validator.accept(1)
        let secondAccepted = validator.accept(2)

        #expect(firstAccepted)
        #expect(secondAccepted)
    }

    @Test func duplicateAndRegressedSequencesAreRejected() {
        var validator = FrameSequenceValidator()

        let firstAccepted = validator.accept(9)
        let duplicateAccepted = validator.accept(9)
        let regressedAccepted = validator.accept(8)

        #expect(firstAccepted)
        #expect(!duplicateAccepted)
        #expect(!regressedAccepted)
    }

    @Test func frameBecomesStaleAfterMaximumAge() {
        let frame = CaptureFrameMetadata(
            sequence: 4,
            monotonicTimestampNanoseconds: 1_000_000_000,
            pixelWidth: 1920,
            pixelHeight: 1080,
            scaleFactor: 2,
            displayID: 1,
            damageRegion: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        #expect(!frame.isStale(atNanoseconds: 1_099_999_999, maximumAgeNanoseconds: 100_000_000))
        #expect(frame.isStale(atNanoseconds: 1_100_000_001, maximumAgeNanoseconds: 100_000_000))
    }

    @Test func futureTimestampIsRejectedAsStale() {
        let frame = CaptureFrameMetadata(
            sequence: 1,
            monotonicTimestampNanoseconds: 200,
            pixelWidth: 100,
            pixelHeight: 100,
            scaleFactor: 1,
            displayID: 1,
            damageRegion: .zero
        )

        #expect(frame.isStale(atNanoseconds: 100, maximumAgeNanoseconds: 1_000))
    }

    @Test func invalidDimensionsAreRejected() {
        #expect(throws: CaptureContractError.invalidDimensions) {
            try CaptureFrameMetadata.validated(
                sequence: 1,
                monotonicTimestampNanoseconds: 1,
                pixelWidth: 0,
                pixelHeight: 1080,
                scaleFactor: 2,
                displayID: 1,
                damageRegion: .zero
            )
        }
    }
}
