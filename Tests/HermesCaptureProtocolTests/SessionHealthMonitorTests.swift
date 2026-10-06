import Testing
@testable import HermesCaptureProtocol

struct SessionHealthMonitorTests {
    @Test func becomesStaleThenClosedWithoutInboundTraffic() {
        var monitor = SessionHealthMonitor(startedAtNanoseconds: 1_000)
        #expect(monitor.evaluate(nowNanoseconds: 5_000_000_000) == .active)
        #expect(monitor.evaluate(nowNanoseconds: 6_000_001_000) == .stale)
        #expect(monitor.evaluate(nowNanoseconds: 16_000_001_000) == .closed)
    }

    @Test func freshInboundTrafficRestoresActiveHealth() {
        var monitor = SessionHealthMonitor(startedAtNanoseconds: 1_000)
        #expect(monitor.evaluate(nowNanoseconds: 6_000_001_000) == .stale)
        monitor.recordInbound(atNanoseconds: 6_100_000_000)
        #expect(monitor.state == .active)
        #expect(monitor.evaluate(nowNanoseconds: 7_000_000_000) == .active)
    }

    @Test func lateInboundCannotReopenClosedSession() {
        var monitor = SessionHealthMonitor(startedAtNanoseconds: 0)
        #expect(monitor.evaluate(nowNanoseconds: 15_000_000_000) == .closed)
        monitor.recordInbound(atNanoseconds: 16_000_000_000)
        #expect(monitor.state == .closed)
        #expect(monitor.lastInboundNanoseconds == 0)
    }

    @Test func closedSessionStaysClosedOnEarlierEvaluation() {
        var monitor = SessionHealthMonitor(startedAtNanoseconds: 0)
        #expect(monitor.evaluate(nowNanoseconds: 15_000_000_000) == .closed)
        #expect(monitor.evaluate(nowNanoseconds: 1_000_000_000) == .closed)
    }

    @Test func heartbeatCadenceIsBounded() {
        let monitor = SessionHealthMonitor(startedAtNanoseconds: 0)
        #expect(!monitor.shouldSendHeartbeat(
            nowNanoseconds: 1_000_000_000,
            lastSentNanoseconds: 0
        ))
        #expect(monitor.shouldSendHeartbeat(
            nowNanoseconds: 2_000_000_000,
            lastSentNanoseconds: 0
        ))
    }

    @Test func activationStartsHealthWindowAtApprovalTime() {
        var monitor = SessionHealthMonitor(startedAtNanoseconds: 1_000)
        #expect(monitor.evaluate(nowNanoseconds: 16_000_001_000) == .closed)

        monitor.activate(atNanoseconds: 30_000_000_000)

        #expect(monitor.evaluate(nowNanoseconds: 34_999_999_999) == .active)
        #expect(monitor.evaluate(nowNanoseconds: 35_000_000_000) == .stale)
    }
}
