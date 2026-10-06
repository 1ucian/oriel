import Testing
@testable import HermesCaptureCore

struct AdvertisementLifecyclePolicyTests {
    @Test func missingAdvertisementStartsNewListener() {
        let requested = AdvertisementIdentity(
            serviceName: "Studio-Mac",
            serviceType: "_orielreconnect._tcp"
        )

        #expect(
            AdvertisementLifecyclePolicy.decision(
                current: nil,
                requested: requested
            ) == .startNew
        )
    }

    @Test func identicalAdvertisementKeepsExistingListener() {
        let current = AdvertisementIdentity(
            serviceName: "Studio-Mac",
            serviceType: "_orielreconnect._tcp"
        )

        #expect(
            AdvertisementLifecyclePolicy.decision(
                current: current,
                requested: current
            ) == .keepExisting
        )
    }

    @Test func changedAdvertisementReplacesExistingListener() {
        let current = AdvertisementIdentity(
            serviceName: "Studio-Mac",
            serviceType: "_hermescapture._tcp"
        )
        let requested = AdvertisementIdentity(
            serviceName: "Studio-Mac",
            serviceType: "_orielreconnect._tcp"
        )

        #expect(
            AdvertisementLifecyclePolicy.decision(
                current: current,
                requested: requested
            ) == .replaceExisting
        )
    }
}
