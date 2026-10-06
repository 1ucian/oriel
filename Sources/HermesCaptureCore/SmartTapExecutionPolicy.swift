public enum SmartTapDenialReason: Equatable, Sendable {
    case frameSequenceMismatch
    case staleTarget
    case targetTimestampInFuture
    case sensitiveTarget
    case disabledTarget
}

public enum SmartTapExecutionDecision: Equatable, Sendable {
    case allowed
    case denied(SmartTapDenialReason)
}

public struct SmartTapExecutionPolicy: Sendable {
    public let maximumAgeNanoseconds: UInt64

    public init(maximumAgeNanoseconds: UInt64 = 500_000_000) {
        self.maximumAgeNanoseconds = maximumAgeNanoseconds
    }

    public func validate(
        _ candidate: TargetCandidate,
        displayedFrameSequence: UInt64,
        nowNanoseconds: UInt64
    ) -> SmartTapExecutionDecision {
        guard candidate.frameSequence == displayedFrameSequence else {
            return .denied(.frameSequenceMismatch)
        }
        guard nowNanoseconds >= candidate.monotonicTimestampNanoseconds else {
            return .denied(.targetTimestampInFuture)
        }
        guard nowNanoseconds - candidate.monotonicTimestampNanoseconds <= maximumAgeNanoseconds else {
            return .denied(.staleTarget)
        }
        guard !candidate.isSensitive else { return .denied(.sensitiveTarget) }
        guard candidate.isEnabled else { return .denied(.disabledTarget) }
        return .allowed
    }
}
