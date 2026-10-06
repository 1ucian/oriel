import Testing
@testable import HermesCaptureCore

struct ExternalPointerAttributionTests {
    @Test func externalSyntheticSourceIsVisible() {
        #expect(
            ExternalPointerAttribution.shouldShowIndicator(
                sourceProcessID: 42,
                currentProcessID: 7
            )
        )
    }

    @Test func currentApplicationSourceIsHidden() {
        #expect(
            !ExternalPointerAttribution.shouldShowIndicator(
                sourceProcessID: 7,
                currentProcessID: 7
            )
        )
    }

    @Test func HardwareSourceIsHidden() {
        #expect(
            !ExternalPointerAttribution.shouldShowIndicator(
                sourceProcessID: 0,
                currentProcessID: 7
            )
        )
    }
}
