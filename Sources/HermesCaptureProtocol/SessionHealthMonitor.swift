public struct SessionHealthMonitor: Sendable {
    public enum Health: Equatable, Sendable {
        case active
        case stale
        case closed
    }

    public let heartbeatIntervalNanoseconds: UInt64
    public let staleAfterNanoseconds: UInt64
    public let closeAfterNanoseconds: UInt64
    public private(set) var lastInboundNanoseconds: UInt64
    public private(set) var state: Health = .active

    public init(
        startedAtNanoseconds: UInt64,
        heartbeatIntervalNanoseconds: UInt64 = 2_000_000_000,
        staleAfterNanoseconds: UInt64 = 5_000_000_000,
        closeAfterNanoseconds: UInt64 = 15_000_000_000
    ) {
        precondition(heartbeatIntervalNanoseconds > 0)
        precondition(staleAfterNanoseconds > heartbeatIntervalNanoseconds)
        precondition(closeAfterNanoseconds > staleAfterNanoseconds)
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
        self.staleAfterNanoseconds = staleAfterNanoseconds
        self.closeAfterNanoseconds = closeAfterNanoseconds
        lastInboundNanoseconds = startedAtNanoseconds
    }

    public mutating func recordInbound(atNanoseconds timestamp: UInt64) {
        // A closed session requires explicit activation, not a delayed packet.
        guard state != .closed, timestamp >= lastInboundNanoseconds else { return }
        lastInboundNanoseconds = timestamp
        state = .active
    }

    public mutating func activate(atNanoseconds timestamp: UInt64) {
        lastInboundNanoseconds = timestamp
        state = .active
    }

    @discardableResult
    public mutating func evaluate(nowNanoseconds: UInt64) -> Health {
        guard state != .closed, nowNanoseconds >= lastInboundNanoseconds else { return state }
        let elapsed = nowNanoseconds - lastInboundNanoseconds
        if elapsed >= closeAfterNanoseconds {
            state = .closed
        } else if elapsed >= staleAfterNanoseconds {
            state = .stale
        } else {
            state = .active
        }
        return state
    }

    public func shouldSendHeartbeat(
        nowNanoseconds: UInt64,
        lastSentNanoseconds: UInt64
    ) -> Bool {
        guard nowNanoseconds >= lastSentNanoseconds else { return false }
        return nowNanoseconds - lastSentNanoseconds
            >= heartbeatIntervalNanoseconds
    }
}
