import Foundation

public enum DisplayAspectRatio: String, CaseIterable, Equatable, Hashable, Sendable {
    case landscape16x9
    case landscape16x10
    case landscape4x3
    case landscape3x2
    case square
    case portrait9x16
    case portrait10x16
    case portrait3x4
    case portrait2x3

    public static let standardLandscape: [DisplayAspectRatio] = [
        .landscape16x9,
        .landscape16x10,
        .landscape4x3,
        .landscape3x2,
        .square,
    ]

    public static let standardPortrait: [DisplayAspectRatio] = [
        .portrait9x16,
        .portrait10x16,
        .portrait3x4,
        .portrait2x3,
    ]

    public var isPortrait: Bool {
        switch self {
        case .portrait9x16, .portrait10x16, .portrait3x4, .portrait2x3:
            true
        default:
            false
        }
    }

    public var title: String {
        switch self {
        case .landscape16x9:
            String(localized: "16:9 Landscape", comment: "Display aspect-ratio preset")
        case .landscape16x10:
            String(localized: "16:10 Landscape", comment: "Display aspect-ratio preset")
        case .landscape4x3:
            String(localized: "4:3 Landscape", comment: "Display aspect-ratio preset")
        case .landscape3x2:
            String(localized: "3:2 Landscape", comment: "Display aspect-ratio preset")
        case .square:
            String(localized: "1:1 Square", comment: "Display aspect-ratio preset")
        case .portrait9x16:
            String(localized: "9:16 Portrait", comment: "Display aspect-ratio preset")
        case .portrait10x16:
            String(localized: "10:16 Portrait", comment: "Display aspect-ratio preset")
        case .portrait3x4:
            String(localized: "3:4 Portrait", comment: "Display aspect-ratio preset")
        case .portrait2x3:
            String(localized: "2:3 Portrait", comment: "Display aspect-ratio preset")
        }
    }

    public static func classify(
        width: Int,
        height: Int,
        tolerance: Double = 0.01
    ) -> DisplayAspectRatio? {
        guard width > 0, height > 0, tolerance >= 0 else { return nil }
        return allCases.first { ratio in
            let expected = Double(ratio.widthUnit) / Double(ratio.heightUnit)
            let actual = Double(width) / Double(height)
            return abs(actual - expected) / expected <= tolerance
        }
    }

    fileprivate var widthUnit: Int {
        switch self {
        case .landscape16x9, .landscape16x10: 16
        case .landscape4x3: 4
        case .landscape3x2: 3
        case .square: 1
        case .portrait9x16: 9
        case .portrait10x16: 10
        case .portrait3x4: 3
        case .portrait2x3: 2
        }
    }

    fileprivate var heightUnit: Int {
        switch self {
        case .landscape16x9: 9
        case .landscape16x10: 10
        case .landscape4x3: 3
        case .landscape3x2: 2
        case .square: 1
        case .portrait9x16, .portrait10x16: 16
        case .portrait3x4: 4
        case .portrait2x3: 3
        }
    }

    fileprivate var targetDimensions: (width: Int, height: Int) {
        switch self {
        case .landscape16x9: (1_920, 1_080)
        case .landscape16x10: (1_920, 1_200)
        case .landscape4x3: (1_440, 1_080)
        case .landscape3x2: (1_620, 1_080)
        case .square: (1_080, 1_080)
        case .portrait9x16: (1_080, 1_920)
        case .portrait10x16: (1_200, 1_920)
        case .portrait3x4: (1_080, 1_440)
        case .portrait2x3: (1_080, 1_620)
        }
    }
}

public struct DisplayResolutionPreset: Equatable, Sendable, Identifiable {
    public let aspectRatio: DisplayAspectRatio
    public let mode: DisplayModeProfile?

    public init(aspectRatio: DisplayAspectRatio, mode: DisplayModeProfile?) {
        self.aspectRatio = aspectRatio
        self.mode = mode
    }

    public var id: String { aspectRatio.rawValue }
    public var isAvailable: Bool { mode != nil }

    public var label: String {
        guard let mode else {
            return String(
                localized: "\(aspectRatio.title) · Not supported",
                comment: "Unavailable display resolution preset"
            )
        }
        return "\(aspectRatio.title) · \(mode.label)"
    }

    public var streamingLabel: String? {
        guard let mode,
              let dimensions = try? VideoOutputDimensions.networkAspectFit(
                sourceWidth: mode.pixelWidth,
                sourceHeight: mode.pixelHeight
              ) else {
            return nil
        }
        return String(
            localized: "Streams up to \(dimensions.width)×\(dimensions.height)",
            comment: "Estimated maximum streamed video dimensions"
        )
    }

    public var accessibilityLabel: String {
        guard let streamingLabel else { return label }
        return "\(label). \(streamingLabel)"
    }
}

public struct DisplayModeProfile: Codable, Equatable, Sendable, Identifiable {
    public let modeID: UInt32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isUsable: Bool

    public init(
        modeID: UInt32,
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        isUsable: Bool
    ) {
        self.modeID = modeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isUsable = isUsable
    }

    public var id: UInt32 { modeID }

