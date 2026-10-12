public enum SessionPolicyError: Error, Equatable, Sendable {
    case unknownSession
    case approvalRequired
    case approvalExceedsRequest
    case sessionExpired
    case deviceRevoked
    case killSwitchActive
    case capabilityDenied
}

public struct SessionApprovalRequest: Equatable, Sendable {
    public let sessionID: String
    public let deviceID: String
    public let deviceName: String
    public let requestedCapabilities: Set<SessionCapability>
    public let expiresAtNanoseconds: UInt64

    public init(
        sessionID: String,
        deviceID: String,
        deviceName: String,
        requestedCapabilities: Set<SessionCapability>,
        expiresAtNanoseconds: UInt64
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.requestedCapabilities = requestedCapabilities
        self.expiresAtNanoseconds = expiresAtNanoseconds
    }
}

public struct ApprovedRemoteSession: Equatable, Sendable {
    public let request: SessionApprovalRequest
    public let approvedCapabilities: Set<SessionCapability>
    public var lastActivityNanoseconds: UInt64
}

public struct RemoteSessionPolicy: Sendable {
    public let maximumInactivityNanoseconds: UInt64
    public private(set) var isKillSwitchActive = false
    public private(set) var revokedDeviceIDs: Set<String> = []
    private var revokedSessionIDs: Set<String> = []
    private var requests: [String: SessionApprovalRequest] = [:]
    private var approvedSessions: [String: ApprovedRemoteSession] = [:]

    public init(maximumInactivityNanoseconds: UInt64 = 15 * 60 * 1_000_000_000) {
        self.maximumInactivityNanoseconds = maximumInactivityNanoseconds
    }

    public mutating func register(_ request: SessionApprovalRequest) {
        guard !revokedDeviceIDs.contains(request.deviceID), !isKillSwitchActive else { return }
        requests[request.sessionID] = request
    }

    public mutating func approve(
        sessionID: String,
        capabilities: Set<SessionCapability>,
        nowNanoseconds: UInt64
    ) throws {
        guard !isKillSwitchActive else { throw SessionPolicyError.killSwitchActive }
        guard !revokedSessionIDs.contains(sessionID) else { throw SessionPolicyError.deviceRevoked }
        guard let request = requests[sessionID] else { throw SessionPolicyError.unknownSession }
        guard !revokedDeviceIDs.contains(request.deviceID) else { throw SessionPolicyError.deviceRevoked }
        guard capabilities.isSubset(of: request.requestedCapabilities) else {
            throw SessionPolicyError.approvalExceedsRequest
        }
        guard nowNanoseconds <= request.expiresAtNanoseconds else { throw SessionPolicyError.sessionExpired }
        approvedSessions[sessionID] = ApprovedRemoteSession(
            request: request,
            approvedCapabilities: capabilities,
            lastActivityNanoseconds: nowNanoseconds
        )
    }

    public mutating func authorize(
        _ event: RemoteInputEvent,
        sessionID: String,
        nowNanoseconds: UInt64
    ) throws {
        guard !isKillSwitchActive else { throw SessionPolicyError.killSwitchActive }
        guard !revokedSessionIDs.contains(sessionID) else { throw SessionPolicyError.deviceRevoked }
        guard let request = requests[sessionID] else { throw SessionPolicyError.unknownSession }
        guard !revokedDeviceIDs.contains(request.deviceID) else { throw SessionPolicyError.deviceRevoked }
        guard var session = approvedSessions[sessionID] else { throw SessionPolicyError.approvalRequired }
        guard nowNanoseconds <= request.expiresAtNanoseconds,
              nowNanoseconds >= session.lastActivityNanoseconds,
              nowNanoseconds - session.lastActivityNanoseconds <= maximumInactivityNanoseconds else {
            approvedSessions.removeValue(forKey: sessionID)
            throw SessionPolicyError.sessionExpired
        }
        do {
            try InputAuthorizationPolicy.authorize(event, capabilities: session.approvedCapabilities)
        } catch {
            throw SessionPolicyError.capabilityDenied
        }
        session.lastActivityNanoseconds = nowNanoseconds
        approvedSessions[sessionID] = session
    }

    public mutating func stopControl() {
        isKillSwitchActive = true
        revokedSessionIDs.formUnion(requests.keys)
        approvedSessions.removeAll()
        requests.removeAll()
    }

    public mutating func resumeAcceptingNewSessions() {
        isKillSwitchActive = false
    }

    public mutating func revoke(deviceID: String) {
        revokedDeviceIDs.insert(deviceID)
        revokedSessionIDs.formUnion(requests.values.filter { $0.deviceID == deviceID }.map(\.sessionID))
        requests = requests.filter { $0.value.deviceID != deviceID }
        approvedSessions = approvedSessions.filter { $0.value.request.deviceID != deviceID }
    }

    /// The owner approved a revoked device again, after a new pairing: its new sessions may
    /// register. The sessions revoked with it stay revoked.
    public mutating func readmit(deviceID: String) {
        revokedDeviceIDs.remove(deviceID)
    }

    public func approvedSession(id: String) -> ApprovedRemoteSession? {
        approvedSessions[id]
    }

    public var activeSessions: [ApprovedRemoteSession] {
        approvedSessions.values.sorted { $0.request.sessionID < $1.request.sessionID }
    }
}
