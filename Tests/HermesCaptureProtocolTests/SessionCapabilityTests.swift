import Foundation
import Testing
@testable import HermesCaptureProtocol

struct SessionCapabilityTests {
    @Test func phaseOneDefaultsExcludeSensitiveCapabilities() {
        let capabilities = SessionCapability.phaseOneDefaults

        #expect(capabilities.contains(.viewScreen))
        #expect(capabilities.contains(.controlPointer))
        #expect(capabilities.contains(.typeText))
        #expect(!capabilities.contains(.enterSecrets))
        #expect(!capabilities.contains(.approveSensitiveAction))
        #expect(!capabilities.contains(.runAgentActions))
    }

    @Test func assistantDefaultsAddOnlyTheAssistant() {
        #expect(SessionCapability.assistantDefaults == SessionCapability.phaseOneDefaults.union([.runAgentActions]))
        #expect(SessionCapability.approvable == SessionCapability.assistantDefaults)
        #expect(!SessionCapability.approvable.contains(.enterSecrets))
    }

    @Test func capabilitiesRoundTripThroughJSON() throws {
        let original: Set<SessionCapability> = [.viewScreen, .controlPointer, .typeText]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Set<SessionCapability>.self, from: data)

        #expect(decoded == original)
    }
}
