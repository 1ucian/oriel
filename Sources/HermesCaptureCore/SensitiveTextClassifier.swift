import Foundation

public enum SensitiveTextClassifier {
    private static let keywords = [
        "password", "passcode", "verification code", "one-time code", "one time code",
        "otp", "security code", "cvv", "card number", "social security", "secret", "recovery code"
    ]

    public static func isSensitive(_ text: String) -> Bool {
        let normalized = text.lowercased()
        if keywords.contains(where: normalized.contains) { return true }

        let digits = normalized.compactMap(\.wholeNumberValue)
        if digits.count == 6, normalized.allSatisfy({ $0.isNumber || $0.isWhitespace || $0.isPunctuation }) {
            return true
        }
        if (13...19).contains(digits.count) { return true }
        return false
    }
}
