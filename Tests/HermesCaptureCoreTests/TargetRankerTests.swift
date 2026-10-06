import Testing
@testable import HermesCaptureCore

struct TargetRankerTests {
    private let now: UInt64 = 10_000

    @Test func accessibilityOutranksHigherConfidenceVision() throws {
        let ax = try candidate(id: "ax", source: .accessibility, confidence: 0.91)
        let ocr = try candidate(id: "ocr", source: .visionOCR, confidence: 0.99)
        let result = TargetRanker().rank([ocr, ax], displayedFrameSequence: 7, nowNanoseconds: now)
        #expect(result == .automatic(ax))
    }

    @Test func staleDisabledAndSensitiveCandidatesAreExcluded() throws {
        let stale = try candidate(id: "stale", source: .accessibility, confidence: 0.99, timestamp: 1)
        let disabled = try candidate(id: "disabled", source: .accessibility, confidence: 0.99, enabled: false)
        let sensitive = try candidate(id: "secret", source: .accessibility, confidence: 0.99, sensitive: true)
        let result = TargetRanker(configuration: .init(maximumAgeNanoseconds: 500)).rank(
            [stale, disabled, sensitive], displayedFrameSequence: 7, nowNanoseconds: now
        )
        #expect(result == .none(.noEligibleCandidates))
    }

    @Test func belowAutoThresholdRequiresConfirmation() throws {
        let target = try candidate(id: "confirm", source: .visionOCR, confidence: 0.78)
        let result = TargetRanker().rank([target], displayedFrameSequence: 7, nowNanoseconds: now)
        #expect(result == .confirmationRequired([target]))
    }

    @Test func overlappingNearTiesRefuseToGuess() throws {
        let first = try candidate(id: "a", source: .visionOCR, confidence: 0.95)
        let second = try candidate(id: "b", source: .visionOCR, confidence: 0.94, x: 0.11, y: 0.11)
        let result = TargetRanker().rank([first, second], displayedFrameSequence: 7, nowNanoseconds: now)
        #expect(result == .ambiguous([first, second]))
    }

    @Test func ambiguityDetectionDoesNotStopAtNonOverlappingDistractor() throws {
        let first = try candidate(id: "a", source: .visionOCR, confidence: 0.95)
        let distractor = try candidate(id: "b", source: .visionOCR, confidence: 0.945, x: 0.7, y: 0.7)
        let overlapping = try candidate(id: "c", source: .visionOCR, confidence: 0.94, x: 0.11, y: 0.11)
        let result = TargetRanker().rank([first, distractor, overlapping], displayedFrameSequence: 7, nowNanoseconds: now)
        #expect(result == .ambiguous([first, overlapping]))
    }

    @Test func invalidCandidateGeometryIsRejected() {
        #expect(throws: TargetCandidateError.invalidBounds) {
            _ = try candidate(id: "bad", source: .openCV, confidence: 0.9, x: -0.1)
        }
    }

    private func candidate(
        id: String,
        source: TargetSource,
        confidence: Double,
        timestamp: UInt64 = 9_900,
        enabled: Bool = true,
        sensitive: Bool = false,
        x: Double = 0.1,
        y: Double = 0.1
    ) throws -> TargetCandidate {
        try TargetCandidate.validated(
            stableIdentifier: id,
            bounds: .init(x: x, y: y, width: 0.2, height: 0.1),
            label: id,
            role: .button,
            source: source,
            frameSequence: 7,
            monotonicTimestampNanoseconds: timestamp,
            confidence: confidence,
            isEnabled: enabled,
            isSensitive: sensitive
        )
    }
}
