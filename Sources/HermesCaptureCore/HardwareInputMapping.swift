import Foundation

/// macOS virtual key codes for the USB HID keyboard usages (page 0x07) that an iPhone or iPad keyboard reports, so a
/// hardware keyboard types on the Mac by key position, as the Mac's own keyboard would with the same layout.
public enum HardwareKeyMap {
    /// The macOS virtual key code for a HID keyboard usage, or nil for keys the Mac has no equivalent for.
    public static func macKeyCode(forHIDUsage usage: Int) -> UInt16? { table[usage] }

    /// The modifier keys themselves (control, shift, option, command, left and right); they travel as flags.
    public static func isModifier(hidUsage usage: Int) -> Bool { (0xE0...0xE7).contains(usage) }

    static let table: [Int: UInt16] = [
        // a to z
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4, 0x0C: 34, 0x0D: 38,
        0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15, 0x16: 1, 0x17: 17,
        0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        // 1 to 9, then 0
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        0x28: 36,  // return
        0x29: 53,  // escape
        0x2A: 51,  // delete
        0x2B: 48,  // tab
        0x2C: 49,  // space
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,  // - = [ ] backslash
        0x32: 42,  // the ISO key beside return, which macOS reports as backslash
        0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44,  // ; ' ` , . /
        0x39: 57,  // caps lock
        // F1 to F12
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100, 0x42: 101,
        0x43: 109, 0x44: 103, 0x45: 111,
        0x49: 114,  // insert, the Mac's help key
        0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121,  // home, page up, forward delete, end, page down
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,  // right, left, down, up
        // keypad
        0x53: 71, 0x54: 75, 0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76,  // clear / * - + enter
        0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87, 0x5E: 88, 0x5F: 89, 0x60: 91, 0x61: 92, 0x62: 82,
        0x63: 65,  // keypad .
        0x64: 10,  // the ISO key beside left shift
        0x67: 81,  // keypad =
        // F13 to F20
        0x68: 105, 0x69: 107, 0x6A: 113, 0x6B: 106, 0x6C: 64, 0x6D: 79, 0x6E: 80, 0x6F: 90,
    ]
}

/// A game controller thumbstick as pointer or scroll motion: a dead zone, then a curve that is fine near the centre
/// and fast at the edge, scaled by the frame's duration so the speed does not depend on the display's refresh rate.
public enum ThumbstickCurve {
    public static let deadZone = 0.12
    /// Mac display points per second at full deflection.
    public static let pointerTopSpeed = 1_500.0
    /// Scroll points per second at full deflection.
    public static let scrollTopSpeed = 1_800.0

    /// The stick's direction with its strength reshaped to 0...1 past the dead zone.
    public static func shaped(x: Double, y: Double) -> (x: Double, y: Double) {
        let magnitude = min(1, (x * x + y * y).squareRoot())
        guard magnitude > deadZone else { return (0, 0) }
        let strength = (magnitude - deadZone) / (1 - deadZone)
        let curved = 0.3 * strength + 0.7 * strength * strength
        return (x / magnitude * curved, y / magnitude * curved)
    }

    /// Pointer travel for one frame. The stick's y grows upward, the screen's downward.
    public static func pointerDelta(x: Double, y: Double, seconds: Double) -> (dx: Double, dy: Double) {
        let s = shaped(x: x, y: y)
        return (s.x * pointerTopSpeed * seconds, -s.y * pointerTopSpeed * seconds)
    }

    /// Scroll for one frame, in the sense of a finger: pushing up scrolls toward the top of the page.
    public static func scrollDelta(x: Double, y: Double, seconds: Double) -> (dx: Double, dy: Double) {
        let s = shaped(x: x, y: y)
        return (-s.x * scrollTopSpeed * seconds, s.y * scrollTopSpeed * seconds)
    }
}
