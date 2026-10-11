import AppKit
import CoreGraphics
import Darwin
import Foundation
import HermesCaptureCore
import HermesCaptureProtocol

/// One goal from a local tool, as goal.json gives it.
struct LocalAssistantGoal: Equatable, Sendable {
    static let maximumSteps = 30

    struct Invalid: Error, Equatable {
        /// Nil when goal.json held no readable id.
        let id: String?
        let why: String
    }

    let instruction: AgentInstruction
    /// The app the run is confined to.
    let app: String?
    /// The exact texts the run may type.
    let typeAllowed: [String]
    /// The run may observe and answer but send no input.
    let readOnly: Bool

    var id: String { instruction.id }

    private struct Header: Decodable {
        let id: String?
    }

    private struct Wire: Decodable {
        let instruction: String?
        let app: String?
        let maxSteps: Int?
        let typeAllowed: [String]?
        let readOnly: Bool?
    }

    static func parse(_ data: Data) throws -> LocalAssistantGoal {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw Invalid(id: nil, why: "goal.json is not one JSON object with a string \"id\"")
        }
        guard let id = header.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(id: nil, why: "\"id\" is missing or empty")
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch let DecodingError.typeMismatch(_, context) {
            throw Invalid(id: id, why: "\"\(context.codingPath.first?.stringValue ?? "?")\" has the wrong type")
        } catch {
            throw Invalid(id: id, why: "goal.json could not be read")
        }
        guard let text = wire.instruction, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(id: id, why: "\"instruction\" is missing or empty")
        }
        guard let maxSteps = wire.maxSteps else { throw Invalid(id: id, why: "\"maxSteps\" is missing") }
        guard (1...maximumSteps).contains(maxSteps) else {
            throw Invalid(id: id, why: "\"maxSteps\" must be 1 to \(maximumSteps)")
        }
        let app = wire.app?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app, app.isEmpty { throw Invalid(id: id, why: "\"app\" is empty") }
        let instruction: AgentInstruction
        do {
            instruction = try AgentInstruction(id: id, text: text, maximumSteps: maxSteps)
        } catch {
            throw Invalid(id: id, why: "\"instruction\" is too long or holds a NUL character")
        }
        return LocalAssistantGoal(instruction: instruction, app: app, typeAllowed: wire.typeAllowed ?? [],
                                  readOnly: wire.readOnly ?? false)
    }

    /// The last word on an action of this goal's run, after the policy. Nobody is there to
    /// approve, so what the policy would ask about ends the run; it clicks only listed things
    /// with a label (the policy's sign and attest rules read labels), types only `typeAllowed`,
    /// opens only `app`, and its input goes only to `app`.
    func vet(_ action: AgentAction, in observation: AgentObservation, policy: AgentApprovalDecision,
             frontmostApplication: String?) -> AgentApprovalDecision {
        if readOnly, action.movesTheMac {
            return .block(reason: "read-only run")
        }
        switch action {
        case .click, .type, .key, .scroll:
            if let app, frontmostApplication?.caseInsensitiveCompare(app) != .orderedSame {
                return .block(reason: "\(app) is not in front (\(frontmostApplication ?? "no app") is), so nothing was sent.")
            }
        default:
            break
        }
        guard case .allow = policy else { return policy }
        switch action {
        case let .click(target, _, _):
            guard case let .element(id) = target, Self.label(of: id, in: observation) != nil else {
                return .block(reason: "A local run clicks only a listed control or text line with a label, not a screen point or an unlabelled region.")
            }
        case let .type(text):
            guard typeAllowed.contains(text) else {
                return .block(reason: "Typing text that is not in typeAllowed (\(text.count) characters) was refused.")
            }
        case let .openApplication(name):
            guard let app, name.caseInsensitiveCompare(app) == .orderedSame else {
                return .block(reason: "Opening \(name) was refused: a local run opens only its goal's app" + (app.map { " (\($0))." } ?? ", and this goal names none."))
            }
        default:
            break
        }
        return .allow
    }

    /// The label the policy reads for a click on `id`; nil for an unknown id, an empty label or
    /// a shape region (its label is only "region").
    static func label(of id: String, in observation: AgentObservation) -> String? {
        if let element = observation.element(id: id) {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return element.role == "region" || label.isEmpty ? nil : label
        }
        if let text = observation.text(id: id) {
            let label = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : label
        }
        return nil
    }
}

