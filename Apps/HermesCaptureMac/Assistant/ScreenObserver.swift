import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import ScreenCaptureKit
import Vision

struct ScreenObservationResult: Sendable {
    let observation: AgentObservation
    /// Present only when the caller asked for it and the sharing policy allowed it.
    let screenshotJPEG: Data?
    let frameSequence: UInt64
}

/// Reads the Mac's own screen for one assistant step, on the Mac: the accessibility tree,
/// on-device OCR, and shape detection when an app exposes no controls. A downscaled JPEG is
/// produced only when asked.
@MainActor
final class ScreenObserver {
    static let ocrMaximumWidth: CGFloat = 1_600
    static let screenshotMaximumWidth: CGFloat = 1_280
    static let screenshotQuality: CGFloat = 0.55

    private let accessibility = AccessibilityTargetProvider()
    private let ocr = VisionTextProvider()
    private let shapes = VisionShapeProvider()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func observe(
        frame: CaptureFrame?,
        displayID: CGDirectDisplayID,
        includeScreenshot: Bool,
        includeShapes: Bool
    ) async throws -> ScreenObservationResult {
        let now = DispatchTime.now().uptimeNanoseconds
        let sequence = frame?.metadata.sequence ?? 0
        let bounds = CGDisplayBounds(displayID)

        var candidates = (try? accessibility.targets(
            displayID: displayID, frameSequence: sequence, monotonicTimestampNanoseconds: now
        )) ?? []

        var image = frame.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
        if image == nil { image = await Self.captureOnce(displayID: displayID) }
        var screenshot: Data?
        if let image {
            let ocrImage = scaled(image, maximumWidth: Self.ocrMaximumWidth)
            if let cgImage = context.createCGImage(ocrImage, from: ocrImage.extent) {
                let ocr = self.ocr
                let shapes = self.shapes
                let wantShapes = includeShapes || candidates.filter { $0.role != .text }.count < 3
                let detected: [TargetCandidate] = await Task.detached(priority: .userInitiated) {
                    var found = (try? ocr.targets(in: cgImage, frameSequence: sequence, monotonicTimestampNanoseconds: now)) ?? []
                    if wantShapes {
                        found += (try? shapes.regions(in: cgImage, frameSequence: sequence, monotonicTimestampNanoseconds: now)) ?? []
                    }
                    return found
                }.value
                candidates += detected
            }
            if includeScreenshot {
                let small = scaled(image, maximumWidth: Self.screenshotMaximumWidth)
                screenshot = context.jpegRepresentation(
                    of: small, colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Self.screenshotQuality]
                )
            }
        }

        let application = NSWorkspace.shared.frontmostApplication
        let pointer = pointerLocation(in: bounds)
        let observation = AgentObservation.make(
            candidates: candidates,
            frontmostApplication: application?.localizedName,
            frontmostBundleIdentifier: application?.bundleIdentifier,
            windowTitle: application.flatMap { focusedWindowTitle(processIdentifier: $0.processIdentifier) },
            displayWidth: Int(bounds.width),
            displayHeight: Int(bounds.height),
            pointerX: pointer?.x,
            pointerY: pointer?.y,
            capturedAtNanoseconds: now,
            focusedField: application.flatMap { focusedField(processIdentifier: $0.processIdentifier) }
        )
        return ScreenObservationResult(observation: observation, screenshotJPEG: screenshot, frameSequence: sequence)
    }

    /// One frame through ScreenCaptureKit when the session's stream has none yet.
    private static func captureOnce(displayID: CGDirectDisplayID) async -> CIImage? {
        guard let display = try? await DisplayCatalog.findDisplay(id: displayID) else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return CIImage(cgImage: image)
    }

    private func scaled(_ image: CIImage, maximumWidth: CGFloat) -> CIImage {
        let width = image.extent.width
        guard width > maximumWidth, width > 0 else { return image }
        let scale = maximumWidth / width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Cocoa reports the pointer from the bottom-left of the main display; displays are
    /// described from the top-left.
    private func pointerLocation(in bounds: CGRect) -> (x: Double, y: Double)? {
        guard !bounds.isEmpty else { return nil }
        let location = NSEvent.mouseLocation
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let point = CGPoint(x: location.x, y: mainHeight - location.y)
        guard bounds.contains(point) else { return nil }
        return ((point.x - bounds.minX) / bounds.width, (point.y - bounds.minY) / bounds.height)
    }

    /// The focused text input as "role: label", from its description, title or placeholder.
    private func focusedField(processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let element = focused as! AXUIElement
        func string(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let text = value as? String, !text.isEmpty else { return nil }
            return text
        }
        guard let role = string(kAXRoleAttribute as String),
              ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else { return nil }
        let label = string(kAXDescriptionAttribute as String) ?? string(kAXTitleAttribute as String)
            ?? string("AXPlaceholderValue") ?? string(kAXRoleDescriptionAttribute as String) ?? ""
        return "\(role): \(label.prefix(80))"
    }

    private func focusedWindowTitle(processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        let text = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? String(text!.prefix(120)) : nil
    }
}

