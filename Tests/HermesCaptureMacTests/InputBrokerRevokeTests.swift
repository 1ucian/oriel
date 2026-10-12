import Foundation
import Testing
import HermesCaptureProtocol
@testable import HermesCaptureMac

/// Revoke on the Mac ends a phone's input at the broker, which every remote event passes first.
struct InputBrokerRevokeTests {
    @Test func revokedPhoneInputStopsAndItsNewSessionsWaitForTheOwner() async throws {
        let broker = InputBroker()
        let point = try NormalizedPoint(x: 0.5, y: 0.5)
        await broker.register(Self.session("s1", device: "phone"))
        try await broker.approve(sessionID: "s1", capabilities: [.controlPointer], nowNanoseconds: 1_000)

        await broker.revoke(deviceID: "phone")

        // Refused by the session policy, before any permission check or event.
        await #expect(throws: SessionPolicyError.deviceRevoked) {
            try await broker.execute(.pointerMove(point), sessionID: "s1", nowNanoseconds: 1_100, displayID: 0)
        }
        await broker.register(Self.session("s2", device: "phone"))
        await #expect(throws: SessionPolicyError.unknownSession) {
            try await broker.approve(sessionID: "s2", capabilities: [.controlPointer], nowNanoseconds: 1_200)
        }

        await broker.readmit(deviceID: "phone")
        await broker.register(Self.session("s3", device: "phone"))
        try await broker.approve(sessionID: "s3", capabilities: [.controlPointer], nowNanoseconds: 1_300)
    }

    private static func session(_ id: String, device: String) -> SessionApprovalRequest {
        SessionApprovalRequest(
            sessionID: id,
            deviceID: device,
            deviceName: "Phone",
            requestedCapabilities: [.controlPointer],
            expiresAtNanoseconds: 10_000
        )
    }
}
