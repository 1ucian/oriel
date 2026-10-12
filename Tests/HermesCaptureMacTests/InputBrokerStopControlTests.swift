import Foundation
import Testing
import HermesCaptureProtocol
@testable import HermesCaptureMac

/// Stop Control ends input at the broker the way Revoke does, without revoking the phone.
struct InputBrokerStopControlTests {
    @Test func stopControlEndsTypingInProgressButAResumedRunKeepsIt() async throws {
        let broker = InputBroker()
        await broker.register(Self.session("s1"))
        try await broker.approve(sessionID: "s1", capabilities: [.typeText], nowNanoseconds: 1_000)
        let ticket = await broker.typingTicket(sessionID: "s1")
        #expect(await broker.typingStopReason(ticket) == nil)

        // The same phone is back while its run goes on: what the run is typing carries on.
        await broker.stopControl(keepingRunInput: true)
        #expect(await broker.typingStopReason(ticket) == nil)

        await broker.stopControl()
        #expect(await broker.typingStopReason(ticket) == .killSwitchActive)
    }

    @Test func aRevokeEndsTypingInProgressOnlyForThatPhone() async throws {
        let broker = InputBroker()
        await broker.register(Self.session("s1"))
        try await broker.approve(sessionID: "s1", capabilities: [.typeText], nowNanoseconds: 1_000)
        let ticket = await broker.typingTicket(sessionID: "s1")

        await broker.revoke(deviceID: "another-phone")
        #expect(await broker.typingStopReason(ticket) == nil)
        await broker.revoke(deviceID: "phone")
        #expect(await broker.typingStopReason(ticket) == .deviceRevoked)
    }

    @Test func stopControlRefusesInputButKeepsThePhoneAdmitted() async throws {
        let broker = InputBroker()
        let point = try NormalizedPoint(x: 0.5, y: 0.5)
        await broker.register(Self.session("s1"))
        try await broker.approve(sessionID: "s1", capabilities: [.controlPointer], nowNanoseconds: 1_000)

        await broker.stopControl()

        // Refused by the session policy, before any permission check or event.
        await #expect(throws: SessionPolicyError.killSwitchActive) {
            try await broker.execute(.pointerMove(point), sessionID: "s1", nowNanoseconds: 1_100, displayID: 0)
        }
        // Unlike a revoke, the phone's next session is accepted once the Mac takes sessions again.
        await broker.resumeAcceptingNewSessions()
        await broker.register(Self.session("s2"))
        try await broker.approve(sessionID: "s2", capabilities: [.controlPointer], nowNanoseconds: 1_200)
        // The stopped session itself stays refused; the policy reports it as a revoked session.
        await #expect(throws: SessionPolicyError.deviceRevoked) {
            try await broker.execute(.pointerMove(point), sessionID: "s1", nowNanoseconds: 1_300, displayID: 0)
        }
    }

    private static func session(_ id: String) -> SessionApprovalRequest {
        SessionApprovalRequest(
            sessionID: id,
            deviceID: "phone",
            deviceName: "Phone",
            requestedCapabilities: [.controlPointer, .typeText],
            expiresAtNanoseconds: 10_000
        )
    }
}
