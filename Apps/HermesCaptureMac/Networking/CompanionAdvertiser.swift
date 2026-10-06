@preconcurrency import Network
import HermesCaptureCore
import HermesCaptureProtocol
import Observation

@MainActor
@Observable
final class CompanionAdvertiser {
    private(set) var state: DiscoveryState = .idle
    private(set) var listeningPort: UInt16?

    private var listener: NWListener?
    private var currentAdvertisement: AdvertisementIdentity?
    private var listenerGeneration = 0
    private var candidateConnectionHandler: (@Sendable (NWConnection) -> Void)?
    private let queue = DispatchQueue(
        label: "com.67enterprise.hermescapture.bonjour.advertiser"
    )

    func startPairingMode(serviceName: String) throws {
        try start(
            serviceName: serviceName,
            serviceType: "_hermescapture._tcp",
            purpose: "pairing"
        )
    }

    func startReconnectMode(serviceName: String) throws {
        try start(
            serviceName: serviceName,
            serviceType: "_orielreconnect._tcp",
            purpose: "reconnect"
        )
    }

    private func start(
        serviceName: String,
        serviceType: String,
        purpose: String
    ) throws {
        let requestedAdvertisement = AdvertisementIdentity(
            serviceName: serviceName,
            serviceType: serviceType
        )
        let current = listener == nil ? nil : currentAdvertisement
        switch AdvertisementLifecyclePolicy.decision(
            current: current,
            requested: requestedAdvertisement
        ) {
        case .keepExisting:
            return
        case .replaceExisting:
            stop()
        case .startNew:
            break
        }

        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: nil,
            txtRecord: NWTXTRecord([
                "version": "1",
                "purpose": purpose,
            ])
        )
        let candidateConnectionHandler = self.candidateConnectionHandler
        listener.newConnectionHandler = { connection in
            guard let candidateConnectionHandler else {
                connection.cancel()
                return
            }
            candidateConnectionHandler(connection)
        }
        listenerGeneration &+= 1
        let generation = listenerGeneration
        listener.stateUpdateHandler = { [weak self, weak listener] listenerState in
            Task { @MainActor in
                guard let listener else { return }
                self?.handle(
                    listenerState,
                    listener: listener,
                    generation: generation
                )
            }
        }

        self.listener = listener
        currentAdvertisement = requestedAdvertisement
        state = .advertising
        listener.start(queue: queue)
    }

    func onCandidateConnection(
        _ handler: @escaping @Sendable (NWConnection) -> Void
    ) {
        candidateConnectionHandler = handler
    }

    func stop() {
        listenerGeneration &+= 1
        let listener = self.listener
        self.listener = nil
        currentAdvertisement = nil
        listeningPort = nil
        state = .idle
        listener?.stateUpdateHandler = nil
        listener?.cancel()
    }

    private func handle(
        _ listenerState: NWListener.State,
        listener: NWListener,
        generation: Int
    ) {
        guard listenerGeneration == generation, self.listener === listener else {
            return
        }
        switch listenerState {
        case .ready:
            listeningPort = listener.port?.rawValue
            state = .advertising
        case .failed:
            self.listener = nil
            currentAdvertisement = nil
            listeningPort = nil
            state = .failed
        case .cancelled:
            self.listener = nil
            currentAdvertisement = nil
            listeningPort = nil
            state = .idle
        default:
            break
        }
    }
}
