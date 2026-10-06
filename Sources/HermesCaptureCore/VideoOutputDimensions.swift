public enum VideoOutputDimensionsError: Error, Equatable, Sendable {
    case invalidDimensions
}

public struct VideoOutputDimensions: Equatable, Sendable {
    public static let networkMaximumWidth = 1_920
    public static let networkMaximumHeight = 1_080

    public let width: Int
    public let height: Int

    public static func networkAspectFit(
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> VideoOutputDimensions {
        try aspectFit(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            maximumWidth: networkMaximumWidth,
            maximumHeight: networkMaximumHeight
        )
    }

    public static func aspectFit(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumWidth: Int,
        maximumHeight: Int
    ) throws -> VideoOutputDimensions {
        guard sourceWidth >= 16,
              sourceHeight >= 16,
              maximumWidth >= 16,
              maximumHeight >= 16 else {
            throw VideoOutputDimensionsError.invalidDimensions
        }

        let scale = min(
            1,
            Double(maximumWidth) / Double(sourceWidth),
            Double(maximumHeight) / Double(sourceHeight)
        )
        let width = max(16, Int((Double(sourceWidth) * scale).rounded(.down)) & ~1)
        let height = max(16, Int((Double(sourceHeight) * scale).rounded(.down)) & ~1)

        return VideoOutputDimensions(width: width, height: height)
    }
}