/// result.json.
struct LocalAssistantResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case done
        case failed
        case cancelled
        case needsApproval = "needs_approval"
        case blocked
        case timeout
        case busy
        case invalid
    }

    let id: String?
    let status: Status
    var answer: String? = nil
    var steps = 0
    var elapsedMs = 0
    var why: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, status, answer, steps, elapsedMs, why
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Null rather than missing when goal.json held no readable id.
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(answer, forKey: .answer)
        try container.encode(steps, forKey: .steps)
        try container.encode(elapsedMs, forKey: .elapsedMs)
        try container.encodeIfPresent(why, forKey: .why)
    }
}

/// What a local run reads and drives on this Mac; tests replace it.
struct LocalAssistantMachine: Sendable {
    var observe: @Sendable (_ includeScreenshot: Bool, _ includeShapes: Bool) async throws -> ScreenObservationResult
    var execute: @Sendable (RemoteInputEvent) async throws -> Void
    var openApplication: @Sendable (String) async throws -> Void
    var resolveApplication: @Sendable (String) async -> String?
    var landsOnOriel: @Sendable (NormalizedPoint?) async -> Bool
    var frontmostApplication: @Sendable () async -> String?
    /// Input is authorized for one run, from its start to its end.
    var beginInput: @Sendable (_ runID: String) async throws -> Void
    var endInput: @Sendable () async -> Void
}

/// Hands the assistant one goal at a time from a local process, through files in
/// ~/.hermes/cache/oriel/assistant, and writes back the run's trace and result. It runs the
/// phone's assistant runtime with the Mac's model settings, with no one to approve or answer
/// (see `LocalAssistantGoal.vet` and docs/COMPATIBILITY.md).
@MainActor
final class LocalAssistantBridge {
    static var defaultDirectory: URL {
        LocalCaptureBridge.defaultCacheDirectory.appendingPathComponent("assistant", isDirectory: true)
    }

    /// A run still going after this is stopped and reported as a timeout.
    static let defaultRunTimeLimit: Duration = .seconds(600)

    private let directory: URL
    private let pollInterval: Duration
    private let runTimeLimit: Duration
    private let machine: LocalAssistantMachine
    private let configuration: @MainActor () -> AssistantRunConfiguration?
    private let phoneRunActive: @MainActor () -> Bool
    private var pollTask: Task<Void, Never>?
    private var lastGoalFile: FileStamp?
    private var usedIDs: Set<String> = []
    private var active: (run: LocalAssistantRun, runtime: AssistantRuntime)?
    /// Models stay loaded between local runs, the way they do between a phone's instructions;
    /// the last runtime lets them go when the bridge stops.
    private var lastRuntime: AssistantRuntime?

    private var goalURL: URL { directory.appendingPathComponent("goal.json") }
    private var resultURL: URL { directory.appendingPathComponent("result.json") }
    private var traceURL: URL { directory.appendingPathComponent("trace.jsonl") }
    private var cancelURL: URL { directory.appendingPathComponent("cancel") }

