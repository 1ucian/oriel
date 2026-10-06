public enum DiscoveryState: String, Codable, Equatable, Sendable {
    case idle
    case advertising
    case browsing
    case peerAvailable
    case failed
}

public enum DiscoveryEvent: Sendable {
    case beginAdvertising
    case beginBrowsing
    case peerFound
    case fail
    case stop
}

public enum DiscoveryTransitionError: Error, Equatable, Sendable {
    case invalidTransition
}

public struct DiscoveryStateMachine: Sendable {
    public private(set) var state: DiscoveryState

    public init(state: DiscoveryState = .idle) {
        self.state = state
    }

    public mutating func apply(_ event: DiscoveryEvent) throws {
        switch (state, event) {
        case (.idle, .beginAdvertising):
            state = .advertising
        case (.idle, .beginBrowsing):
            state = .browsing
        case (.browsing, .peerFound):
            state = .peerAvailable
        case (.advertising, .fail), (.browsing, .fail), (.peerAvailable, .fail):
            state = .failed
        case (_, .stop):
            state = .idle
        default:
            throw DiscoveryTransitionError.invalidTransition
        }
    }
}