    public var aspectRatio: DisplayAspectRatio? {
        DisplayAspectRatio.classify(width: width, height: height)
    }

    public var label: String {
        let rate = refreshRate > 0 ? String(format: "%.0f", refreshRate) : String(localized: "Variable")
        return "\(width)×\(height) · \(rate) Hz"
    }

    public var detailedLabel: String {
        let ratio = aspectRatio?.title ?? String(localized: "Custom ratio")
        if pixelWidth == width, pixelHeight == height {
            return "\(label) · \(ratio)"
        }
        return "\(label) · \(ratio) · \(pixelWidth)×\(pixelHeight) pixels"
    }
}

public enum DisplayProfileSelector {
    public static let minimumCustomDimension = 640
    public static let maximumCustomDimension = 8_192

    public static func agentMode(
        in modes: [DisplayModeProfile],
        targetWidth: Int = 1_920,
        targetHeight: Int = 1_080,
        targetRefreshRate: Double = 60
    ) -> DisplayModeProfile? {
        guard targetWidth > 0, targetHeight > 0, targetRefreshRate > 0 else {
            return nil
        }

        return validModes(modes).min { lhs, rhs in
            let leftScore = agentScore(
                lhs,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                targetRefreshRate: targetRefreshRate
            )
            let rightScore = agentScore(
                rhs,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                targetRefreshRate: targetRefreshRate
            )
            if leftScore == rightScore {
                return lhs.modeID < rhs.modeID
            }
            return leftScore < rightScore
        }
    }

    public static func ownerMode(
        matching saved: DisplayModeProfile,
        in modes: [DisplayModeProfile]
    ) -> DisplayModeProfile? {
        modes.first(where: { $0.isUsable && $0.modeID == saved.modeID })
    }

    public static func mode(
        for aspectRatio: DisplayAspectRatio,
        in modes: [DisplayModeProfile]
    ) -> DisplayModeProfile? {
        let target = aspectRatio.targetDimensions
        return agentMode(
            in: validModes(modes).filter { $0.aspectRatio == aspectRatio },
            targetWidth: target.width,
            targetHeight: target.height
        )
    }

    public static func resolutionPresets(
        in modes: [DisplayModeProfile]
    ) -> [DisplayResolutionPreset] {
        let landscape = DisplayAspectRatio.standardLandscape.map { aspectRatio in
            DisplayResolutionPreset(
                aspectRatio: aspectRatio,
                mode: mode(for: aspectRatio, in: modes)
            )
        }
        let portrait: [DisplayResolutionPreset] = DisplayAspectRatio.standardPortrait.compactMap {
            aspectRatio -> DisplayResolutionPreset? in
            guard let selectedMode = Self.mode(
                for: aspectRatio,
                in: modes
            ) else {
                return nil
            }
            return DisplayResolutionPreset(
                aspectRatio: aspectRatio,
                mode: selectedMode
            )
        }
        return landscape + portrait
    }

    public static func customDimensionsAreValid(width: Int, height: Int) -> Bool {
        (minimumCustomDimension...maximumCustomDimension).contains(width)
            && (minimumCustomDimension...maximumCustomDimension).contains(height)
    }

    public static func customMode(
        width: Int,
        height: Int,
        in modes: [DisplayModeProfile]
    ) -> DisplayModeProfile? {
        guard customDimensionsAreValid(width: width, height: height) else {
            return nil
        }
        return agentMode(
            in: validModes(modes).filter {
                $0.width == width && $0.height == height
            },
            targetWidth: width,
            targetHeight: height
        )
    }

    private static func validModes(
        _ modes: [DisplayModeProfile]
    ) -> [DisplayModeProfile] {
        modes.filter {
            $0.isUsable
                && $0.width > 0
                && $0.height > 0
                && $0.pixelWidth > 0
                && $0.pixelHeight > 0
                && $0.pixelWidth <= maximumCustomDimension
                && $0.pixelHeight <= maximumCustomDimension
                && $0.refreshRate >= 0
        }
    }

    private static func agentScore(
        _ mode: DisplayModeProfile,
        targetWidth: Int,
        targetHeight: Int,
        targetRefreshRate: Double
    ) -> Double {
        let widthDifference = abs(Double(mode.width - targetWidth)) / Double(targetWidth)
        let heightDifference = abs(Double(mode.height - targetHeight)) / Double(targetHeight)
        let effectiveRate = mode.refreshRate > 0 ? mode.refreshRate : targetRefreshRate
        let rateDifference = abs(effectiveRate - targetRefreshRate) / targetRefreshRate
        let pixelWidthOverhead = max(0, Double(mode.pixelWidth - targetWidth)) / Double(targetWidth)
        let pixelHeightOverhead = max(0, Double(mode.pixelHeight - targetHeight)) / Double(targetHeight)
        let lowRefreshPenalty = effectiveRate < 50 ? 10.0 : 0

        return widthDifference
            + heightDifference
            + (rateDifference * 0.2)
            + ((pixelWidthOverhead + pixelHeightOverhead) * 0.01)
            + lowRefreshPenalty
    }
}
