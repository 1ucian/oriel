import Testing
@testable import HermesCaptureCore

struct CaptureCadenceTests {
    @Test func cadenceUsesExpectedFrameRates() {
        #expect(CaptureCadence.idle.framesPerSecond == 5)
        #expect(CaptureCadence.interactive.framesPerSecond == 30)
        #expect(CaptureCadence.highMotion.framesPerSecond == 60)
    }

    @Test func allCadencesProducePositiveFrameIntervals() {
        for cadence in CaptureCadence.allCases {
            #expect(cadence.frameIntervalNanoseconds > 0)
        }
    }
}
