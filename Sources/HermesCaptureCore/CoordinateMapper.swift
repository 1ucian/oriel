import CoreGraphics

public struct CoordinateMapper: Sendable {
    public let displaySize: CGSize
    public let viewportSize: CGSize

    public init(displaySize: CGSize, viewportSize: CGSize) {
        self.displaySize = displaySize
        self.viewportSize = viewportSize
    }

    public func displayPoint(forViewportPoint point: CGPoint) -> CGPoint? {
        guard displaySize.width > 0,
              displaySize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return nil
        }

        let scale = min(
            viewportSize.width / displaySize.width,
            viewportSize.height / displaySize.height
        )
        let renderedSize = CGSize(
            width: displaySize.width * scale,
            height: displaySize.height * scale
        )
        let origin = CGPoint(
            x: (viewportSize.width - renderedSize.width) / 2,
            y: (viewportSize.height - renderedSize.height) / 2
        )
        let renderedRect = CGRect(origin: origin, size: renderedSize)

        guard renderedRect.contains(point) else {
            return nil
        }

        return CGPoint(
            x: (point.x - origin.x) / scale,
            y: (point.y - origin.y) / scale
        )
    }
}
