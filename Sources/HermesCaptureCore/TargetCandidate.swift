import Foundation

public enum TargetCandidateError: Error, Equatable, Sendable {
    case emptyIdentifier
    case invalidBounds
    case invalidConfidence
    case emptyLabel
}

public struct NormalizedTargetBounds: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }

    public func overlapRatio(with other: Self) -> Double {
        let intersectionWidth = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let intersectionHeight = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let intersection = intersectionWidth * intersectionHeight
        let smallerArea = min(width * height, other.width * other.height)
        return smallerArea > 0 ? intersection / smallerArea : 0
    }
}

public enum TargetRole: String, CaseIterable, Hashable, Sendable {
    case button
    case link
    case checkbox
    case radioButton
    case menuItem
    case tab
    case text
    case image
    case object
    case unknown
}

public enum TargetSource: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case visionOCR
    case openCV
    case ownedCoreML

    var rank: Int {
        switch self {
        case .accessibility: 4
        case .visionOCR: 3
        case .openCV: 2
        case .ownedCoreML: 1
        }
    }
}

public struct TargetCandidate: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { stableIdentifier }
    public let stableIdentifier: String
    public let bounds: NormalizedTargetBounds
    public let label: String
    public let role: TargetRole
    public let source: TargetSource
    public let frameSequence: UInt64
    public let monotonicTimestampNanoseconds: UInt64
    public let confidence: Double
    public let isEnabled: Bool
    public let isSensitive: Bool

    private init(
        stableIdentifier: String,
        bounds: NormalizedTargetBounds,
        label: String,
        role: TargetRole,
        source: TargetSource,
        frameSequence: UInt64,
        monotonicTimestampNanoseconds: UInt64,
        confidence: Double,
        isEnabled: Bool,
        isSensitive: Bool
    ) {
        self.stableIdentifier = stableIdentifier
        self.bounds = bounds
        self.label = label
        self.role = role
        self.source = source
        self.frameSequence = frameSequence
        self.monotonicTimestampNanoseconds = monotonicTimestampNanoseconds
        self.confidence = confidence
        self.isEnabled = isEnabled
        self.isSensitive = isSensitive
    }

    public static func validated(
        stableIdentifier: String,
        bounds: NormalizedTargetBounds,
        label: String,
        role: TargetRole,
        source: TargetSource,
        frameSequence: UInt64,
        monotonicTimestampNanoseconds: UInt64,
        confidence: Double,
        isEnabled: Bool,
        isSensitive: Bool
    ) throws -> Self {
        guard !stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TargetCandidateError.emptyIdentifier
        }
        guard bounds.isValid else { throw TargetCandidateError.invalidBounds }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw TargetCandidateError.invalidConfidence
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TargetCandidateError.emptyLabel
        }
        return Self(
            stableIdentifier: stableIdentifier,
            bounds: bounds,
            label: label,
            role: role,
            source: source,
            frameSequence: frameSequence,
            monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
            confidence: confidence,
            isEnabled: isEnabled,
            isSensitive: isSensitive
        )
    }
}
