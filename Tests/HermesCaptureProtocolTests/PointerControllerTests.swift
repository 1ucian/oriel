import CoreGraphics
import Testing
@testable import HermesCaptureProtocol

struct PointerControllerTests {
    @Test func absolutePointNormalizesToDisplay() throws {
        var controller = try PointerController()
        let event = try controller.absoluteMove(
            displayPoint: CGPoint(x: 960, y: 540),
            displaySize: CGSize(width: 1920, height: 1080)
        )
        #expect(event == .pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)))
    }

    @Test func relativeMovementClampsToDisplayBounds() throws {
        var controller = try PointerController(
            initialPoint: NormalizedPoint(x: 0.95, y: 0.05)
        )
        let event = try controller.relativeMove(
            translation: CGSize(width: 200, height: -200),
            viewportSize: CGSize(width: 100, height: 100)
        )
        #expect(event == .pointerMove(try NormalizedPoint(x: 1, y: 0)))
    }

    @Test func relativeMovementRejectsInvalidViewport() throws {
        var controller = try PointerController()
        #expect(throws: PointerControllerError.invalidViewport) {
            try controller.relativeMove(
                translation: CGSize(width: 2, height: 2),
                viewportSize: .zero
            )
        }
    }
}
