import CoreGraphics
import Testing
@testable import HermesCaptureCore

struct CoordinateMapperTests {
    @Test func mapsAspectFitTouchIntoDisplayCoordinates() {
        let mapper = CoordinateMapper(
            displaySize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 390, height: 844)
        )

        let mapped = mapper.displayPoint(forViewportPoint: CGPoint(x: 195, y: 422))

        #expect(mapped != nil)
        #expect(abs(mapped!.x - 960) < 0.001)
        #expect(abs(mapped!.y - 540) < 0.001)
    }

    @Test func rejectsTouchesInLetterboxArea() {
        let mapper = CoordinateMapper(
            displaySize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 390, height: 844)
        )

        #expect(mapper.displayPoint(forViewportPoint: CGPoint(x: 195, y: 50)) == nil)
    }

    @Test func rejectsInvalidGeometry() {
        let mapper = CoordinateMapper(
            displaySize: .zero,
            viewportSize: CGSize(width: 390, height: 844)
        )

        #expect(mapper.displayPoint(forViewportPoint: CGPoint(x: 100, y: 100)) == nil)
    }
}
