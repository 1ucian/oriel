import Foundation
import Testing
@testable import HermesCaptureCore

struct HardwareInputMappingTests {
    @Test func lettersDigitsAndEditingKeysLandOnTheMacKeyForTheSamePosition() {
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x04) == 0)    // a
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x06) == 8)    // c
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x19) == 9)    // v
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x1D) == 6)    // z
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x1E) == 18)   // 1
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x27) == 29)   // 0
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x28) == 36)   // return
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x29) == 53)   // escape
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x2A) == 51)   // delete
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x2B) == 48)   // tab
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x2C) == 49)   // space
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x4C) == 117)  // forward delete
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x3A) == 122)  // F1
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x45) == 111)  // F12
    }

    @Test func arrowsMapToTheMacArrows() {
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x50) == 123)  // left
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x4F) == 124)  // right
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x51) == 125)  // down
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x52) == 126)  // up
    }

    @Test func everyLetterAndDigitHasAKeyAndNoTwoShareOne() {
        let codes = (0x04...0x27).compactMap(HardwareKeyMap.macKeyCode(forHIDUsage:))
        #expect(codes.count == 36)
        #expect(Set(codes).count == 36)
    }

    @Test func modifiersAreFlagsAndUnknownKeysAreDropped() {
        #expect((0xE0...0xE7).allSatisfy(HardwareKeyMap.isModifier(hidUsage:)))
        #expect(!HardwareKeyMap.isModifier(hidUsage: 0x04))
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0xE3) == nil)  // left command travels as a flag
        #expect(HardwareKeyMap.macKeyCode(forHIDUsage: 0x46) == nil)  // print screen has no Mac key
    }

    @Test func aStickInsideTheDeadZoneDoesNothing() {
        let still = ThumbstickCurve.pointerDelta(x: 0.08, y: -0.05, seconds: 1)
        #expect(still.dx == 0 && still.dy == 0)
    }

    @Test func fullDeflectionReachesTopSpeedAndKeepsDirection() {
        let right = ThumbstickCurve.pointerDelta(x: 1, y: 0, seconds: 0.5)
        #expect(abs(right.dx - ThumbstickCurve.pointerTopSpeed * 0.5) < 0.001)
        #expect(right.dy == 0)
        let up = ThumbstickCurve.pointerDelta(x: 0, y: 1, seconds: 1)
        #expect(up.dy < 0, "Pushing up moves the pointer up the screen")
        let scroll = ThumbstickCurve.scrollDelta(x: 0, y: 1, seconds: 1)
        #expect(scroll.dy > 0, "Pushing up scrolls toward the top, as a finger dragging down would")
    }

    @Test func theCurveIsGentleNearTheCentreAndGrowsSteadily() {
        let strengths = stride(from: 0.15, through: 1.0, by: 0.05).map { ThumbstickCurve.shaped(x: $0, y: 0).x }
        #expect(zip(strengths, strengths.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ThumbstickCurve.shaped(x: 0.3, y: 0).x < 0.3, "Small pushes move slowly for precise pointing")
    }
}
