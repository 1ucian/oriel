import AppKit
import Testing
@testable import HermesCaptureMac

struct OrielPointerGeometryTests {
    @Test func tipLandsAtTheQuartzPointOnTheMainDisplay() throws {
        // Quartz: top-left origin. AppKit: bottom-left origin. Same 1792×1120 display.
        let origin = try #require(OrielPointerGeometry.panelOrigin(
            tip: CGPoint(x: 100, y: 50),
            displayBounds: CGRect(x: 0, y: 0, width: 1792, height: 1120),
            screenFrame: NSRect(x: 0, y: 0, width: 1792, height: 1120),
            panelSize: CGSize(width: 56, height: 56),
            hotspot: CGPoint(x: 14, y: 12)
        ))
        #expect(origin.x == CGFloat(100 - 14))
        // The tip is 12 points below the panel's top; the panel's top is 50 points below the screen top.
        #expect(origin.y == CGFloat(1120 - 50 - (56 - 12)))
    }

    @Test func secondaryDisplaysOffsetByTheirOrigin() throws {
        let origin = try #require(OrielPointerGeometry.panelOrigin(
            tip: CGPoint(x: 2000, y: 100),
            displayBounds: CGRect(x: 1792, y: 0, width: 1440, height: 900),
            screenFrame: NSRect(x: 1792, y: 220, width: 1440, height: 900),
            panelSize: CGSize(width: 56, height: 56),
            hotspot: CGPoint(x: 14, y: 12)
        ))
        #expect(origin.x == CGFloat(1792 + (2000 - 1792) - 14))
        #expect(origin.y == CGFloat((220 + 900) - 100 - 44))
    }

    @Test func missingScreenGivesNoOrigin() {
        #expect(OrielPointerGeometry.panelOrigin(
            tip: .zero, displayBounds: .zero, screenFrame: nil,
            panelSize: CGSize(width: 56, height: 56), hotspot: .zero
        ) == nil)
    }
}
