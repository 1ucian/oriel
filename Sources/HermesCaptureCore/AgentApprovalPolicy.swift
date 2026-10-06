import Foundation

/// The protected surfaces from the PRD (FR-8), decided on the Mac before any action reaches
/// the input broker: secrets and one-time codes, payments, permission and security dialogs,
/// CAPTCHA, destructive file and account actions, public sends and posts, medical-record
/// signing. A model never gets to argue with this.
public enum AgentActionKind: String, Sendable {
    case click
    case type
    case key
    case scroll
    case openApplication
    case wait
    case done
    case ask
}

public struct AgentActionContext: Equatable, Sendable {
    public let kind: AgentActionKind
    public let targetLabel: String?
    public let targetRole: String?
    public let targetIsSensitive: Bool
    public let text: String?
    public let keyName: String?
    public let modifiers: Set<String>
    public let frontmostBundleIdentifier: String?
    public let frontmostApplication: String?
    public let windowTitle: String?
    /// The focused text input, "role: label", when known.
    public let focusedField: String?
    /// The input would land in Oriel's own windows: its pairing approvals, codes and settings.
    public let landsOnOriel: Bool

    public init(
        kind: AgentActionKind,
        targetLabel: String? = nil,
        targetRole: String? = nil,
        targetIsSensitive: Bool = false,
        text: String? = nil,
        keyName: String? = nil,
        modifiers: Set<String> = [],
        frontmostBundleIdentifier: String? = nil,
        frontmostApplication: String? = nil,
        windowTitle: String? = nil,
        focusedField: String? = nil,
        landsOnOriel: Bool = false
    ) {
        self.focusedField = focusedField
        self.landsOnOriel = landsOnOriel
        self.kind = kind
        self.targetLabel = targetLabel
        self.targetRole = targetRole
        self.targetIsSensitive = targetIsSensitive
        self.text = text
        self.keyName = keyName
        self.modifiers = Set(modifiers.map { $0.lowercased() })
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.frontmostApplication = frontmostApplication
        self.windowTitle = windowTitle
    }

    /// The same action, known to land in Oriel's own windows.
    public func landingOnOriel() -> AgentActionContext {
        AgentActionContext(kind: kind, targetLabel: targetLabel, targetRole: targetRole, targetIsSensitive: targetIsSensitive,
                           text: text, keyName: keyName, modifiers: modifiers, frontmostBundleIdentifier: frontmostBundleIdentifier,
                           frontmostApplication: frontmostApplication, windowTitle: windowTitle, focusedField: focusedField,
                           landsOnOriel: true)
    }
}

public enum AgentApprovalDecision: Equatable, Sendable {
    case allow
    /// The phone's owner must approve this exact step.
    case requireApproval(reason: String)
    /// Never done by the assistant; the person does it at the Mac.
    case block(reason: String)
}

