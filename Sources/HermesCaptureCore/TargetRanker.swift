import Foundation

public enum TargetRankingNoneReason: Equatable, Sendable {
    case noEligibleCandidates
    case belowConfirmationThreshold
}

public enum TargetRankingDecision: Equatable, Sendable {
    case automatic(TargetCandidate)
    case confirmationRequired([TargetCandidate])
    case ambiguous([TargetCandidate])
    case none(TargetRankingNoneReason)
}

public struct TargetRankerConfiguration: Equatable, Sendable {
    public var maximumAgeNanoseconds: UInt64
    public var automaticConfidenceThreshold: Double
    public var confirmationConfidenceThreshold: Double
    public var ambiguityScoreDelta: Double
    public var ambiguityOverlapRatio: Double
    public var allowedOwnedCoreMLLabels: Set<String>

    public init(
        maximumAgeNanoseconds: UInt64 = 500_000_000,
        automaticConfidenceThreshold: Double = 0.90,
        confirmationConfidenceThreshold: Double = 0.65,
        ambiguityScoreDelta: Double = 0.03,
        ambiguityOverlapRatio: Double = 0.50,
        allowedOwnedCoreMLLabels: Set<String> = []
    ) {
        self.maximumAgeNanoseconds = maximumAgeNanoseconds
        self.automaticConfidenceThreshold = automaticConfidenceThreshold
        self.confirmationConfidenceThreshold = confirmationConfidenceThreshold
        self.ambiguityScoreDelta = ambiguityScoreDelta
        self.ambiguityOverlapRatio = ambiguityOverlapRatio
        self.allowedOwnedCoreMLLabels = allowedOwnedCoreMLLabels
    }
}

public struct TargetRanker: Sendable {
    public let configuration: TargetRankerConfiguration

    public init(configuration: TargetRankerConfiguration = .init()) {
        self.configuration = configuration
    }

    public func rank(
        _ candidates: [TargetCandidate],
        displayedFrameSequence: UInt64,
        nowNanoseconds: UInt64
    ) -> TargetRankingDecision {
        let eligible = candidates.filter {
            $0.frameSequence == displayedFrameSequence
                && isFresh($0, nowNanoseconds: nowNanoseconds)
                && $0.isEnabled
                && !$0.isSensitive
                && ($0.source != .ownedCoreML || configuration.allowedOwnedCoreMLLabels.contains($0.label))
        }.sorted(by: orderedBefore)

        guard let top = eligible.first else { return .none(.noEligibleCandidates) }

        let ambiguous = eligible.filter { candidate in
            score(top) - score(candidate) <= configuration.ambiguityScoreDelta
                && top.bounds.overlapRatio(with: candidate.bounds) >= configuration.ambiguityOverlapRatio
        }
        if ambiguous.count > 1 {
            return .ambiguous(ambiguous)
        }

        if top.confidence >= configuration.automaticConfidenceThreshold {
            return .automatic(top)
        }
        if top.confidence >= configuration.confirmationConfidenceThreshold {
            return .confirmationRequired([top])
        }
        return .none(.belowConfirmationThreshold)
    }

    private func isFresh(_ candidate: TargetCandidate, nowNanoseconds: UInt64) -> Bool {
        nowNanoseconds >= candidate.monotonicTimestampNanoseconds
            && nowNanoseconds - candidate.monotonicTimestampNanoseconds <= configuration.maximumAgeNanoseconds
    }

    private func score(_ candidate: TargetCandidate) -> Double {
        Double(candidate.source.rank) + candidate.confidence
    }

    private func orderedBefore(_ lhs: TargetCandidate, _ rhs: TargetCandidate) -> Bool {
        let leftScore = score(lhs)
        let rightScore = score(rhs)
        if leftScore != rightScore { return leftScore > rightScore }
        if lhs.bounds.y != rhs.bounds.y { return lhs.bounds.y < rhs.bounds.y }
        if lhs.bounds.x != rhs.bounds.x { return lhs.bounds.x < rhs.bounds.x }
        return lhs.stableIdentifier < rhs.stableIdentifier
    }
}
