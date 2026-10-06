import Foundation
import FoundationModels

/// Apple's on-device foundation model (macOS 26, Apple Intelligence): nothing to download,
/// nothing on the network, loaded and unloaded by the system. Text only, with a 4,096-token
/// window for prompt and reply together, so long screen descriptions are cut to fit and the
/// executor's eyes stay a separate vision model.
struct AppleModelProvider: AssistantModelProvider {
    static let modelID = "apple-on-device"
    static let title = "Apple on-device"
    /// Characters, not tokens: a safe budget under the window with room for the reply.
    static let maximumPromptCharacters = 9_000
    static let fallbackPromptCharacters = 5_000
    static let tailCharacters = 300

    enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    var displayName: String { Self.title }

    static var availability: Availability {
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(describe(reason))
            }
        }
        return .unavailable("needs macOS 26 or later")
    }

    func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
        guard #available(macOS 26.0, *) else {
            throw AssistantModelProviderError.transport("Apple's on-device model needs macOS 26 or later")
        }
        if case let .unavailable(reason) = Self.availability {
            throw AssistantModelProviderError.transport("Apple's on-device model is unavailable: \(reason)")
        }
        let start = Date()
        let prompt = Self.prompt(from: request.messages, limit: Self.maximumPromptCharacters)
        let text: String
        do {
            text = try await Self.respond(system: request.system, prompt: prompt, request: request)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                let shorter = Self.prompt(from: request.messages, limit: Self.fallbackPromptCharacters)
                text = try await Self.respond(system: request.system, prompt: shorter, request: request)
            } else {
                throw AssistantModelProviderError.transport(Self.describe(error))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AssistantModelProviderError.emptyReply }
        return AssistantModelReply(
            text: trimmed,
            model: Self.modelID,
            latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    func listModels() async throws -> [String] {
        guard case .available = Self.availability else { return [] }
        return [Self.modelID]
    }

    /// The runtime sends the whole history each turn, so every call is a fresh session.
    @available(macOS 26.0, *)
    private static func respond(system: String, prompt: String, request: AssistantModelRequest) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: max(64, min(1_024, request.maxTokens))
        )
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch let error as LanguageModelSession.GenerationError {
            throw error
        } catch {
            throw AssistantModelProviderError.transport(String(describing: error))
        }
    }

    /// One prompt from the message list. When it is over the budget, the head (goal, sub-task,
    /// steps) and the tail (ids hint, reply instruction) stay; the middle of the screen
    /// description is what gets cut.
    static func prompt(from messages: [AssistantModelMessage], limit: Int) -> String {
        let text: String
        if messages.count == 1, let only = messages.first {
            text = only.text
        } else {
            text = messages.map { message in
                (message.role == .user ? "User: " : "Assistant: ") + message.text
            }.joined(separator: "\n\n")
        }
        guard text.count > limit else { return text }
        let tailKeep = min(tailCharacters, text.count)
        let headKeep = max(0, limit - tailKeep)
        let head = text.prefix(headKeep)
        let tail = text.suffix(tailKeep)
        return head + "\n…(screen description cut to fit the model)…\n" + tail
    }

    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "this Mac cannot run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "turn on Apple Intelligence in System Settings"
        case .modelNotReady: "the model is still downloading or preparing"
        @unknown default: "not available right now"
        }
    }

    @available(macOS 26.0, *)
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        if case .guardrailViolation = error {
            return "Apple's on-device model declined this request"
        }
        return "Apple's on-device model failed: \(error.localizedDescription)"
    }
}