public enum AgentApprovalPolicy {
    /// System surfaces where every action is approved by the owner first.
    static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.apple.UserNotificationCenter",
        "com.apple.systempreferences",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.AuthKitAgent",
        "com.apple.CoreAuthUI",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.ScreenSaver.Engine",
        "com.apple.PasswordManager",
    ]

    static let blockedLabelTokens = [
        "captcha", "not a robot", "sign note", "sign chart", "sign encounter", "sign order",
        "attest", "e-sign", "esign", "sign and close", "sign & close", "sign the note",
        "one-time code", "verification code", "security code", "passcode", "password",
    ]

    static let approvalLabelTokens = [
        "pay", "purchase", "buy", "checkout", "check out", "place order", "order now", "subscribe",
        "send", "post", "publish", "share", "tweet", "reply all", "submit", "transfer", "wire",
        "delete", "remove", "erase", "empty trash", "uninstall", "format", "reset", "revoke",
        "confirm", "allow", "grant", "trust", "install", "accept", "agree", "authorize",
        "sign in", "log in", "login", "sign out", "log out", "unsubscribe", "cancel subscription",
        "deactivate", "close account", "quit",
        // A system permission prompt can float over the app in front, where only its text is
        // seen: answering it either way is the owner's call.
        "deny", "don't allow", "dont allow", "open system settings",
    ]

    /// Chat apps, where Return sends what was typed to other people.
    static let messagingBundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.apple.iChat",
        "com.microsoft.teams", "com.microsoft.teams2", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.facebook.archon",
    ]

    static func isMessagingApp(_ context: AgentActionContext) -> Bool {
        context.frontmostBundleIdentifier.map(messagingBundleIdentifiers.contains) ?? false
    }

    public static func isChatApp(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(messagingBundleIdentifiers.contains) ?? false
    }

    /// A search or jump box: Return there opens a result, it sends nothing.
    public static func isSearchField(_ focusedField: String?) -> Bool {
        guard let field = focusedField?.lowercased(), !field.isEmpty, !field.contains("message") else { return false }
        // Slack's jump box reports itself as "AXComboBox: Query"; combo boxes and search
        // fields are where people look things up, not where they write to someone.
        if field.hasPrefix("axcombobox") || field.hasPrefix("axsearchfield") { return true }
        return ["search", "query", "jump to", "find", "filter", "quick switcher", "go to"].contains { field.contains($0) }
    }

    static let protectedWindowTokens = [
        "checkout", "payment", "billing", "security & privacy", "privacy & security",
        "two-factor", "2fa", "verification", "sign in", "log in", "password",
    ]

    public static func evaluate(_ context: AgentActionContext) -> AgentApprovalDecision {
        switch context.kind {
        case .done, .ask, .wait:
            return .allow
        default:
            break
        }
        // Oriel's own windows hold pairing approvals, pairing codes and the model settings: an
        // assistant that could press them could let in another device or redirect itself.
        if context.landsOnOriel, context.kind != .openApplication {
            return .block(reason: "Oriel does not operate its own windows; pairing, approvals and settings stay with you.")
        }
        if let bundle = context.frontmostBundleIdentifier, bundle.hasPrefix("com.apple.loginwindow") {
            return .block(reason: "The lock screen is handled by you at the Mac.")
        }
        // System security and permission dialogs: the owner decides, step by step, from the
        // phone. Typing secrets into them is still refused below.
        if let bundle = context.frontmostBundleIdentifier,
           protectedBundleIdentifiers.contains(bundle) || bundle.hasPrefix("com.apple.SecurityAgent") {
            if context.kind == .type {
                if context.targetIsSensitive || (context.text.map(SensitiveTextClassifier.isSensitive) ?? false) {
                    return .block(reason: "Oriel never types a password or code into a system dialog.")
                }
            }
            let name = context.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "a system dialog"
            return .requireApproval(reason: "Acting on \(name) (system security or permission dialog) needs your approval.")
        }
        let label = (context.targetLabel ?? "").lowercased()
        let role = (context.targetRole ?? "").lowercased()
        let title = (context.windowTitle ?? "").lowercased()

        switch context.kind {
        case .type:
            if context.targetIsSensitive || role.contains("secure") {
                return .block(reason: "Oriel never types into secure fields.")
            }
            if let text = context.text, SensitiveTextClassifier.isSensitive(text) {
                return .block(reason: "That text looks like a password, code or card number. Enter it yourself.")
            }
            if blockedLabelTokens.contains(where: label.contains) {
                return .block(reason: "That field is a protected surface (\(context.targetLabel ?? "secure field")).")
            }
            if protectedWindowTokens.contains(where: title.contains) {
                return .requireApproval(reason: "Typing into a sign-in, payment or verification window.")
            }
            if isMessagingApp(context), !isSearchField(context.focusedField),
               let text = context.text, text.contains("\n") || text.contains("\r") {
                return .requireApproval(reason: "A line break in a chat app can send the message; it needs your approval.")
            }
            return .allow
        case .click:
            if context.targetIsSensitive {
                return .block(reason: "That control is a secure field.")
            }
            if blockedLabelTokens.contains(where: label.contains) {
                return .block(reason: "\"\(context.targetLabel ?? "")\" is a protected action that only you may take.")
            }
            if let token = approvalLabelTokens.first(where: { matches(label, $0) }) {
                return .requireApproval(reason: "Clicking \"\(context.targetLabel ?? token)\" needs your approval.")
            }
            if protectedWindowTokens.contains(where: title.contains) {
                return .requireApproval(reason: "Acting inside a sign-in, payment or verification window.")
            }
            return .allow
        case .key:
            let key = (context.keyName ?? "").lowercased()
            let command = context.modifiers.contains("command")
            if command, key == "q" { return .requireApproval(reason: "⌘Q quits the app.") }
            if command, key == "delete" || key == "backspace" {
                return .requireApproval(reason: "⌘Delete moves items to the Trash.")
            }
            if command, context.modifiers.contains("shift"), key == "delete" || key == "backspace" {
                return .requireApproval(reason: "Emptying the Trash needs your approval.")
            }
            if command, context.modifiers.contains("option"), key == "escape" {
                return .requireApproval(reason: "Force Quit needs your approval.")
            }
            if key == "return" || key == "enter" {
                if isMessagingApp(context), !isSearchField(context.focusedField) {
                    return .requireApproval(reason: "Return in a chat app can send a message; it needs your approval.")
                }
                if protectedWindowTokens.contains(where: title.contains) {
                    return .requireApproval(reason: "Confirming inside a sign-in, payment or verification window.")
                }
            }
            return .allow
        case .scroll, .openApplication:
            return .allow
        case .done, .ask, .wait:
            return .allow
        }
    }

    /// Whole-word match so "send" does not fire on "sender" or "Ascend".
    private static func matches(_ label: String, _ token: String) -> Bool {
        guard let range = label.range(of: token) else { return false }
        let before = range.lowerBound == label.startIndex ? nil : label[label.index(before: range.lowerBound)]
        let after = range.upperBound == label.endIndex ? nil : label[range.upperBound]
        func isBoundary(_ character: Character?) -> Bool {
            guard let character else { return true }
            return !(character.isLetter || character.isNumber)
        }
        return isBoundary(before) && isBoundary(after)
    }
}
