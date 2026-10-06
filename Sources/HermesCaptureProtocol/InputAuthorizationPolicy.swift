public enum InputAuthorizationError: Error, Equatable, Sendable {
    case capabilityDenied
}

public enum InputAuthorizationPolicy {
    public static func authorize(
        _ event: RemoteInputEvent,
        capabilities: Set<SessionCapability>
    ) throws {
        let requiredCapability: SessionCapability
        switch event {
        case .pointerMove, .mouseButton, .scrollDelta:
            requiredCapability = .controlPointer
        case .key, .textInput:
            requiredCapability = .typeText
        }

        guard capabilities.contains(requiredCapability) else {
            throw InputAuthorizationError.capabilityDenied
        }
    }
}
