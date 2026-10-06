import AppKit
import ApplicationServices
import CoreGraphics
import HermesCaptureCore

struct AccessibilityTargetProvider {
    enum ProviderError: Error {
        case accessibilityPermissionDenied
        case noFrontmostApplication
        case invalidDisplay
    }

    let maximumElements = 2_000

    func targets(
        displayID: CGDirectDisplayID,
        frameSequence: UInt64,
        monotonicTimestampNanoseconds: UInt64
    ) throws -> [TargetCandidate] {
        guard AXIsProcessTrusted() else { throw ProviderError.accessibilityPermissionDenied }
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw ProviderError.noFrontmostApplication
        }
        let displayBounds = CGDisplayBounds(displayID)
        guard !displayBounds.isEmpty else { throw ProviderError.invalidDisplay }

        let application = AXUIElementCreateApplication(processIdentifier)
        var queue: [AXUIElement] = [application]
        var index = 0
        var candidates: [TargetCandidate] = []

        while index < queue.count, index < maximumElements {
            let element = queue[index]
            index += 1
            queue.append(contentsOf: children(of: element))
            guard let raw = rawTarget(from: element),
                  let sanitized = AccessibilityTargetSanitizer.sanitize(raw),
                  let bounds = normalized(sanitized.bounds, within: displayBounds),
                  let candidate = try? TargetCandidate.validated(
                    stableIdentifier: sanitized.stableIdentifier,
                    bounds: bounds,
                    label: sanitized.label,
                    role: sanitized.role,
                    source: .accessibility,
                    frameSequence: frameSequence,
                    monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
                    confidence: 1,
                    isEnabled: sanitized.isEnabled,
                    isSensitive: false
                  ) else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    private func rawTarget(from element: AXUIElement) -> AccessibilityRawTarget? {
        guard let role: String = attribute(kAXRoleAttribute, from: element),
              let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else { return nil }
        let enabled: Bool = attribute(kAXEnabledAttribute, from: element) ?? true
        return AccessibilityRawTarget(
            role: role,
            subrole: attribute(kAXSubroleAttribute, from: element),
            label: attribute(kAXDescriptionAttribute, from: element),
            title: attribute(kAXTitleAttribute, from: element),
            value: nil,
            isEnabled: enabled,
            bounds: .init(x: position.x, y: position.y, width: size.width, height: size.height)
        )
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, from: element) ?? []
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        guard let value: AXValue = attribute(name, from: element), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        guard let value: AXValue = attribute(name, from: element), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func normalized(_ bounds: ScreenTargetBounds, within display: CGRect) -> NormalizedTargetBounds? {
        let intersection = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height).intersection(display)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        let normalized = NormalizedTargetBounds(
            x: (intersection.minX - display.minX) / display.width,
            y: (intersection.minY - display.minY) / display.height,
            width: intersection.width / display.width,
            height: intersection.height / display.height
        )
        return normalized.isValid ? normalized : nil
    }
}
