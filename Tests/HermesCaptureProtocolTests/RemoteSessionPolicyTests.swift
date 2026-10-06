import Testing
@testable import HermesCaptureProtocol

struct RemoteSessionPolicyTests {
    @Test func newSessionRequiresExplicitApproval() throws {
        var policy = RemoteSessionPolicy()
        let request = SessionApprovalRequest(sessionID: "s1", deviceID: "d1", deviceName: "Alex’s iPhone", requestedCapabilities: [.viewScreen, .controlPointer], expiresAtNanoseconds: 2_000)
        policy.register(request)
        #expect(throws: SessionPolicyError.approvalRequired) {
            try policy.authorize(.pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)), sessionID: "s1", nowNanoseconds: 1_000)
        }
        try policy.approve(sessionID: "s1", capabilities: [.viewScreen, .controlPointer], nowNanoseconds: 1_000)
        #expect(throws: Never.self) {
            try policy.authorize(.pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)), sessionID: "s1", nowNanoseconds: 1_100)
        }
    }

    @Test func stopControlAndRevocationDenyBeforeInputAuthorization() throws {
        var policy = RemoteSessionPolicy()
        let request = SessionApprovalRequest(sessionID: "s1", deviceID: "d1", deviceName: "Phone", requestedCapabilities: [.controlPointer], expiresAtNanoseconds: 5_000)
        policy.register(request)
        try policy.approve(sessionID: "s1", capabilities: [.controlPointer], nowNanoseconds: 1_000)
        policy.stopControl()
        #expect(throws: SessionPolicyError.killSwitchActive) {
            try policy.authorize(.pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)), sessionID: "s1", nowNanoseconds: 1_100)
        }
        policy.resumeAcceptingNewSessions()
        policy.revoke(deviceID: "d1")
        #expect(throws: SessionPolicyError.deviceRevoked) {
            try policy.authorize(.pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)), sessionID: "s1", nowNanoseconds: 1_200)
        }
    }

    @Test func expiredSessionAndCapabilityEscalationAreDenied() throws {
        var policy = RemoteSessionPolicy(maximumInactivityNanoseconds: 500)
        let request = SessionApprovalRequest(sessionID: "s1", deviceID: "d1", deviceName: "Phone", requestedCapabilities: [.controlPointer, .typeText], expiresAtNanoseconds: 5_000)
        policy.register(request)
        try policy.approve(sessionID: "s1", capabilities: [.controlPointer], nowNanoseconds: 1_000)
        #expect(throws: SessionPolicyError.capabilityDenied) {
            try policy.authorize(try .text("no"), sessionID: "s1", nowNanoseconds: 1_100)
        }
        #expect(throws: SessionPolicyError.sessionExpired) {
            try policy.authorize(.pointerMove(try NormalizedPoint(x: 0.5, y: 0.5)), sessionID: "s1", nowNanoseconds: 1_501)
        }
    }
}