    init(
        directory: URL,
        pollInterval: Duration = .milliseconds(50),
        runTimeLimit: Duration = LocalAssistantBridge.defaultRunTimeLimit,
        machine: LocalAssistantMachine,
        configuration: @escaping @MainActor () -> AssistantRunConfiguration?,
        phoneRunActive: @escaping @MainActor () -> Bool
    ) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.runTimeLimit = runTimeLimit
        self.machine = machine
        self.configuration = configuration
        self.phoneRunActive = phoneRunActive
    }

    static func makeDefault() -> LocalAssistantBridge {
        let displayID = CGMainDisplayID()
        let observer = ScreenObserver()
        let input = LocalAssistantInput(displayID: displayID)
        let machine = LocalAssistantMachine(
            observe: { includeScreenshot, includeShapes in
                // A run never asks for Screen Recording; without it there is nothing to read.
                guard CGPreflightScreenCaptureAccess() else { throw LocalAssistantInput.Failure.screenRecordingNotGranted }
                return try await observer.observe(frame: nil, displayID: displayID,
                                                  includeScreenshot: includeScreenshot, includeShapes: includeShapes)
            },
            execute: { event in try await input.execute(event) },
            openApplication: { name in try await ApplicationLauncher.open(name) },
            resolveApplication: { name in await MainActor.run { ApplicationLauncher.exactName(name) } },
            landsOnOriel: { point in await OrielWindows.receiveInput(at: point, displayID: displayID) },
            frontmostApplication: { await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName } },
            beginInput: { runID in try await input.begin(runID) },
            endInput: { await input.end() }
        )
        return LocalAssistantBridge(
            directory: defaultDirectory,
            machine: machine,
            configuration: { AssistantSettings.shared.runConfiguration() },
            phoneRunActive: { AssistantStatus.shared.isActive }
        )
    }

    var isRunning: Bool { active != nil }

    func start() throws {
        guard pollTask == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // A goal written before the bridge started may be stale; only goals written from now run.
        lastGoalFile = FileStamp(goalURL)
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        if let active {
            active.run.requestStop(.cancelled, why: "Oriel quit before the run ended.")
            await active.runtime.stop()
            await finish(active.run, phase: active.run.phase ?? .stopped)
        }
        await lastRuntime?.releaseModels()
        lastRuntime = nil
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            await poll()
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    func poll() async {
        if let active {
            if let phase = active.run.phase, !phase.isActive, phase != .idle {
                await finish(active.run, phase: phase)
            } else if !active.run.stopping {
                if cancelRequested(for: active.run.goal.id) {
                    try? FileManager.default.removeItem(at: cancelURL)
                    active.run.requestStop(.cancelled, why: "Cancelled.")
                    await active.runtime.stop()
                } else if active.run.started.duration(to: .now) >= runTimeLimit {
                    active.run.requestStop(.timeout, why: "No result within \(runTimeLimit.components.seconds) seconds.")
                    await active.runtime.stop()
                }
            }
        }
        guard let stamp = FileStamp(goalURL), stamp != lastGoalFile else { return }
        lastGoalFile = stamp
        guard let data = try? Data(contentsOf: goalURL) else { return }
        await accept(data)
    }

    private func accept(_ data: Data) async {
        let goal: LocalAssistantGoal
        do {
            goal = try LocalAssistantGoal.parse(data)
        } catch {
            let invalid = error as? LocalAssistantGoal.Invalid ?? LocalAssistantGoal.Invalid(id: nil, why: String(describing: error))
            ActivityLog.shared.write(.assistant, "Local goal refused: \(ActivityLogRedaction.scrub(invalid.why))")
            write(LocalAssistantResult(id: invalid.id, status: .invalid, why: invalid.why))
            return
        }
        guard !usedIDs.contains(goal.id) else { return }
        if active != nil || phoneRunActive() {
            let why = active != nil ? "Another local run is in progress." : "A run from the phone is in progress."
            ActivityLog.shared.write(.assistant, "Local run \(goal.id.prefix(8)) refused: \(why)")
            write(LocalAssistantResult(id: goal.id, status: .busy, why: why))
            return
        }
        usedIDs.insert(goal.id)
        guard var configuration = configuration() else {
            ActivityLog.shared.write(.assistant, "Local run \(goal.id.prefix(8)) refused: no model is configured on the Mac")
            write(LocalAssistantResult(id: goal.id, status: .failed,
                                       why: "No model is configured on the Mac. Open Oriel on the Mac, Permissions & Diagnostics, Assistant."))
            return
        }
        configuration.readOnly = goal.readOnly
        do {
            try await machine.beginInput(goal.id)
        } catch {
            write(LocalAssistantResult(id: goal.id, status: .failed, why: "Input could not be authorized: \(error)"))
            return
        }
        let run = LocalAssistantRun(goal: goal, traceURL: traceURL)
        let runtime = AssistantRuntime(configuration: configuration, dependencies: dependencies(for: run))
        ActivityLog.shared.write(.assistant, "Local run \(goal.id.prefix(8)) received: "
            + ActivityLogRedaction.instruction(goal.instruction.text)
            + "; \(MacRemoteSessionController.describe(configuration.planner)); \(MacRemoteSessionController.describe(configuration.executor))"
            + ", up to \(min(goal.instruction.maximumSteps, configuration.maximumSteps)) steps"
            + (goal.app.map { ", only in \($0)" } ?? "") + ", \(goal.typeAllowed.count) texts it may type"
            + (goal.readOnly ? ", read-only" : ""))
        active = (run, runtime)
        lastRuntime = runtime
        await runtime.run(goal.instruction)
    }

    private func dependencies(for run: LocalAssistantRun) -> AssistantRuntime.Dependencies {
        let machine = self.machine
        let goal = run.goal
        var dependencies = AssistantRuntime.Dependencies(
            observe: machine.observe,
            execute: { event in
                // Nothing reaches the Mac once the run ended or was told to stop.
                guard run.inputOpen else { throw CancellationError() }
                try await machine.execute(event)
            },
            openApplication: { name in
                guard run.inputOpen else { throw CancellationError() }
                try await machine.openApplication(name)
            },
            emit: { event in run.record(event) },
            phaseChanged: { phase in run.phase = phase },
            now: { DispatchTime.now().uptimeNanoseconds },
            resolveApplication: machine.resolveApplication,
            log: { line in
                ActivityLog.shared.write(.assistant, ActivityLogRedaction.scrub(line))
            },
            landsOnOriel: machine.landsOnOriel
        )
        dependencies.unattendedGate = { action, observation, decision in
            let verdict = goal.vet(action, in: observation, policy: decision,
                                   frontmostApplication: await machine.frontmostApplication())
            run.refused(verdict)
            return verdict
        }
        return dependencies
    }

    private func finish(_ run: LocalAssistantRun, phase: AssistantRunPhase) async {
        guard active?.run === run else { return }
        active = nil
        run.close()
        await machine.endInput()
        var result = LocalAssistantResult(id: run.goal.id, status: .failed, steps: run.steps, elapsedMs: run.elapsedMilliseconds)
        switch phase {
        case let .finished(summary):
            result = LocalAssistantResult(id: run.goal.id, status: .done, answer: summary, steps: run.steps, elapsedMs: run.elapsedMilliseconds)
        case .stopped:
            let reason = run.stopReason ?? (.cancelled, "Stopped.")
            result = LocalAssistantResult(id: run.goal.id, status: reason.status, steps: run.steps,
                                          elapsedMs: run.elapsedMilliseconds, why: reason.why)
        case let .failed(why):
            let refusal = run.refusal
            result = LocalAssistantResult(id: run.goal.id, status: refusal?.status ?? .failed, steps: run.steps,
                                          elapsedMs: run.elapsedMilliseconds, why: refusal?.why ?? why)
        default:
            result = LocalAssistantResult(id: run.goal.id, status: run.stopReason?.status ?? .failed, steps: run.steps,
                                          elapsedMs: run.elapsedMilliseconds, why: run.stopReason?.why ?? "The run ended early.")
        }
        write(result)
        ActivityLog.shared.write(.assistant, "Local run \(run.goal.id.prefix(8)) ended: \(result.status.rawValue)"
            + " after \(result.steps) steps, \(result.elapsedMs) ms" + (result.why.map { ": " + ActivityLogRedaction.scrub($0) } ?? ""))
    }

    private func cancelRequested(for id: String) -> Bool {
        guard let text = try? String(contentsOf: cancelURL, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == id
    }

    private func write(_ result: LocalAssistantResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            // Written beside the old file and renamed over it, so a reader never sees half of one.
            try encoder.encode(result).write(to: resultURL, options: .atomic)
        } catch {
            NSLog("Oriel could not write the local goal result: %@", String(describing: error))
        }
    }
}

