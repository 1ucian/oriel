import Foundation
import Testing
@testable import HermesCaptureMac

struct AppleModelProviderTests {
    @Test func promptKeepsTheHeadAndTheTailWhenCut() {
        let head = String(repeating: "a", count: 6_000)
        let middle = String(repeating: "b", count: 6_000)
        let tail = "Reply with the next action as one JSON object."
        let messages = [AssistantModelMessage(role: .user, text: head + "\n" + middle + "\n" + tail)]

        let prompt = AppleModelProvider.prompt(from: messages, limit: 5_000)

        #expect(prompt.count <= 5_000 + 100)
        #expect(prompt.hasPrefix("aaaa"))
        #expect(prompt.hasSuffix(tail))
        #expect(prompt.contains("cut to fit"))
    }

    @Test func shortPromptsPassThroughUntouched() {
        let messages = [AssistantModelMessage(role: .user, text: "hello")]
        #expect(AppleModelProvider.prompt(from: messages, limit: 100) == "hello")
    }

    @Test func severalMessagesAreLabelledByRole() {
        let messages = [
            AssistantModelMessage(role: .user, text: "first"),
            AssistantModelMessage(role: .assistant, text: "{\"plan\":[]}"),
            AssistantModelMessage(role: .user, text: "second"),
        ]
        let prompt = AppleModelProvider.prompt(from: messages, limit: 1_000)
        #expect(prompt == "User: first\n\nAssistant: {\"plan\":[]}\n\nUser: second")
    }

    @Test func availabilityIsDecidedWithoutCrashing() {
        switch AppleModelProvider.availability {
        case .available:
            #expect(AppleModelProvider().displayName == AppleModelProvider.title)
        case let .unavailable(reason):
            #expect(!reason.isEmpty)
        }
    }

    @Test func appleKindRunsOnThisMacAndNeedsNoEndpoint() {
        let endpoint = AssistantEndpointSettings(kind: .appleOnDevice, baseURL: "", model: "")
        #expect(endpoint.resolvedModel == AppleModelProvider.modelID)
        #expect(endpoint.locality == .onThisMac)
        #expect(endpoint.resolvedBaseURL == nil)
        #expect(endpoint.displayName(role: "Executor") == "Executor Apple on-device · on this Mac")
    }
}
