import Testing
@testable import HermesCaptureProtocol

struct InputAuthorizationPolicyTests {
    @Test func pointerRequiresPointerCapability() throws {
        let event = RemoteInputEvent.pointerMove(
            try NormalizedPoint(x: 0.5, y: 0.5)
        )

        #expect(throws: InputAuthorizationError.capabilityDenied) {
            try InputAuthorizationPolicy.authorize(event, capabilities: [.viewScreen])
        }
        #expect(throws: Never.self) {
            try InputAuthorizationPolicy.authorize(event, capabilities: [.controlPointer])
        }
    }

    @Test func textRequiresTextCapability() throws {
        let event = try RemoteInputEvent.text("hello")

        #expect(throws: InputAuthorizationError.capabilityDenied) {
            try InputAuthorizationPolicy.authorize(event, capabilities: [.controlPointer])
        }
        #expect(throws: Never.self) {
            try InputAuthorizationPolicy.authorize(event, capabilities: [.typeText])
        }
    }
}
