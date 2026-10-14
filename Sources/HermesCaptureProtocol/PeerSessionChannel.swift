@preconcurrency import Network
import Foundation

public enum PeerSessionChannelError: Error, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case protocolViolation(PeerSessionError)
}

public final class PeerSessionChannel: @unchecked Sendable {
    public typealias PacketHandler = @Sendable (SessionPacket) -> Void
    public typealias StateHandler = @Sendable (PeerSessionState) -> Void
    public typealias ErrorHandler = @Sendable (PeerSessionChannelError) -> Void

    private let connection: NWConnection
    private let cipher: SessionCipher
    private let wireTransport: RelayWireTransport
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var decoder = SessionWireDecoder()
    private var machine = PeerSessionStateMachine()
    private var receivedReconnectRoute: ReconnectRoute?
    private var receivedCloseReason: String?
    /// Voice input: what this Mac offered, what the Mac offered this phone, and whether the phone has used it. A peer
    /// that did not show it speaks the speech packets never gets one; older peers end a session on an unknown kind.
    private var offeredSpeech: SpeechTranscriptionOffer?
    private var receivedSpeechOffer: SpeechTranscriptionOffer?
    private var peerSentSpeech = false
    private var healthMonitor = SessionHealthMonitor(
        startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
    )
    private var lastHeartbeatSentNanoseconds: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var started = false

    public var onPacket: PacketHandler?
    public var onStateChange: StateHandler?
    public var onError: ErrorHandler?

    public init(
        connection: NWConnection,
        cipher: SessionCipher,
        wireTransport: RelayWireTransport = .tlsTCP,
        queue: DispatchQueue = DispatchQueue(
            label: "com.67enterprise.hermescapture.peer-session",
            qos: .userInitiated
        )
    ) {
        self.connection = connection
        self.cipher = cipher
        self.wireTransport = wireTransport
        self.queue = queue
    }

    public var currentState: PeerSessionState {
        lock.withLock { machine.state }
    }

    public var currentCapabilities: Set<SessionCapability> {
        lock.withLock { machine.capabilities }
    }

    var heartbeatTimerIsScheduled: Bool {
        lock.withLock { heartbeatTimer != nil }
    }

    public func start() {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        connection.start(queue: queue)
        startHeartbeatTimer()
        receiveNextChunk()
    }

