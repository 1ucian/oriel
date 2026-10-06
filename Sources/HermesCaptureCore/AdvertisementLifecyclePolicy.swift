public struct AdvertisementIdentity: Equatable, Sendable {
    public let serviceName: String
    public let serviceType: String

    public init(serviceName: String, serviceType: String) {
        self.serviceName = serviceName
        self.serviceType = serviceType
    }
}

public enum AdvertisementLifecycleDecision: Equatable, Sendable {
    case startNew
    case keepExisting
    case replaceExisting
}

public enum AdvertisementLifecyclePolicy {
    public static func decision(
        current: AdvertisementIdentity?,
        requested: AdvertisementIdentity
    ) -> AdvertisementLifecycleDecision {
        guard let current else { return .startNew }
        return current == requested ? .keepExisting : .replaceExisting
    }
}
