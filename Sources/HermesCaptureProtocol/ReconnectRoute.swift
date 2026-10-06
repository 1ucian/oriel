import Foundation

/// A standing rendezvous on the relay, so a paired phone can find its Mac from anywhere:
/// the relay's address plus a room, an access key and a nonce that only the Mac and the
/// phones it approved know. The Mac hands it over at approval, inside the encrypted session,
/// and both sides keep it with the trusted record. Each use registers a fresh short-lived
/// `RelayRoute` built from it, so the relay never holds a long-lived credential.
public struct ReconnectRoute: Codable, Equatable, Sendable {
    /// How long one waiting host registration may sit on the relay (the relay's own cap is
    /// ten minutes); the Mac registers again when it lapses.
    public static let hostRegistrationLifetime: TimeInterval = 9 * 60
    /// How long a derived relay route is valid; well under the relay's one-hour maximum.
    public static let routeLifetime: TimeInterval = 50 * 60

    public let host: String
    public let port: UInt16
    public let transport: RelayWireTransport
    public let roomID: Data
    public let accessKey: Data
    /// Stands in for the pairing nonce in the rendezvous tag; one per route.
    public let nonce: Data

    public init(
        host: String,
        port: UInt16,
        transport: RelayWireTransport,
        roomID: Data,
        accessKey: Data,
        nonce: Data
    ) {
        self.host = host
        self.port = port
        self.transport = transport
        self.roomID = roomID
        self.accessKey = accessKey
        self.nonce = nonce
    }

    public func validate(at now: Date = .now) throws {
        try relayRoute(now: now).validate(at: now)
        guard (16...64).contains(nonce.count) else { throw RelayError.invalidRoute }
    }

    /// A relay route for the next `routeLifetime` seconds, with the shared room and key.
    public func relayRoute(lifetime: TimeInterval = ReconnectRoute.routeLifetime, now: Date = .now) -> RelayRoute {
        RelayRoute(
            host: host,
            port: port,
            roomID: roomID,
            accessKey: accessKey,
            expiresAt: now.addingTimeInterval(min(lifetime, RelayRoute.maximumLifetime - 60)),
            transport: transport
        )
    }
}