    public func adoptEstablishedConnection() throws {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        try transition(.connectionEstablished)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failed(error):
                finishConnection(
                    reporting: .connectionFailed(String(describing: error))
                )
            case .cancelled:
                finishConnection()
            default:
                break
            }
        }
        startHeartbeatTimer()
        receiveNextChunk()
    }

    public func markPeerAuthenticated() throws {
        try transition(.peerAuthenticated)
    }

    public func approve(
        capabilities: Set<SessionCapability>,
        reconnectRoute: ReconnectRoute? = nil,
        speech: SpeechTranscriptionOffer? = nil
    ) throws {
        try transition(.approved(capabilities: capabilities))
        lock.withLock { offeredSpeech = speech }
        try send(
            .approval(
                .init(
                    capabilities: capabilities,
                    expiresAt: Date.now.addingTimeInterval(3_600),
                    reconnectRoute: reconnectRoute,
                    speech: speech
                )
            )
        )
    }

    /// The relay rendezvous the Mac handed over with its approval, if any.
    public var approvedReconnectRoute: ReconnectRoute? {
        lock.withLock { receivedReconnectRoute }
    }

    /// Voice input the Mac offered with its approval; nil from a Mac or PC that does not offer it.
    public var speechOffer: SpeechTranscriptionOffer? {
        lock.withLock { receivedSpeechOffer }
    }

    /// The reason the other device gave when it ended the session, if it said goodbye.
    public var peerCloseReason: String? {
        lock.withLock { receivedCloseReason }
    }

    public func send(_ packet: SessionPacket) throws {
        let current = lock.withLock { machine }
        switch packet {
        case .input:
            guard current.state == .active,
                  current.capabilities.contains(.controlPointer)
                    || current.capabilities.contains(.typeText) else {
                throw PeerSessionError.controlNotAuthorized
            }
        case .video:
            guard current.state == .active,
                  current.capabilities.contains(.viewScreen) else {
                throw PeerSessionError.controlNotAuthorized
            }
        case .approval:
            guard current.state == .active else {
                throw PeerSessionError.invalidTransition
            }
        case .agentInstruction, .agentControl:
            guard current.state == .active,
                  current.capabilities.contains(.runAgentActions) else {
                throw PeerSessionError.controlNotAuthorized
            }
        case .agentTrace, .agentStatus:
            guard current.state == .active else {
                throw PeerSessionError.controlNotAuthorized
            }
        case .speechRequest:
            // Only to a Mac that offered voice input this session.
            guard current.state == .active, speechOffer != nil else {
                throw PeerSessionError.capabilityDenied
            }
        case .speechEvent:
            // Only to a phone that has used voice input this session.
            let (offered, peerSent) = lock.withLock { (offeredSpeech != nil, peerSentSpeech) }
            guard current.state == .active, offered, peerSent else {
                throw PeerSessionError.capabilityDenied
            }
        default:
            break
        }

        let envelope = try cipher.seal(packet)
        let data = try SessionWireCodec.encode(envelope)
        connection.send(
            content: data,
            contentContext: wireTransport.makeSendContext(),
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finishConnection(
                    reporting: .connectionFailed(String(describing: error))
                )
            }
        })
    }

    public func close(reason: String = "user-ended-session") {
        // Hang up only after the goodbye has gone out: cancelling at once can drop it, and the
        // other side then cannot tell a deliberate end from a lost connection.
        let goodbyeSent = sendGoodbye(reason)
        finishConnection(cancellingConnection: !goodbyeSent)
    }

    private func sendGoodbye(_ reason: String) -> Bool {
        guard let envelope = try? cipher.seal(.close(reason: reason)),
              let data = try? SessionWireCodec.encode(envelope) else {
            return false
        }
        let connection = self.connection
        connection.send(
            content: data,
            contentContext: wireTransport.makeSendContext(),
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
        // A connection that never started never reports the send.
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        return true
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            do {
                try transition(.connectionEstablished)
            } catch let error as PeerSessionError {
                onError?(.protocolViolation(error))
                finishConnection()
            } catch {
                finishConnection()
            }
        case let .failed(error):
            finishConnection(
                reporting: .connectionFailed(String(describing: error))
            )
        case .cancelled:
            finishConnection()
        default:
            break
        }
    }

    private func receiveNextChunk() {
        if wireTransport == .secureWebSocket {
            connection.receiveMessage { [weak self] data, context, isComplete, error in
                guard let self else { return }
                // Hanging up completes the pending read with nothing in it; that is not a
                // protocol violation.
                guard currentState != .closed else { return }
                if error == nil {
                    switch wireTransport.classify(context) {
                    case .control:
                        receiveNextChunk()
                        return
                    case .closed:
                        finishConnection()
                        return
                    case .payload where isComplete:
                        break
                    case .payload, .unexpected:
                        onError?(.protocolViolation(.invalidPacket))
                        finishConnection()
                        return
                    }
                }
                handleReceivedChunk(
                    data: data,
                    connectionComplete: false,
                    error: error
                )
            }
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            self?.handleReceivedChunk(
                data: data,
                connectionComplete: isComplete,
                error: error
            )
        }
    }

    private func handleReceivedChunk(
        data: Data?,
        connectionComplete: Bool,
        error: NWError?
    ) {
        // Closed here while the goodbye was going out: nothing left to read.
        guard currentState != .closed else { return }
        if let error {
            finishConnection(
                reporting: .connectionFailed(String(describing: error))
            )
            return
        }
        if let data, !data.isEmpty {
            do {
                let envelopes = try lock.withLock {
                    try decoder.append(data)
                }
                for envelope in envelopes {
                    let packet = try cipher.open(envelope)
                    lock.withLock {
                        healthMonitor.recordInbound(
                            atNanoseconds: DispatchTime.now().uptimeNanoseconds
                        )
                    }
                    try validateIncoming(packet)
                    onPacket?(packet)
                    if currentState == .closed { return }
                }
            } catch let error as PeerSessionError {
                onError?(.protocolViolation(error))
                finishConnection()
                return
            } catch {
                finishConnection()
                return
            }
        }
        if connectionComplete {
            finishConnection(reporting: .connectionClosed)
            return
        }
        receiveNextChunk()
    }

    private func validateIncoming(_ packet: SessionPacket) throws {
        switch packet {
        case .heartbeat:
            try transition(.heartbeatReceived)
        case .input:
            try transition(.controlReceived)
        case let .approval(approval):
            // Stored first: the state change below reaches the owner synchronously, and the
            // phone reads the route from inside that callback.
            lock.withLock {
                receivedReconnectRoute = approval.reconnectRoute
                receivedSpeechOffer = approval.speech
            }
            try transition(.approved(capabilities: approval.capabilities))
        case .agentInstruction, .agentControl:
            // The assistant is a control surface: it counts as activity and needs the capability.
            guard currentCapabilities.contains(.runAgentActions) else {
                throw PeerSessionError.capabilityDenied
            }
            try transition(.controlReceived)
        case .agentTrace, .agentStatus:
            guard currentState == .active || currentState == .stale else {
                throw PeerSessionError.invalidTransition
            }
        case .speechRequest:
            // Voice input this Mac did not offer is a protocol violation, like any capability it did not grant.
            guard lock.withLock({ offeredSpeech != nil }) else {
                throw PeerSessionError.capabilityDenied
            }
            guard currentState == .active || currentState == .stale else {
                throw PeerSessionError.invalidTransition
            }
            lock.withLock { peerSentSpeech = true }
        case .speechEvent:
            guard speechOffer != nil else {
                throw PeerSessionError.capabilityDenied
            }
            guard currentState == .active || currentState == .stale else {
                throw PeerSessionError.invalidTransition
            }
        case let .close(reason):
            lock.withLock { receivedCloseReason = reason }
            finishConnection()
        default:
            break
        }
    }

    private func transition(_ event: PeerSessionEvent) throws {
        let (state, changed) = try lock.withLock {
            let previousState = machine.state
            try machine.handle(event)
            if machine.state == .active,
               previousState != .active,
               previousState != .stale {
                healthMonitor.activate(
                    atNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            }
            return (machine.state, machine.state != previousState)
        }
        // Heartbeats and control packets keep an active session active: listeners hear only
        // real changes, plus every approval (it can change the capabilities).
        if changed || event.isApproval {
            onStateChange?(state)
        }
    }

    private func startHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        let installation = lock.withLock { () -> (installed: Bool, previous: DispatchSourceTimer?) in
            guard machine.state != .closed else {
                return (false, nil)
            }
            let previous = heartbeatTimer
            heartbeatTimer = timer
            return (true, previous)
        }
        guard installation.installed else {
            timer.resume()
            timer.cancel()
            return
        }
        installation.previous?.cancel()
        timer.resume()
    }

    private func finishConnection(
        reporting error: PeerSessionChannelError? = nil,
        cancellingConnection: Bool = true
    ) {
        let finalization = lock.withLock { () -> (timer: DispatchSourceTimer?, changedToClosed: Bool) in
            let timer = heartbeatTimer
            heartbeatTimer = nil
            guard machine.state != .closed else {
                return (timer, false)
            }
            try? machine.handle(.closed)
            return (timer, machine.state == .closed)
        }
        finalization.timer?.cancel()

        if finalization.changedToClosed {
            onStateChange?(.closed)
        }
        if let error {
            onError?(error)
        }
        if cancellingConnection {
            connection.cancel()
        }
    }

    private func heartbeatTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let state = currentState
        guard state == .active || state == .stale else { return }
        let result = lock.withLock { () -> (SessionHealthMonitor.Health, Bool) in
            let health = healthMonitor.evaluate(nowNanoseconds: now)
            let shouldSend = healthMonitor.shouldSendHeartbeat(
                nowNanoseconds: now,
                lastSentNanoseconds: lastHeartbeatSentNanoseconds
            )
            if shouldSend { lastHeartbeatSentNanoseconds = now }
            return (health, shouldSend)
        }

        switch result.0 {
        case .closed:
            finishConnection()
        case .stale:
            if currentState == .active {
                try? transition(.heartbeatTimedOut)
            }
        case .active:
            if result.1, currentState == .active {
                try? send(.heartbeat(monotonicNanoseconds: now))
            }
        }
    }
}