/// A file's identity: an atomic replace changes the inode even when the bytes are the same.
struct FileStamp: Equatable {
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }
}

/// One local run: its trace file, phase, and what ended it. Written from the runtime's actor,
/// read by the bridge.
private final class LocalAssistantRun: @unchecked Sendable {
    private struct TraceLine: Encodable {
        let t: String
        let kind: String
        let text: String
    }

    let goal: LocalAssistantGoal
    let started = ContinuousClock.now
    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentPhase: AssistantRunPhase?
    private var lastStep = 0
    private var stopRequest: (status: LocalAssistantResult.Status, why: String)?
    private var refusalVerdict: (status: LocalAssistantResult.Status, why: String)?
    private var open = true

    init(goal: LocalAssistantGoal, traceURL: URL) {
        self.goal = goal
        // Each run starts its own trace.
        let descriptor = Darwin.open(traceURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o600)
        handle = descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
    }

    var phase: AssistantRunPhase? {
        get { lock.withLock { currentPhase } }
        set { lock.withLock { currentPhase = newValue } }
    }

    var steps: Int { lock.withLock { lastStep } }
    var stopReason: (status: LocalAssistantResult.Status, why: String)? { lock.withLock { stopRequest } }
    var stopping: Bool { lock.withLock { stopRequest != nil } }
    var refusal: (status: LocalAssistantResult.Status, why: String)? { lock.withLock { refusalVerdict } }

