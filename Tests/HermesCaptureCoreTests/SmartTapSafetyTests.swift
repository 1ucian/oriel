import Testing
@testable import HermesCaptureCore

struct SmartTapSafetyTests {
    @Test func executionRequiresMatchingDisplayedFrameSequence() throws {
        let target = try makeTarget(sequence: 41)
        let policy = SmartTapExecutionPolicy(maximumAgeNanoseconds: 1_000)
        #expect(policy.validate(target, displayedFrameSequence: 42, nowNanoseconds: 10_000) == .denied(.frameSequenceMismatch))
    }

    @Test func executionRejectsStaleAndSensitiveTargets() throws {
        let stale = try makeTarget(sequence: 42, timestamp: 100)
        let sensitive = try makeTarget(sequence: 42, timestamp: 9_900, sensitive: true)
        let policy = SmartTapExecutionPolicy(maximumAgeNanoseconds: 1_000)
        #expect(policy.validate(stale, displayedFrameSequence: 42, nowNanoseconds: 10_000) == .denied(.staleTarget))
        #expect(policy.validate(sensitive, displayedFrameSequence: 42, nowNanoseconds: 10_000) == .denied(.sensitiveTarget))
    }

    @Test func sanitizerNeverUsesAccessibilityValueAndExcludesSecureText() {
        let normal = AccessibilityTargetSanitizer.sanitize(.init(
            role: "AXButton", subrole: nil, label: "Continue", title: nil,
            value: "private-value", isEnabled: true,
            bounds: .init(x: 10, y: 20, width: 100, height: 30)
        ))
        #expect(normal?.label == "Continue")
        #expect(normal?.label != "private-value")

        let secure = AccessibilityTargetSanitizer.sanitize(.init(
            role: "AXTextField", subrole: "AXSecureTextField", label: "Password",
            title: nil, value: "hunter2", isEnabled: true,
            bounds: .init(x: 0, y: 0, width: 100, height: 30)
        ))
        #expect(secure == nil)

        let hidden = AccessibilityTargetSanitizer.sanitize(.init(
            role: "AXButton", subrole: nil, label: "Hidden", title: nil,
            value: nil, isEnabled: true, isVisible: false,
            bounds: .init(x: 0, y: 0, width: 100, height: 30)
        ))
        #expect(hidden == nil)
    }

    @Test func visibleSensitiveTextIsMarkedForExclusion() {
        #expect(SensitiveTextClassifier.isSensitive("Verification code 123456"))
        #expect(SensitiveTextClassifier.isSensitive("Card 4242 4242 4242 4242"))
        #expect(!SensitiveTextClassifier.isSensitive("Open Settings"))
    }

    private func makeTarget(sequence: UInt64, timestamp: UInt64 = 9_900, sensitive: Bool = false) throws -> TargetCandidate {
        try TargetCandidate.validated(
            stableIdentifier: "target", bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
            label: "Target", role: .button, source: .accessibility,
            frameSequence: sequence, monotonicTimestampNanoseconds: timestamp,
            confidence: 0.99, isEnabled: true, isSensitive: sensitive
        )
    }
}
