import CoreGraphics

public enum PointerControllerError: Error, Equatable, Sendable {
    case invalidDisplay
    case invalidViewport
}

public struct PointerController: Sendable {
    public private(set) var currentPoint: NormalizedPoint

    public init(
        initialPoint: NormalizedPoint = try! NormalizedPoint(x: 0.5, y: 0.5)
    ) throws {
        currentPoint = initialPoint
    }

    public mutating func absoluteMove(
        displayPoint: CGPoint,
        displaySize: CGSize
    ) throws -> RemoteInputEvent {
        guard displaySize.width > 0,
              displaySize.height > 0,
              displayPoint.x.isFinite,
              displayPoint.y.isFinite else {
            throw PointerControllerError.invalidDisplay
        }
        currentPoint = try NormalizedPoint(
            x: min(max(displayPoint.x / displaySize.width, 0), 1),
            y: min(max(displayPoint.y / displaySize.height, 0), 1)
        )
        return .pointerMove(currentPoint)
    }

    public mutating func relativeMove(
        translation: CGSize,
        viewportSize: CGSize,
        sensitivity: Double = 1
    ) throws -> RemoteInputEvent {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              translation.width.isFinite,
              translation.height.isFinite,
              sensitivity.isFinite,
              sensitivity > 0 else {
            throw PointerControllerError.invalidViewport
        }
        currentPoint = try NormalizedPoint(
            x: min(
                max(
                    currentPoint.x
                        + translation.width / viewportSize.width * sensitivity,
                    0
                ),
                1
            ),
            y: min(
                max(
                    currentPoint.y
                        + translation.height / viewportSize.height * sensitivity,
                    0
                ),
                1
            )
        )
        return .pointerMove(currentPoint)
    }
}
