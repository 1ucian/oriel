import AppKit
import CoreGraphics
import CoreImage.CIFilterBuiltins
import CryptoKit
import HermesCaptureProtocol
@preconcurrency import Network
import Observation
import Security

@MainActor
@Observable
final class PairingCoordinator {
    private(set) var qrImage: NSImage?
    /// The same offer as text, for a phone that pastes instead of scanning.
    private(set) var pairingCode: String?
    private(set) var pending: PendingPairing?
    private(set) var isPairing = false
    private(set) var isControlling = false
    private(set) var isApprovalInFlight = false
    private(set) var connectedDeviceName: String?
    /// True when the live session arrived through the relay rather than the local network.
    private(set) var connectedThroughRelay = false
    private var pendingArrivedThroughRelay = false
    private(set) var activeCapabilities: Set<SessionCapability> = []
    private(set) var errorDescription: String?
    /// The phones this Mac trusts, newest pairing first.
    private(set) var pairedDevices: [TrustedPeerRecord] = []
    /// Why the list above may be out of date: the keychain could not be read or written.
    private(set) var pairedDevicesError: String?

    private let advertiser = CompanionAdvertiser()
    private let server = PairingServer()
    private let reconnectServer = ReconnectServer()
    private let identityStore = PairingIdentityStore()
    private let trustedClientStore: TrustedClientStore
    private let remoteController = MacRemoteSessionController()
    private var identity: PairingIdentity?
    private var offer: SignedPairingPayload?
    private var activeChannel: PeerSessionChannel?
    private(set) var activePeerSigningPublicKey: Data?
    private var availabilityServiceName: String?
    private var reconnectInFlight = false
    private var approvalInFlight = SingleFlightGate<String>()
    private var relayTask: Task<Void, Never>?
    private var relayConnection: NWConnection?
    /// Waits on the relay for a paired phone that is not on the local network.
    private var relayAvailabilityTask: Task<Void, Never>?
    private var reconnectRoute: ReconnectRoute?
    private var isShuttingDown = false

    init(trustedClientStore: TrustedClientStore = TrustedClientStore()) {
        self.trustedClientStore = trustedClientStore
    }

    func startAvailability() {
        guard !isShuttingDown, !isPairing, pending == nil, !isControlling else {
            return
        }
        do {
            let identity = try identityStore.loadOrCreate()
            let serviceName = sanitizedServiceName(advertisedName())
            availabilityServiceName = serviceName
            advertiser.onCandidateConnection { [weak self] connection in
                Task {
                    await self?.acceptReconnect(
                        connection,
                        identity: identity,
                        serviceName: serviceName
                    )
                }
            }
            try advertiser.startReconnectMode(serviceName: serviceName)
            startRelayAvailability(identity: identity, serviceName: serviceName)
        } catch {
            advertiser.stop(); stopRelayAvailability()
            errorDescription = "Reconnect availability could not start."
        }
    }

    func startPairing() {
        stopPairing(resumeAvailability: false)
        do {
            let identity = try identityStore.loadOrCreate()
            let nonce = try secureRandomData(count: 24)
            let serviceName = sanitizedServiceName(advertisedName())
            let expiresAt = Date.now.addingTimeInterval(
                PairingOfferPolicy.lifetime
            )
            let relayRoute = try configuredRelayRoute(expiresAt: expiresAt)
            let shouldAdvertiseDirect = RelayConnectionPreference.shouldAdvertiseDirect(
                environment: ProcessInfo.processInfo.environment,
                hasRelayRoute: relayRoute != nil
            )
            let payload = PairingPayload(
                macPublicKey: identity.keyAgreementKey.publicKey.rawRepresentation,
                nonce: nonce,
                expiresAt: expiresAt,
                serviceName: serviceName,
                relayRoute: relayRoute
            )
            let offer = try SignedPairingPayload.sign(
                payload,
                with: identity.signingKey
            )
            let pairingCode = try offer.qrEncodedString()
            qrImage = try makeQRCode(pairingCode)
            self.pairingCode = pairingCode
            self.identity = identity
            self.offer = offer
            errorDescription = nil

            if shouldAdvertiseDirect {
                advertiser.onCandidateConnection { [weak self] connection in
                    NSLog("Oriel pairing: candidate connection from %@", String(describing: connection.endpoint))
                    Task { await self?.accept(connection) }
                }
                try advertiser.startPairingMode(serviceName: serviceName)
            }
            isPairing = true
            ActivityLog.shared.write(.pairing, "Pairing code shown; waiting "
                + (shouldAdvertiseDirect && relayRoute != nil ? "on the local network and the relay"
                   : relayRoute != nil ? "on the relay" : "on the local network"))
            if let relayRoute {
                relayTask = Task { [weak self] in
                    await self?.connectRelayUntilPaired(
                        route: relayRoute,
                        offer: offer,
                        identity: identity
                    )
                }
            }
        } catch {
            errorDescription = String(describing: error)
            ActivityLog.shared.write(.pairing, "Pairing could not start: \(error)")
            stopPairing()
        }
    }