    var elapsedMilliseconds: Int {
        let elapsed = started.duration(to: .now).components
        return Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// False once the run ended or was told to stop.
    var inputOpen: Bool {
        lock.withLock {
            guard open, stopRequest == nil else { return false }
            switch currentPhase {
            case .finished?, .failed?, .stopped?: return false
            default: return true
            }
        }
    }

    func record(_ event: AgentTraceEvent) {
        let line = TraceLine(t: Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                             kind: event.kind.rawValue, text: ActivityLogRedaction.summary(event))
        let data = (try? JSONEncoder().encode(line)).map { $0 + Data("\n".utf8) }
        lock.withLock {
            guard open else { return }
            lastStep = max(lastStep, event.stepIndex)
            if let data { try? handle?.write(contentsOf: data) }
        }
        ActivityLog.shared.write(.assistant, ActivityLogRedaction.trace(event))
    }

    func refused(_ verdict: AgentApprovalDecision) {
        lock.withLock {
            switch verdict {
            case .allow: break
            case let .block(reason): refusalVerdict = (.blocked, reason)
            case let .requireApproval(reason): refusalVerdict = (.needsApproval, reason)
            }
        }
    }

    func requestStop(_ status: LocalAssistantResult.Status, why: String) {
        lock.withLock { if stopRequest == nil { stopRequest = (status, why) } }
    }

    func close() {
        lock.withLock {
            open = false
            try? handle?.close()
            handle = nil
        }
    }
}

/// The input broker for local runs: its session check lets input through for one run at a
/// time, from the run's start to its end.
actor LocalAssistantInput {
    enum Failure: Error, CustomStringConvertible {
        case screenRecordingNotGranted
        case noRunInProgress

        var description: String {
            switch self {
            case .screenRecordingNotGranted: "Oriel has no Screen Recording access"
            case .noRunInProgress: "no local run is in progress"
            }
        }
    }

    private let broker = InputBroker()
    private let displayID: CGDirectDisplayID
    private var sessionID: String?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func begin(_ runID: String) async throws {
        let sessionID = "local-\(runID)"
        let now = DispatchTime.now().uptimeNanoseconds
        let capabilities: Set<SessionCapability> = [.controlPointer, .typeText]
        await broker.resumeAcceptingNewSessions()
        await broker.register(SessionApprovalRequest(
            sessionID: sessionID, deviceID: "local-goal-bridge", deviceName: "Local goal bridge",
            requestedCapabilities: capabilities, expiresAtNanoseconds: now + 60 * 60 * 1_000_000_000
        ))
        try await broker.approve(sessionID: sessionID, capabilities: capabilities, nowNanoseconds: now)
        self.sessionID = sessionID
    }

    func execute(_ event: RemoteInputEvent) async throws {
        guard let sessionID else { throw Failure.noRunInProgress }
        try await broker.execute(event, sessionID: sessionID, nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                 displayID: displayID)
    }

    func end() async {
        sessionID = nil
        await broker.stopControl()
        await MainActor.run { OrielPointer.shared.hide() }
    }
}
