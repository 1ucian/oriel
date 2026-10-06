import Testing
@testable import HermesCaptureProtocol

struct DiscoveryStateMachineTests {
    @Test func advertiserStartsOnlyFromIdle() throws {
        var machine = DiscoveryStateMachine()

        try machine.apply(.beginAdvertising)
        #expect(machine.state == .advertising)

        #expect(throws: DiscoveryTransitionError.invalidTransition) {
            try machine.apply(.beginBrowsing)
        }
    }

    @Test func browserCanFindPeerThenStop() throws {
        var machine = DiscoveryStateMachine()

        try machine.apply(.beginBrowsing)
        try machine.apply(.peerFound)
        #expect(machine.state == .peerAvailable)
        try machine.apply(.stop)
        #expect(machine.state == .idle)
    }

    @Test func failureCanRecoverToIdle() throws {
        var machine = DiscoveryStateMachine()

        try machine.apply(.beginBrowsing)
        try machine.apply(.fail)
        #expect(machine.state == .failed)
        try machine.apply(.stop)
        #expect(machine.state == .idle)
    }
}