    func approve() {
        guard let pending, approvalInFlight.begin(pending.sessionID) else { return }
        isApprovalInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                approvalInFlight.end(pending.sessionID)
                isApprovalInFlight = false
            }
            // The owner's approval is what lets a phone revoked earlier in this run back in.
            await remoteController.readmit(deviceID: pending.deviceID)
            // Declined, revoked or replaced meanwhile: whatever ended it has already cleaned up.
            guard self.pending?.sessionID == pending.sessionID else { return }
            await activate(
                pending,
                persistApprovedCapabilities: pending.requestedCapabilities
            )
        }
    }

    private func activate(
        _ pending: PendingPairing,
        persistApprovedCapabilities: Set<SessionCapability>?
    ) async {
        // The phone counts as the active one while its session starts, so Revoke or Stop Control
        // in that time closes its channel at once.
        activePeerSigningPublicKey = pending.clientSigningPublicKey
        do {
            try pending.channel.approve(
                capabilities: pending.requestedCapabilities,
                reconnectRoute: reconnectRoute,
                speech: SpeechSettings.shared.offer(for: pending.requestedCapabilities)
            )
            observeActiveChannel(pending.channel)
            try await remoteController.start(
                channel: pending.channel,
                displayID: CGMainDisplayID(),
                sessionID: pending.sessionID,
                deviceID: pending.deviceID,
                deviceName: pending.deviceName,
                capabilities: pending.requestedCapabilities
            )
            guard activeChannel === pending.channel,
                  pending.channel.currentState == .active else {
                throw PeerSessionChannelError.connectionClosed
            }
            if let persistApprovedCapabilities {
                // A saved phone approved for more keeps the date it was first paired.
                let pairedAt = pending.isReconnect
                    ? (try? trustedClientStore.record(signingPublicKey: pending.clientSigningPublicKey))?.createdAt
                    : nil
                try trustedClientStore.save(
                    TrustedPeerRecord(
                        signingPublicKey: pending.clientSigningPublicKey,
                        keyAgreementPublicKey: pending.clientKeyAgreementPublicKey,
                        serviceName: pending.serviceName,
                        displayName: pending.deviceName,
                        approvedCapabilities: persistApprovedCapabilities,
                        createdAt: pairedAt ?? .now
                    )
                )
                refreshPairedDevices()
            }
            self.pending = nil
            self.isPairing = false
            self.isControlling = true
            self.connectedThroughRelay = pendingArrivedThroughRelay
            self.connectedDeviceName = pending.deviceName
            self.activeCapabilities = pending.requestedCapabilities
            self.activePeerSigningPublicKey = pending.clientSigningPublicKey
            self.errorDescription = nil
            ActivityLog.shared.write(.session, "Session started with \(Self.loggedName(pending.deviceName)) "
                + (pendingArrivedThroughRelay ? "through the relay" : "on the local network")
                + "; allowed: " + pending.requestedCapabilities.map(\.rawValue).sorted().joined(separator: ", "))
            startAvailability()
        } catch {
            // Revoke, Stop Control or the phone ended the session while it started: that path
            // closed the channel with its own reason and advertises again.
            let endedMeanwhile = activePeerSigningPublicKey != pending.clientSigningPublicKey
            ActivityLog.shared.write(.session, "Session with \(Self.loggedName(pending.deviceName)) could not start: \(error)")
            if !endedMeanwhile {
                pending.channel.close(reason: "approval-failed")
            }
            if activeChannel === pending.channel {
                activeChannel = nil
            }
            await remoteController.stop()
            if self.pending?.sessionID == pending.sessionID {
                self.pending = nil
            }
            if activePeerSigningPublicKey == pending.clientSigningPublicKey {
                activePeerSigningPublicKey = nil
            }
            guard !endedMeanwhile else { return }
            self.errorDescription = pending.isReconnect
                ? "Reconnect request could not be authorized."
                : String(describing: error)
            startAvailability()
        }
    }

    func decline() {
        if let pending {
            ActivityLog.shared.write(.pairing, "Request from \(Self.loggedName(pending.deviceName)) declined on the Mac")
        }
        pending?.channel.close(reason: "declined-on-mac")
        pending = nil
        startAvailability()
    }

    /// Ends the session, its input and any assistant run, a run that went on without its phone too.
    /// The phone stays trusted: it can reconnect, which Revoke would prevent.
    func stopControl() {
        let channel = activeChannel
        let endsConnection = channel != nil || pending != nil
        if channel != nil || AssistantStatus.shared.isActive {
            ActivityLog.shared.write(.session, "Session stopped on the Mac (Stop Control)")
        }
        activeChannel = nil
        channel?.close(reason: "stopped-on-mac")
        pending?.channel.close(reason: "stopped-on-mac")
        pending = nil
        isControlling = false
        connectedDeviceName = nil
        activePeerSigningPublicKey = nil
        activeCapabilities.removeAll()
        Task { [weak self] in
            guard let self else { return }
            await remoteController.stop()
            // With only a run going on without its phone, advertising never stopped.
            if endsConnection {
                startAvailability()
            }
        }
    }

    func shutdown() async {
        ActivityLog.shared.write(.app, "Oriel is quitting")
        defer { ActivityLog.shared.flush() }
        isShuttingDown = true
        advertiser.stop(); stopRelayAvailability()
        relayTask?.cancel()
        relayTask = nil
        relayConnection?.cancel()
        relayConnection = nil
        activeChannel?.close(reason: "mac-app-quit")
        pending?.channel.close(reason: "mac-app-quit")
        activeChannel = nil
        pending = nil
        await remoteController.stop()
        isPairing = false
        isControlling = false
        connectedDeviceName = nil
        activePeerSigningPublicKey = nil
        activeCapabilities.removeAll()
        qrImage = nil; pairingCode = nil
        offer = nil
        identity = nil
    }

    private func observeActiveChannel(_ channel: PeerSessionChannel) {
        activeChannel = channel
        channel.onError = { error in
            ActivityLog.shared.write(.session, "Connection error: \(error)")
        }
        channel.onStateChange = { [weak self, weak channel] state in
            guard let self, let channel else { return }
            switch state {
            case .stale:
                // A phone that went quiet (asleep, in another app, out of signal) did not ask
                // for the assistant to stop: a run in progress goes on without it.
                Task { @MainActor in
                    await self.endActiveSession(
                        channel,
                        closeReason: "stale-on-mac",
                        why: "nothing arrived from the phone for 5 seconds, so the Mac ended the session",
                        keepingRun: true
                    )
                }
            case .closed:
                Task { @MainActor in
                    let why = channel.peerCloseReason.map {
                        "the phone ended the session (\(ActivityLogRedaction.token($0)))"
                    } ?? "the connection closed without a goodbye from the phone"
                    await self.endActiveSession(channel, why: why, keepingRun: channel.peerCloseReason == nil)
                }
            default:
                break
            }
        }
    }

    private func endActiveSession(
        _ channel: PeerSessionChannel,
        closeReason: String? = nil,
        why: String,
        keepingRun: Bool = false
    ) async {
        guard activeChannel === channel else { return }
        ActivityLog.shared.write(.session, "Session with \(Self.loggedName(connectedDeviceName ?? "the phone")) ended: \(why)")
        activeChannel = nil
        if let closeReason {
            channel.close(reason: closeReason)
        }
        await remoteController.stop(keepingRun: keepingRun)
        isControlling = false
        connectedDeviceName = nil
        activePeerSigningPublicKey = nil
        activeCapabilities.removeAll()
        startAvailability()
    }

    /// A device name as the activity log shows it.
    private static func loggedName(_ name: String) -> String {
        "\"" + ActivityLogRedaction.scrub(name, limit: 64) + "\""
    }

    func stopPairing() {
        if isPairing {
            ActivityLog.shared.write(.pairing, "Pairing stopped")
        }
        stopPairing(resumeAvailability: true)
    }

    private func stopPairing(resumeAvailability: Bool) {
        // The relay wait stays up while a code is shown: a trusted phone reconnecting from
        // outside must not be blocked by a pairing in progress.
        advertiser.stop()
        relayTask?.cancel()
        relayTask = nil
        relayConnection?.cancel()
        relayConnection = nil
        isPairing = false
        qrImage = nil; pairingCode = nil
        offer = nil
        identity = nil
        if resumeAvailability {
            startAvailability()
        }
    }

    private func accept(
        _ connection: NWConnection,
        connectionIsEstablished: Bool = false,
        wireTransport: RelayWireTransport = .tlsTCP
    ) async {
        guard let offer, let identity else {
            connection.cancel()
            return
        }
        do {
            let pending = try await server.accept(
                connection: connection,
                offer: offer,
                identity: identity,
                connectionIsEstablished: connectionIsEstablished,
                wireTransport: wireTransport
            )
            advertiser.stop(); stopRelayAvailability()
            if connectionIsEstablished {
                relayConnection = nil
                relayTask = nil
            } else {
                relayTask?.cancel()
                relayTask = nil
                relayConnection?.cancel()
                relayConnection = nil
            }
            isPairing = false
            qrImage = nil; pairingCode = nil
            self.offer = nil
            self.identity = nil
            pendingArrivedThroughRelay = connectionIsEstablished
            self.pending = pending
            ActivityLog.shared.write(.pairing, "Pairing request from \(Self.loggedName(pending.deviceName)) "
                + (connectionIsEstablished ? "through the relay" : "on the local network") + "; waiting for approval on the Mac")
        } catch {
            connection.cancel()
            NSLog("Oriel pairing accept failed: %@", String(describing: error))
            ActivityLog.shared.write(.pairing, "Pairing attempt failed: \(error)")
            errorDescription = String(describing: error)
        }
    }

    /// Keeps a host registration waiting on the relay so a paired phone can reconnect from
    /// anywhere. The relay drops a waiting registration when it lapses; this registers again.
    private func startRelayAvailability(identity: PairingIdentity, serviceName: String) {
        stopRelayAvailability()
        guard let configured = try? configuredRelayRoute(expiresAt: Date.now.addingTimeInterval(120)) else {
            reconnectRoute = nil
            return
        }
        guard let route = try? ReconnectRouteStore(serviceName: serviceName).loadOrCreate(
            host: configured.host, port: configured.port, transport: configured.transport
        ) else { return }
        reconnectRoute = route
        relayAvailabilityTask = Task { [weak self] in
            var retryDelay = Duration.seconds(1)
            while !Task.isCancelled {
                let relayRoute = route.relayRoute(lifetime: ReconnectRoute.hostRegistrationLifetime + 60)
                do {
                    let connection = try await RelayConnectionFactory.connect(
                        route: relayRoute,
                        pairingNonce: route.nonce,
                        role: .host,
                        signingKey: identity.signingKey,
                        registrationLifetime: ReconnectRoute.hostRegistrationLifetime
                    )
                    guard !Task.isCancelled, let self else {
                        connection.cancel()
                        return
                    }
                    retryDelay = .seconds(1)
                    await self.acceptReconnect(
                        connection,
                        identity: identity,
                        serviceName: serviceName,
                        connectionIsEstablished: true,
                        wireTransport: relayRoute.transport
                    )
                } catch is CancellationError {
                    return
                } catch {
                    NSLog("Oriel relay availability: %@", String(describing: error))
                    ActivityLog.shared.write(.relay, "Waiting registration ended (\(error)); registering again")
                    do { try await Task.sleep(for: retryDelay) } catch { return }
                    retryDelay = min(retryDelay * 2, .seconds(8))
                }
            }
        }
    }

    private func stopRelayAvailability() {
        relayAvailabilityTask?.cancel()
        relayAvailabilityTask = nil
    }

    private func acceptReconnect(
        _ connection: NWConnection,
        identity: PairingIdentity,
        serviceName: String,
        connectionIsEstablished: Bool = false,
        wireTransport: RelayWireTransport = .tlsTCP
    ) async {
        guard !isShuttingDown, pending == nil, !isControlling,
              !reconnectInFlight,
              availabilityServiceName == serviceName else {
            connection.cancel()
            return
        }
        if isPairing {
            // A phone we already trust is back; the code on screen can wait.
            stopPairing(resumeAvailability: false)
        }
        reconnectInFlight = true
        defer { reconnectInFlight = false }
        do {
            let accepted = try await reconnectServer.accept(
                connection: connection,
                identity: identity,
                serviceName: serviceName,
                trustedPeers: trustedClientStore.records(),
                connectionIsEstablished: connectionIsEstablished,
                wireTransport: wireTransport
            )
            guard let currentTrustedPeer = try trustedClientStore.record(
                signingPublicKey: accepted.trustedPeer.signingPublicKey
            ), currentTrustedPeer == accepted.trustedPeer else {
                ActivityLog.shared.write(.session, "Reconnect from \(Self.loggedName(accepted.deviceName)) refused: no longer a trusted device")
                accepted.channel.close(reason: "reconnect-peer-revoked")
                return
            }
            guard !isShuttingDown, !isPairing, pending == nil, !isControlling else {
                ActivityLog.shared.write(.session, "Reconnect from \(Self.loggedName(accepted.deviceName)) refused: the Mac is busy with another session or a pairing")
                accepted.channel.close(reason: "reconnect-no-longer-available")
                return
            }
            advertiser.stop(); stopRelayAvailability()
            pendingArrivedThroughRelay = connectionIsEstablished
            let pending = PendingPairing(
                channel: accepted.channel,
                sessionID: accepted.sessionID,
                deviceID: accepted.deviceID,
                deviceName: accepted.deviceName,
                requestedCapabilities: accepted.requestedCapabilities,
                clientSigningPublicKey: accepted.trustedPeer.signingPublicKey,
                clientKeyAgreementPublicKey: accepted.trustedPeer.keyAgreementPublicKey,
                serviceName: serviceName,
                isReconnect: true,
                confirmationCode: nil
            )
            ActivityLog.shared.write(.session, "Reconnect from \(Self.loggedName(accepted.deviceName)) "
                + (connectionIsEstablished ? "through the relay" : "on the local network")
                + (accepted.decision == .autoApprove ? "; saved device, approved automatically" : "; waiting for approval on the Mac"))
            switch accepted.decision {
            case .autoApprove:
                await activate(pending, persistApprovedCapabilities: nil)
            case .requiresApproval:
                self.pending = pending
            }
        } catch {
            connection.cancel()
            NSLog("Oriel reconnect accept failed: %@", String(describing: error))
            ActivityLog.shared.write(.session, "Reconnect attempt failed: \(error)")
        }
    }

    func refreshPairedDevices() {
        do {
            pairedDevices = try trustedClientStore.records().sorted { $0.createdAt > $1.createdAt }
            pairedDevicesError = nil
        } catch {
            pairedDevicesError = "The list of paired devices could not be read."
        }
    }

    /// Ends the phone's session and input now and removes its trust: it comes back only through a
    /// new pairing code and a new approval on the Mac. Trust goes first, so no reconnect slips in
    /// between, and the session ends even when the keychain write fails.
    func revokePeer(signingPublicKey: Data) {
        let deviceID = SHA256.hash(data: signingPublicKey).map { String(format: "%02x", $0) }.joined()
        let name = pairedDevices.first { $0.signingPublicKey == signingPublicKey }
            .map { Self.loggedName($0.displayName) } ?? "a phone"
        var trustRemoved = true
        do {
            try trustedClientStore.revoke(signingPublicKey: signingPublicKey)
            ActivityLog.shared.write(.pairing, "\(name) revoked on the Mac; it must pair again with a new code")
        } catch {
            trustRemoved = false
            ActivityLog.shared.write(.pairing, "Revoking \(name) could not remove its trust: \(error)")
        }
        let endsSession = activePeerSigningPublicKey == signingPublicKey
        if endsSession {
            let channel = activeChannel
            activeChannel = nil
            channel?.close(reason: "revoked-on-mac")
            isControlling = false
            connectedDeviceName = nil
            activePeerSigningPublicKey = nil
            activeCapabilities.removeAll()
        }
        let endsRequest = pending?.clientSigningPublicKey == signingPublicKey
        if endsRequest {
            pending?.channel.close(reason: "revoked-on-mac")
            pending = nil
        }
        refreshPairedDevices()
        if !trustRemoved {
            pairedDevicesError = "The pairing could not be removed. Try Revoke again."
        }
        Task { [weak self] in
            guard let self else { return }
            await remoteController.revoke(deviceID: deviceID)
            if endsSession || endsRequest {
                startAvailability()
            }
        }
    }

    private func connectRelayUntilPaired(
        route: RelayRoute,
        offer: SignedPairingPayload,
        identity: PairingIdentity
    ) async {
        var retryDelay = Duration.milliseconds(250)
        while !Task.isCancelled, Date.now < route.expiresAt {
            do {
                let connection = try await RelayConnectionFactory.connect(
                    route: route,
                    pairingNonce: offer.payload.nonce,
                    role: .host,
                    signingKey: identity.signingKey
                )
                guard self.offer?.payload.nonce == offer.payload.nonce,
                      isPairing else {
                    connection.cancel()
                    return
                }
                relayConnection = connection
                await accept(
                    connection,
                    connectionIsEstablished: true,
                    wireTransport: route.transport
                )
                return
            } catch is CancellationError {
                return
            } catch {
                ActivityLog.shared.write(.relay, "Pairing wait on the relay ended (\(error)); trying again")
                do {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, .seconds(4))
            }
        }
        if !Task.isCancelled,
           self.offer?.payload.nonce == offer.payload.nonce,
           isPairing {
            ActivityLog.shared.write(.pairing, "Pairing code expired")
            errorDescription = "Pairing code expired. Generate a new code to continue."
            stopPairing()
        }
    }

    private func configuredRelayRoute(expiresAt: Date) throws -> RelayRoute? {
        let environment = ProcessInfo.processInfo.environment
        let configuredHost = environment["ORIEL_RELAY_HOST"]
            ?? Bundle.main.object(forInfoDictionaryKey: "OrielRelayHost") as? String
        guard let host = configuredHost?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !host.isEmpty else {
            return nil
        }
        let bundlePort = Bundle.main.object(
            forInfoDictionaryKey: "OrielRelayPort"
        )
        let portString = environment["ORIEL_RELAY_PORT"]
            ?? (bundlePort as? String)
            ?? (bundlePort as? NSNumber)?.stringValue
            ?? "443"
        guard let port = UInt16(portString) else {
            throw RelayError.invalidRoute
        }
        let configuredTransport = environment["ORIEL_RELAY_TRANSPORT"]
            ?? Bundle.main.object(
                forInfoDictionaryKey: "OrielRelayTransport"
            ) as? String
            ?? "websocket"
        let transport: RelayWireTransport
        switch configuredTransport.lowercased() {
        case "websocket", "wss", "securewebsocket":
            transport = .secureWebSocket
        case "tcp", "tls", "tlstcp":
            transport = .tlsTCP
        default:
            throw RelayError.invalidRoute
        }
        let route = RelayRoute(
            host: host,
            port: port,
            roomID: try secureRandomData(count: 24),
            accessKey: try secureRandomData(count: 32),
            expiresAt: expiresAt,
            transport: transport
        )
        try route.validate()
        return route
    }

    private func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PairingIdentityStoreError.keychain(status)
        }
        return data
    }

    /// The Mac's name as advertised to phones. `ORIEL_SERVICE_NAME` lets a
    /// second copy run beside the installed companion during development.
    private func advertisedName() -> String {
        let override = ProcessInfo.processInfo.environment["ORIEL_SERVICE_NAME"]
        if let override, !override.isEmpty { return override }
        return Host.current().localizedName ?? "Mac"
    }

    private func sanitizedServiceName(_ value: String) -> String {
        let allowed = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar)
                ? Character(String(scalar))
                : "-"
        }
        let normalized = String(allowed)
            .replacingOccurrences(of: "--", with: "-")
            .prefix(63)
        return normalized.isEmpty ? "Mac" : String(normalized)
    }

    private func makeQRCode(_ value: String) throws -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 7, y: 7)
        ) else {
            throw PairingError.invalidEncoding
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct SingleFlightGate<Key: Equatable> {
    private var activeKey: Key?

    mutating func begin(_ key: Key) -> Bool {
        guard activeKey == nil else { return false }
        activeKey = key
        return true
    }

    mutating func end(_ key: Key) {
        guard activeKey == key else { return }
        activeKey = nil
    }
}