/// Oriel's own windows, as the assistant's input would meet them.
@MainActor
enum OrielWindows {
    /// Whether input lands in one of Oriel's windows. A point goes to the topmost window under
    /// it, skipping Oriel's click-through overlays (the pointer panel) and invisible windows;
    /// keyboard input (no point) goes to Oriel when it is the active app or holds the key window.
    static func receiveInput(at point: HermesCaptureProtocol.NormalizedPoint?, displayID: CGDirectDisplayID) -> Bool {
        guard let point else { return NSApp.isActive || NSApp.keyWindow != nil }
        let bounds = CGDisplayBounds(displayID)
        let target = CGPoint(x: bounds.minX + point.x * bounds.width, y: bounds.minY + point.y * bounds.height)
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let clickThrough = Set(NSApp.windows.filter(\.ignoresMouseEvents).map(\.windowNumber))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        for window in windows {
            guard let frameInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: frameInfo as CFDictionary),
                  frame.contains(target) else { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 { continue }
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if owner == ownProcess {
                if let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue, clickThrough.contains(number) { continue }
                return true
            }
            return false
        }
        return false
    }
}

/// Shape detection for apps with no accessibility tree: contour bounding boxes of plausible
/// control size become "region" candidates the model can click by id.
struct VisionShapeProvider: Sendable {
    static let maximumRegions = 40

    func regions(
        in image: CGImage,
        frameSequence: UInt64,
        monotonicTimestampNanoseconds: UInt64
    ) throws -> [TargetCandidate] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.5
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 768
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { return [] }

        var boxes: [NormalizedTargetBounds] = []
        var queue = observation.topLevelContours
        var depth = 0
        while !queue.isEmpty, depth < 2, boxes.count < 400 {
            var next: [VNContour] = []
            for contour in queue {
                let box = contour.normalizedPath.boundingBox
                let area = box.width * box.height
                let aspect = box.height > 0 ? box.width / box.height : 0
                if (0.0004...0.2).contains(area), (0.08...25).contains(aspect) {
                    let normalized = NormalizedTargetBounds(
                        x: max(0, box.minX), y: max(0, 1 - box.maxY),
                        width: min(box.width, 1 - max(0, box.minX)), height: min(box.height, 1 - max(0, 1 - box.maxY))
                    )
                    if normalized.isValid, !boxes.contains(where: { $0.overlapRatio(with: normalized) > 0.85 }) {
                        boxes.append(normalized)
                    }
                }
                next += contour.childContours
            }
            queue = next
            depth += 1
        }

        return boxes
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(Self.maximumRegions)
            .enumerated()
            .compactMap { index, bounds in
                try? TargetCandidate.validated(
                    stableIdentifier: "shape:\(frameSequence):\(index)",
                    bounds: bounds,
                    label: "region",
                    role: .object,
                    source: .openCV,
                    frameSequence: frameSequence,
                    monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
                    confidence: 0.5,
                    isEnabled: true,
                    isSensitive: false
                )
            }
    }
}
