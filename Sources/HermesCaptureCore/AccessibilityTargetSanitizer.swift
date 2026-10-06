import Foundation

public struct AccessibilityRawTarget: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let title: String?
    public let value: String?
    public let isEnabled: Bool
    public let isVisible: Bool
    public let bounds: ScreenTargetBounds

    public init(
        role: String,
        subrole: String?,
        label: String?,
        title: String?,
        value: String?,
        isEnabled: Bool,
        isVisible: Bool = true,
        bounds: ScreenTargetBounds
    ) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.bounds = bounds
    }
}

public struct ScreenTargetBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SanitizedAccessibilityTarget: Equatable, Sendable {
    public let stableIdentifier: String
    public let label: String
    public let role: TargetRole
    public let isEnabled: Bool
    public let bounds: ScreenTargetBounds
}

public enum AccessibilityTargetSanitizer {
    private static let secureTokens = ["secure", "password", "secret", "token", "otp", "one-time"]

    public static func sanitize(_ raw: AccessibilityRawTarget) -> SanitizedAccessibilityTarget? {
        guard raw.isVisible else { return nil }
        let roleMaterial = "\(raw.role) \(raw.subrole ?? "")".lowercased()
        guard !secureTokens.contains(where: roleMaterial.contains) else { return nil }
        guard raw.bounds.width > 0, raw.bounds.height > 0 else { return nil }

        // AXValue is intentionally never considered. It can contain typed or secret content.
        let safeLabel = [raw.label, raw.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let safeLabel else { return nil }

        let material = [raw.role, raw.subrole ?? "", safeLabel,
                        String(raw.bounds.x.rounded()), String(raw.bounds.y.rounded()),
                        String(raw.bounds.width.rounded()), String(raw.bounds.height.rounded())]
            .joined(separator: "|")
        return SanitizedAccessibilityTarget(
            stableIdentifier: stableHash(material),
            label: safeLabel,
            role: normalizedRole(raw.role),
            isEnabled: raw.isEnabled,
            bounds: raw.bounds
        )
    }

    private static func normalizedRole(_ role: String) -> TargetRole {
        switch role.lowercased() {
        case let value where value.contains("button"): .button
        case let value where value.contains("link"): .link
        case let value where value.contains("checkbox"): .checkbox
        case let value where value.contains("radio"): .radioButton
        case let value where value.contains("menuitem"): .menuItem
        case let value where value.contains("tab"): .tab
        case let value where value.contains("text"): .text
        case let value where value.contains("image"): .image
        default: .unknown
        }
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
