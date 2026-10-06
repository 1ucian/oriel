import CoreGraphics

public enum CaptureContractError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidScaleFactor
}

public struct CaptureFrameMetadata: Equatable, Sendable {
    public let sequence: UInt64
    public let monotonicTimestampNanoseconds: UInt64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scaleFactor: Double
    public let displayID: UInt32
    public let damageRegion: CGRect

    public init(
        sequence: UInt64,
        monotonicTimestampNanoseconds: UInt64,
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: Double,
        displayID: UInt32,
        damageRegion: CGRect
    ) {
        self.sequence = sequence
        self.monotonicTimestampNanoseconds = monotonicTimestampNanoseconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleFactor = scaleFactor
        self.displayID = displayID
        self.damageRegion = damageRegion
    }

    public static func validated(
        sequence: UInt64,
        monotonicTimestampNanoseconds: UInt64,
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: Double,
        displayID: UInt32,
        damageRegion: CGRect
    ) throws -> Self {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw CaptureContractError.invalidDimensions
        }
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            throw CaptureContractError.invalidScaleFactor
        }
        return Self(
            sequence: sequence,
            monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleFactor: scaleFactor,
            displayID: displayID,
            damageRegion: damageRegion
        )
    }

    public func isStale(
        atNanoseconds now: UInt64,
        maximumAgeNanoseconds: UInt64
    ) -> Bool {
        guard now >= monotonicTimestampNanoseconds else {
            return true
        }
        return now - monotonicTimestampNanoseconds > maximumAgeNanoseconds
    }
}

public struct FrameSequenceValidator: Sendable {
    private var lastAcceptedSequence: UInt64?

    public init() {}

    public mutating func accept(_ sequence: UInt64) -> Bool {
        if let lastAcceptedSequence, sequence <= lastAcceptedSequence {
            return false
        }
        lastAcceptedSequence = sequence
        return true
    }
}
