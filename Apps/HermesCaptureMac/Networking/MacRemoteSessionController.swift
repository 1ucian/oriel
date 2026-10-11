import AppKit
import CoreGraphics
import HermesCaptureCore
import HermesCaptureProtocol

actor MacRemoteSessionController {
    private let captureService: ScreenCaptureService
    private let encoder = VideoEncoder()
    private let inputBroker = InputBroker()
    private var channel: PeerSessionChannel?
    private var displayID: CGDirectDisplayID = 0
    private var frameTask: Task<Void, Never>?
    private var isEncoding = false
    private var encoderConfiguration: VideoEncoderConfiguration?
    private var sessionID: String?
    /// The newest frame, for the assistant's on-Mac screen reading.
    private var latestFrame: CaptureFrame?
    private var assistant: AssistantRuntime?
    private var assistantConfiguration: AssistantRunConfiguration?
    /// The phone whose session is attached.
    private var deviceID: String?
    /// A run that outlived its session: the phone went quiet (asleep, in another app, out of
    /// signal) while the assistant worked. The run goes on under the approval of the session
    /// that started it, for at most `detachedRunLimitNanoseconds`; when the same phone comes
    /// back it gets the run's trace and can approve, answer or stop again. The owner can stop
    /// it from the menu bar at any time.
    private var detachedRun: (deviceID: String, sessionID: String, limit: Task<Void, Never>)?
    /// The latest run's trace and the phone that started it, replayed when that phone comes
    /// back after missing part of it.
    private var runTrace: [AgentTraceEvent] = []
    private var runTraceDeviceID: String?
    private var runTraceMissed = false
    static let detachedRunLimitNanoseconds: UInt64 = 10 * 60 * 1_000_000_000
    static let runTraceLimit = 200
    /// The last input failure written to the activity log, so a stream of pointer moves
    /// against a missing permission writes one line, not hundreds.
    private var lastLoggedInputFailure: (message: String, atNanoseconds: UInt64)?

    init(captureService: ScreenCaptureService = ScreenCaptureService()) {
        self.captureService = captureService
    }

    func start(
        channel: PeerSessionChannel,
        displayID: CGDirectDisplayID,
        sessionID: String,
        deviceID: String,
        deviceName: String,
        capabilities: Set<SessionCapability>
    ) async throws {
        guard channel.currentState == .active,
              channel.currentCapabilities.contains(.viewScreen) else {
            throw PeerSessionError.controlNotAuthorized
        }
        // The same phone back while its run went on without it: the run stays, and only the
        // old session's input approval ends.
        let resumingRun = detachedRun?.deviceID == deviceID
        if resumingRun {
            detachedRun?.limit.cancel()
            detachedRun = nil
            await inputBroker.stopControl()
            ActivityLog.shared.write(.assistant, "The phone is back; the run goes on with it")
        } else {
            await stop(closeReason: "replaced-on-mac")
        }
        if runTraceDeviceID != deviceID {
            runTrace = []
            runTraceMissed = false
            runTraceDeviceID = nil
        }
        self.channel = channel
        self.displayID = displayID
        self.sessionID = sessionID
        self.deviceID = deviceID
        await inputBroker.resumeAcceptingNewSessions()
        await inputBroker.register(
            SessionApprovalRequest(
                sessionID: sessionID,
                deviceID: deviceID,
                deviceName: deviceName,
                requestedCapabilities: capabilities,
                expiresAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 60 * 1_000_000_000
            )
        )
        try await inputBroker.approve(
            sessionID: sessionID,
            capabilities: capabilities,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        channel.onPacket = { [weak self] packet in
            switch packet {
            case let .input(event):
                Task { await self?.handleInput(event) }
            case let .agentInstruction(instruction):
                Task { await self?.handleInstruction(instruction) }
            case let .agentControl(control):
                Task { await self?.handleControl(control) }
            default:
                break
            }
        }
        try await captureService.start(displayID: displayID)
        frameTask = Task { [weak self, captureService] in
            for await frame in captureService.frames {
                guard !Task.isCancelled else { return }
                await self?.encode(frame)
            }
        }
        if capabilities.contains(.runAgentActions) {
            if resumingRun, assistant != nil {
                await sendStatus(isRunning: true)
            } else {
                await prepareAssistant()
            }
            await replayMissedTrace(to: channel, deviceID: deviceID)
        } else if resumingRun {
            await assistant?.stop()
        }
    }

    /// Ends the session. With `keepingRun`, a run in progress goes on without the phone (see
    /// `detachedRun`); everything else about the session ends either way.
    func stop(closeReason: String? = nil, keepingRun: Bool = false) async {
        let previousChannel = channel
        channel = nil
        previousChannel?.onPacket = nil
        if let closeReason {
            previousChannel?.close(reason: closeReason)
        }
        frameTask?.cancel()
        frameTask = nil
        isEncoding = false
        encoder.invalidate()
        encoderConfiguration = nil
        await captureService.stop()
        latestFrame = nil
        lastLoggedInputFailure = nil
        if keepingRun, let assistant, await assistant.isRunning, let sessionID, let deviceID {
            let limit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.detachedRunLimitNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.stopDetachedRun(why: "the phone did not come back within 10 minutes")
            }
            detachedRun = (deviceID, sessionID, limit)
            ActivityLog.shared.write(.assistant, "The phone went quiet mid-run; the run goes on without it for up to 10 minutes")
            return
        }
        detachedRun?.limit.cancel()
        detachedRun = nil
        await inputBroker.stopControl()
        await MainActor.run { OrielPointer.shared.hide() }
        sessionID = nil
        deviceID = nil
        if let assistant {
            if await assistant.isRunning {
                ActivityLog.shared.write(.assistant, "The run was cut off: the session ended while the assistant was working")
            }
            await assistant.stop()
            await assistant.releaseModels()
        }
        assistant = nil
        assistantConfiguration = nil
        await MainActor.run { AssistantStatus.shared.reset() }
    }

    private func handleInput(_ event: RemoteInputEvent) async {
        guard let channel, let sessionID,
              channel.currentState == .active else { return }
        do {
            try await inputBroker.execute(
                event,
                sessionID: sessionID,
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                displayID: displayID
            )
        } catch {
            logInputFailure(error)
        }
    }

    private func logInputFailure(_ error: any Error) {
        let message = String(describing: error)
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastLoggedInputFailure, last.message == message,
           now - last.atNanoseconds < 10_000_000_000 {
            return
        }
        lastLoggedInputFailure = (message, now)
        ActivityLog.shared.write(.input, "Input from the phone failed: \(message)")
    }

    // MARK: Assistant

    /// The assistant exists for a session only when the phone was approved for it and the Mac
    /// has a model configured. Nothing is loaded here; models load on the first step of a run.
    private func prepareAssistant() async {
        let configuration = await MainActor.run { AssistantSettings.shared.runConfiguration() }
        assistantConfiguration = configuration
        guard let configuration else {
            await sendStatus(isRunning: false)
            return
        }
        let observer = await MainActor.run { ScreenObserver() }
        let displayID = self.displayID
        let dependencies = AssistantRuntime.Dependencies(
            observe: { [weak self] includeScreenshot, includeShapes in
                let frame = await self?.latestFrame
                let result = try await observer.observe(
                    frame: frame, displayID: displayID,
                    includeScreenshot: includeScreenshot, includeShapes: includeShapes
                )
                if ProcessInfo.processInfo.environment["ORIEL_DEBUG_OBSERVATIONS"] == "1" {
                    // Development only: the whole screen description each step, next to the log.
                    let folder = ActivityLog.shared.directory.appendingPathComponent("observations", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = "observation-\(DispatchTime.now().uptimeNanoseconds).txt"
                    try? AgentObservationRenderer.render(result.observation, maximumBytes: 2_000_000)
                        .write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                return result
            },
            execute: { [weak self] event in
                guard let self else { throw PeerSessionError.controlNotAuthorized }
                try await self.executeForAssistant(event)
            },
            openApplication: { name in
                try await ApplicationLauncher.open(name)
            },
            emit: { [weak self] event in
                Task { await self?.forwardTrace(event) }
            },
            phaseChanged: { [weak self] phase in
                Task { await self?.assistantPhaseChanged(phase) }
            },
            now: { DispatchTime.now().uptimeNanoseconds },
            resolveApplication: { name in
                await MainActor.run { ApplicationLauncher.exactName(name) }
            },
            log: { line in
                ActivityLog.shared.write(.assistant, ActivityLogRedaction.scrub(line))
            },
            landsOnOriel: { point in
                await OrielWindows.receiveInput(at: point, displayID: displayID)
            }
        )
        let runtime = AssistantRuntime(configuration: configuration, dependencies: dependencies)
        assistant = runtime
        await sendStatus(isRunning: false)
        // The phone just connected: load the models now, not when the first instruction comes.
        Task { await runtime.warmModels() }
    }

    private func executeForAssistant(_ event: RemoteInputEvent) async throws {
        guard let sessionID, channel?.currentState == .active || detachedRun != nil else {
            throw PeerSessionError.controlNotAuthorized
        }
        try await inputBroker.execute(
            event,
            sessionID: sessionID,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
            displayID: displayID
        )
    }

    private func handleInstruction(_ instruction: AgentInstruction) async {
        guard let channel, channel.currentState == .active else { return }
        guard let assistant else {
            ActivityLog.shared.write(.assistant, "Instruction refused: no model is configured on the Mac")
            if let event = try? AgentTraceEvent(
                instructionID: instruction.id, stepIndex: 0, kind: .failed,
                summary: "No model is configured on the Mac. Open Oriel on the Mac, Permissions & Diagnostics, Assistant.",
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
            ) {
                try? channel.send(.agentTrace(event))
            }
            return
        }
        if let configuration = assistantConfiguration {
            ActivityLog.shared.write(.assistant, "Run \(instruction.id.prefix(8)) received: "
                + ActivityLogRedaction.instruction(instruction.text)
                + "; \(Self.describe(configuration.planner)); \(Self.describe(configuration.executor))"
                + ", up to \(min(instruction.maximumSteps, configuration.maximumSteps)) steps")
        }
        await MainActor.run {
            AssistantStatus.shared.began(instruction)
            AssistantStatus.shared.stopRequest = { Task { await assistant.stop() } }
        }
        await assistant.run(instruction)
    }

    static func describe(_ role: AssistantModelRole) -> String {
        role.displayName + (role.visionModel.map { ", eyes \($0)" } ?? "")
    }

    private func handleControl(_ control: AgentControl) async {
        ActivityLog.shared.write(.assistant, "The phone sent: \(ActivityLogRedaction.control(control))")
        await assistant?.control(control)
    }

    private func forwardTrace(_ event: AgentTraceEvent) async {
        if event.kind == .started {
            runTrace = []
            runTraceMissed = false
            runTraceDeviceID = deviceID
        }
        runTrace.append(event)
        if runTrace.count > Self.runTraceLimit { runTrace.removeFirst(runTrace.count - Self.runTraceLimit) }
        let delivered = (try? channel?.send(.agentTrace(event))) != nil
        if !delivered { runTraceMissed = true }
        ActivityLog.shared.write(.assistant, ActivityLogRedaction.trace(event)
            + (delivered ? "" : " (not delivered: the phone is not connected; kept for when it comes back)"))
        await MainActor.run { AssistantStatus.shared.record(event) }
    }

    /// The phone that started the latest run gets the run again when it missed part of it:
    /// its view of the run starts empty on every connection.
    private func replayMissedTrace(to channel: PeerSessionChannel, deviceID: String) async {
        guard runTraceMissed, runTraceDeviceID == deviceID, !runTrace.isEmpty else { return }
        for event in runTrace { try? channel.send(.agentTrace(event)) }
        runTraceMissed = false
        ActivityLog.shared.write(.assistant, "Sent the phone the \(runTrace.count) trace lines of the run it missed")
    }

    /// Ends a run that went on without its phone (the time limit, the phone removed on the Mac).
    func stopDetachedRun(why: String) async {
        guard detachedRun != nil else { return }
        ActivityLog.shared.write(.assistant, "The run without its phone was stopped: \(why)")
        await assistant?.stop()
        await finishDetachedRun()
    }

    /// A run without its phone has ended: the approval it ran under ends with it.
    private func finishDetachedRun() async {
        guard let run = detachedRun else { return }
        run.limit.cancel()
        detachedRun = nil
        sessionID = nil
        await inputBroker.stopControl()
        await MainActor.run { OrielPointer.shared.hide() }
    }

    private func assistantPhaseChanged(_ phase: AssistantRunPhase) async {
        await MainActor.run { AssistantStatus.shared.update(phase: phase) }
        if !phase.isActive, detachedRun != nil {
            ActivityLog.shared.write(.assistant, "The run ended while the phone was away; the phone gets the outcome when it reconnects")
            await finishDetachedRun()
        }
        await sendStatus(isRunning: phase.isActive)
    }

    private func sendStatus(isRunning: Bool) async {
        guard let channel, channel.currentState == .active else { return }
        let summary = await MainActor.run {
            AssistantSettings.shared.providerSummary(isRunning: isRunning)
        }
        try? channel.send(.agentStatus(summary))
    }

    // MARK: Video

    private func encode(_ frame: CaptureFrame) {
        latestFrame = frame
        guard !isEncoding, let channel,
              channel.currentState == .active else { return }
        do {
            let outputDimensions = try VideoOutputDimensions.networkAspectFit(
                sourceWidth: frame.metadata.pixelWidth,
                sourceHeight: frame.metadata.pixelHeight
            )
            let configuration = try VideoEncoderConfiguration(
                width: outputDimensions.width,
                height: outputDimensions.height,
                framesPerSecond: 30,
                averageBitRate: 6_000_000
            )
            if encoderConfiguration != configuration {
                try encoder.configure(configuration)
                encoderConfiguration = configuration
            }
            isEncoding = true
            try encoder.encode(
                frame.pixelBuffer,
                sequence: frame.metadata.sequence,
                presentationTimeNanoseconds: frame.metadata.monotonicTimestampNanoseconds,
                forceKeyFrame: frame.metadata.sequence == 1
            ) { [weak self] result in
                Task { await self?.finishEncoding(result) }
            }
        } catch {
            isEncoding = false
        }
    }

    private func finishEncoding(
        _ result: Result<EncodedVideoFrame, VideoEncoderError>
    ) {
        defer { isEncoding = false }
        guard case let .success(frame) = result, let channel else { return }
        try? channel.send(
            .video(
                .init(
                    sequence: frame.sequence,
                    presentationTimeNanoseconds: frame.presentationTimeNanoseconds,
                    isKeyFrame: frame.isKeyFrame,
                    payload: frame.payload,
                    parameterSets: frame.parameterSets
                )
            )
        )
    }
}

/// Opens an app by its name ("Notes", "Safari") or bundle identifier.
@MainActor
enum ApplicationLauncher {
    static let searchDirectories = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
        "/Applications/Utilities", NSHomeDirectory() + "/Applications",
    ]

    static func open(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            running.activate()
            return
        }
        let url = try locate(trimmed)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The app's own name when `name` is exactly an app that is running or installed; no
    /// loose matching, so "Open Dana's DM" is never mistaken for an app.
    static func exactName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return running.localizedName
        }
        let wanted = trimmed.lowercased() + ".app"
        for directory in searchDirectories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            if let exact = items.first(where: { $0.lowercased() == wanted }) {
                return String(exact.dropLast(4))
            }
        }
        return nil
    }

    static func locate(_ name: String) throws -> URL {
        if name.contains("."), !name.lowercased().hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return url
        }
        let wanted = name.lowercased().hasSuffix(".app") ? name.lowercased() : name.lowercased() + ".app"
        var loose: URL?
        for directory in searchDirectories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            if let exact = items.first(where: { $0.lowercased() == wanted }) {
                return URL(fileURLWithPath: directory).appendingPathComponent(exact)
            }
            if loose == nil, let prefix = items.first(where: {
                $0.lowercased().hasSuffix(".app") && $0.lowercased().hasPrefix(String(wanted.dropLast(4)))
            }) {
                loose = URL(fileURLWithPath: directory).appendingPathComponent(prefix)
            }
        }
        if let loose { return loose }
        throw AssistantRuntimeError.applicationNotFound(name)
    }
}
