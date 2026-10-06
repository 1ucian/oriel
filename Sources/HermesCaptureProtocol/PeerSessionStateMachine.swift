import Foundation

public enum PeerSessionError: Error, Equatable, Sendable {
    case invalidTransition
    case controlNotAuthorized
    case capabilityDenied
    case invalidPeerKey
    case invalidPairingNonce
    case payloadTooLarge
    case invalidPacket
    case replayedPacket
    case authenticationFailed
}

public enum PeerSessionState: Equatable, Sendable {
    case idle
    case authenticating
    case awaitingApproval
    case active
    case stale
    case reconnecting
    case closed
}

public enum PeerSessionEvent: Equatable, Sendable {
    case connectionEstablished
    case peerAuthenticated
    case approved(capabilities: Set<SessionCapability>)
    case controlReceived
    case heartbeatReceived
    case heartbeatTimedOut
    case reconnectStarted
    case revoked
    case closed

    var isApproval: Bool {
        if case .approved = self { return true }
        return false
    }
}

public struct PeerSessionStateMachine: Sendable {
    public private(set) var state: PeerSessionState = .idle
    public private(set) var capabilities: Set<SessionCapability> = []

    public init() {}

    public mutating func handle(_ event: PeerSessionEvent) throws {
        switch event {
        case .connectionEstablished where state == .idle || state == .reconnecting:
            state = .authenticating
        case .peerAuthenticated where state == .authenticating:
            state = .awaitingApproval
        case let .approved(capabilities) where state == .awaitingApproval:
            guard !capabilities.isEmpty,
                  capabilities.isSubset(of: SessionCapability.approvable) else {
                throw PeerSessionError.capabilityDenied
            }
            self.capabilities = capabilities
            state = .active
        case .controlReceived:
            guard state == .active else {
                if state == .awaitingApproval {
                    throw PeerSessionError.controlNotAuthorized
                }
                throw PeerSessionError.invalidTransition
            }
        case .heartbeatReceived where state == .active:
            break
        case .heartbeatReceived where state == .stale:
            state = .active
        case .heartbeatTimedOut where state == .active:
            state = .stale
        case .reconnectStarted where state == .stale:
            state = .reconnecting
        case .revoked, .closed:
            capabilities = []
            state = .closed
        default:
            throw PeerSessionError.invalidTransition
        }
    }
}
