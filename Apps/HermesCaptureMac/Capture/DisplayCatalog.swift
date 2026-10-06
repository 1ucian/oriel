import CoreGraphics
import ScreenCaptureKit

struct DisplayDescriptor: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
    let frame: CGRect
}

enum DisplayCatalog {
    static func displays() async throws -> [DisplayDescriptor] {
        let content = try await shareableContent()
        return content.displays.map {
            DisplayDescriptor(
                id: $0.displayID,
                width: $0.width,
                height: $0.height,
                frame: $0.frame
            )
        }
    }

    static func findDisplay(id: CGDirectDisplayID) async throws -> SCDisplay? {
        let content = try await shareableContent()
        return content.displays.first { $0.displayID == id }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }
}
