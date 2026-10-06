import Foundation
import Testing
@testable import HermesCaptureProtocol

/// The phone asks for `assistantDefaults` when it pairs. Every gate between the
/// request and the live session must accept that set, and still refuse secrets.
struct AssistantCapabilityApprovalTests {
    @Test func stateMachineApprovesTheAssistantSet() throws {
        var machine = PeerSessionStateMachine()
        try machine.handle(.connectionEstablished)
        try machine.handle(.peerAuthenticated)
        try machine.handle(.approved(capabilities: SessionCapability.assistantDefaults))

        #expect(machine.state == .active)
        #expect(machine.capabilities.contains(.runAgentActions))
    }

    @Test func stateMachineStillRefusesSecrets() throws {
        var machine = PeerSessionStateMachine()
        try machine.handle(.connectionEstablished)
        try machine.handle(.peerAuthenticated)

        #expect(throws: PeerSessionError.self) {
            try machine.handle(.approved(capabilities: [.viewScreen, .enterSecrets]))
        }
    }

    @Test func reconnectAutoApprovesAnUnchangedAssistantSet() throws {
        let decision = try ReconnectCapabilityDecision.evaluate(
            requested: SessionCapability.assistantDefaults,
            approved: SessionCapability.assistantDefaults
        )
        #expect(decision == .autoApprove)

        let narrowed = try ReconnectCapabilityDecision.evaluate(
            requested: SessionCapability.assistantDefaults,
            approved: SessionCapability.phaseOneDefaults
        )
        #expect(narrowed == .requiresApproval)
    }
}
