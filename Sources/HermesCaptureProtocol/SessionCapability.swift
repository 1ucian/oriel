import Foundation

public enum SessionCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case viewScreen
    case controlPointer
    case typeText
    case readClipboard
    case writeClipboard
    case transferFiles
    case runAgentActions
    case enterSecrets
    case approveSensitiveAction

    public static let phaseOneDefaults: Set<Self> = [
        .viewScreen,
        .controlPointer,
        .typeText,
    ]

    /// Phase 1 plus the assistant: what a phone requests when pairing.
    public static let assistantDefaults: Set<Self> = phaseOneDefaults.union([.runAgentActions])

    /// Everything a session may be approved for. Secrets and remote approval of sensitive
    /// actions never travel; those stay with the person at the Mac.
    public static let approvable: Set<Self> = assistantDefaults
}
