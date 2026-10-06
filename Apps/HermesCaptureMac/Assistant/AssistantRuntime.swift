import Foundation
import HermesCaptureCore
import HermesCaptureProtocol

enum AssistantRunPhase: Equatable, Sendable {
    case idle
    case running(step: Int, of: Int)
    case paused
    case waitingApproval(stepID: String)
    case waitingAnswer(stepID: String)
    case finished(summary: String)
    case failed(reason: String)
    case stopped

    var isActive: Bool {
        switch self {
        case .running, .paused, .waitingApproval, .waitingAnswer: true
        default: false
        }
    }
}

/// One model in one role: where it runs decides what it may see.
struct AssistantModelRole: Sendable {
    let provider: any AssistantModelProvider
    let model: String
    /// The executor's vision model; nil for the planner, which never sees pixels.
    let visionModel: String?
    /// Where the vision model runs when the executor's own provider cannot see pixels.
    var visionProvider: (any AssistantModelProvider)? = nil
    let locality: ModelLocality
    let displayName: String
}

/// A snapshot the runtime takes at the start of a run; settings edits apply to the next run.
struct AssistantRunConfiguration: Sendable {
    let planner: AssistantModelRole
    let executor: AssistantModelRole
    let visionPolicy: AssistantVisionPolicy
    let screenshotsAllowedToRemote: Bool
    /// Executor steps per instruction, all sub-tasks together.
    let maximumSteps: Int
    /// Executor steps per sub-task before the planner is asked again.
    let stepsPerSubtask: Int
    /// The planner reviews the executor's work every this many steps (and at once when an
    /// action changed nothing), while the executor keeps going; 0 turns reviews off.
    var reviewEverySteps: Int = 3

    func executorMayShareScreenshots(instructionAllows: Bool) -> Bool {
        ScreenshotSharingPolicy.mayShareScreenshots(
            locality: executor.locality,
            remoteSharingEnabled: screenshotsAllowedToRemote,
            instructionAllows: instructionAllows
        )
    }
}

/// Two brains. The planner (big, slow, text only) turns the owner's goal into small
/// sub-tasks and pre-scripts the certain ones as direct actions; the executor (small, fast)
/// works each sub-task against the screen without waiting on the planner, and reports back
/// only at sub-task boundaries or when stuck. Policy runs before every action, the phone can
/// pause, stop, approve, deny and answer, and models are released when the run ends.
actor AssistantRuntime {
    struct Dependencies: Sendable {
        let observe: @Sendable (_ includeScreenshot: Bool, _ includeShapes: Bool) async throws -> ScreenObservationResult
        let execute: @Sendable (RemoteInputEvent) async throws -> Void
        let openApplication: @Sendable (String) async throws -> Void
        let emit: @Sendable (AgentTraceEvent) -> Void
        let phaseChanged: @Sendable (AssistantRunPhase) -> Void
        let now: @Sendable () -> UInt64
        /// The app's own name when a name is an app on this Mac, else nil.
        var resolveApplication: @Sendable (String) async -> String? = { _ in nil }
        /// A line for the Mac's activity log (decisions the trace does not show).
        var log: @Sendable (String) -> Void = { _ in }
        /// Whether input would land in Oriel's own windows: the window under a point, or with
        /// no point (keyboard input) the window that has the keyboard.
        var landsOnOriel: @Sendable (NormalizedPoint?) async -> Bool = { _ in false }
    }

    struct StepRecord: Sendable {
        let index: Int
        let reason: String
        let action: AgentAction
        var result: String
    }

    enum SubtaskResult: Equatable, Sendable {
        case completed(summary: String)
        case stuck(reason: String)
        case budgetExceeded
        case ended
        /// The planner, watching, replaced the rest of the plan.
        case replanned([AssistantSubtask])
        /// The planner, watching, saw the goal met.
        case answered(String)
    }

    private var reviewTask: Task<Void, Never>?
    private var reviewToken = 0
    private var reviewResult: (token: Int, review: AssistantReview)?

    static let settleDelayNanoseconds: UInt64 = 600_000_000
    static let approvalTimeoutNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
    static let historyWindow = 8
    static let maximumRevisions = 4

    private let configuration: AssistantRunConfiguration
    private let dependencies: Dependencies
    private(set) var phase: AssistantRunPhase = .idle {
        didSet { dependencies.phaseChanged(phase) }
    }
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var pauseRequested = false
    private var pendingApproval: (stepID: String, decision: Bool?)?
    private var pendingAnswer: (stepID: String, text: String?)?
    private var plannerModelsUsed: Set<String> = []
    private var executorModelsUsed: Set<String> = []
    private var totalSteps = 0
    private var runEnded = false
    /// Apps this run already brought to the front, so a plan's own "Open Slack" is not repeated.
    private var openedApplications: Set<String> = []

    /// What happened earlier in this session, so a follow-up instruction can build on it.
    struct Episode: Sendable {
        let instruction: String
        let outcome: String
        let endedAt: Date
    }
    static let episodeLimit = 10
    private var episodes: [Episode] = []

    private var sessionHistoryLines: [String] {
        episodes.map { "\($0.instruction) → \($0.outcome)" }
    }

    init(configuration: AssistantRunConfiguration, dependencies: Dependencies) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    var isRunning: Bool { phase.isActive }

    func run(_ instruction: AgentInstruction) {
        guard !phase.isActive else {
            emit(instruction, step: totalSteps, kind: .failed, summary: "A run is already in progress. Stop it first.")
            return
        }
        stopRequested = false
        pauseRequested = false
        pendingApproval = nil
        pendingAnswer = nil
        plannerModelsUsed = []
        executorModelsUsed = []
        totalSteps = 0
        runEnded = false
        openedApplications = []
        phase = .running(step: 0, of: min(instruction.maximumSteps, configuration.maximumSteps))
        task = Task { [weak self] in
            await self?.runLoop(instruction)
        }
    }

    func control(_ control: AgentControl) {
        switch control {
        case .pause:
            guard phase.isActive else { return }
            pauseRequested = true
        case .resume:
            pauseRequested = false
        case .stop:
            stop()
        case let .approve(stepID):
            if pendingApproval?.stepID == stepID { pendingApproval?.decision = true }
        case let .deny(stepID):
            if pendingApproval?.stepID == stepID { pendingApproval?.decision = false }
        case let .answer(stepID, text):
            if pendingAnswer?.stepID == stepID { pendingAnswer?.text = text }
        }
    }

    func stop() {
        guard phase.isActive else { return }
        stopRequested = true
        pauseRequested = false
        task?.cancel()
    }

    /// Lets go of the models the run warmed up (Ollama, the built-in engine).
    func releaseModels() async {
        let planner = Array(plannerModelsUsed)
        let executor = Array(executorModelsUsed)
        plannerModelsUsed = []
        executorModelsUsed = []
        if !planner.isEmpty { await configuration.planner.provider.release(models: planner) }
        if let eyes = configuration.executor.visionProvider, let vision = configuration.executor.visionModel {
            if executor.contains(vision) { await eyes.release(models: [vision]) }
            let own = executor.filter { $0 != vision }
            if !own.isEmpty { await configuration.executor.provider.release(models: own) }
        } else if !executor.isEmpty {
            await configuration.executor.provider.release(models: executor)
        }
    }

    // MARK: Run

    private func runLoop(_ instruction: AgentInstruction) async {
        let maximumSteps = min(instruction.maximumSteps, configuration.maximumSteps)
        let screenshotsAllowed = configuration.executorMayShareScreenshots(instructionAllows: instruction.allowScreenshots)
        emit(instruction, step: 0, kind: .started,
             summary: "Working on: \(instruction.text)"
                + (screenshotsAllowed ? "" : " (models see a text description of the screen, never pixels)"))
        defer { Task { await self.releaseModels() } }

        // "Go to Slack, open Dana's DM": the app the owner named comes to the front before
        // anything is planned, whatever happened to be in front.
        for candidate in AssistantSubtask.applicationsMentioned(in: instruction.text) {
            guard let application = await dependencies.resolveApplication(candidate) else { continue }
            if let current = try? await dependencies.observe(false, false),
               current.observation.frontmostApplication?.caseInsensitiveCompare(application) != .orderedSame {
                let opening = AssistantSubtask(id: 0, goal: "Open \(application)", doneWhen: nil, directAction: .openApplication(name: application))
                if case .ended = await performDirect(.openApplication(name: application), subtask: opening, instruction: instruction) { return }
            }
            openedApplications.insert(application.lowercased())
            break
        }

        // "Open Dana's DM and read me the last message": in an app with a jump box, the named
        // conversation comes up before planning, so the planner starts from it.
        if let name = AssistantSubtask.conversationTarget(in: instruction.text) {
            let opening = AssistantSubtask(id: 0, goal: "Open \(name)", doneWhen: nil, directAction: nil)
            if case .ended? = await jump(to: name, subtask: opening, instruction: instruction) { return }
        }

        // Plan from what is on screen now.
        guard let observed = await observe(instruction, screenshot: false, shapes: false) else { return }
        var queue: [AssistantSubtask]
        let calculation = observed.observation.frontmostBundleIdentifier == "com.apple.calculator"
            ? AssistantSubtask.arithmeticExpression(in: instruction.text) : nil
        let conversationOpen = AssistantSubtask.conversationTarget(in: instruction.text).map {
            Self.showsConversation($0, title: observed.observation.windowTitle ?? "", bundleIdentifier: observed.observation.frontmostBundleIdentifier)
        } ?? false
        if conversationOpen, AssistantSubtask.wantsAnAnswer(instruction.text), AssistantSubtask.asksAboutLatest(instruction.text),
           !Self.asksToWrite(instruction.text) {
            // "Open Dana's DM and read me the last message": the conversation is open and its
            // newest messages are on screen, so nothing is left to plan; the answer is read below.
            queue = []
        } else if let calculation {
            // "Open Calculator, compute 12 times 7": clear what an earlier sum left on the display
            // (Escape is C, twice is AC) and type the sum; the answer is read off the display.
            queue = [
                AssistantSubtask(id: 1, goal: "Clear the display", doneWhen: nil, directAction: .key(name: "escape", modifiers: [])),
                AssistantSubtask(id: 2, goal: "Clear all", doneWhen: nil, directAction: .key(name: "escape", modifiers: [])),
                AssistantSubtask(id: 3, goal: "Type \(calculation)=", doneWhen: nil, directAction: .type(text: calculation + "=")),
            ]
            emitPlan(instruction, queue, note: nil)
        } else {
        switch await plan(instruction, message: AssistantPlanner.initialMessage(instruction: instruction, observation: observed.observation, history: sessionHistoryLines),
                          observation: observed.observation) {
        case let .plan(subtasks, note):
            queue = subtasks
            emitPlan(instruction, subtasks, note: note)
        case let .done(summary):
            finish(instruction, kind: .finished, summary: summary)
            return
        case let .ask(question):
            guard let answer = await askOwner(instruction, question: question, stepID: "\(instruction.id)#plan") else { return }
            switch await plan(instruction, message: AssistantPlanner.initialMessage(instruction: instruction, observation: observed.observation, history: sessionHistoryLines)
                              + "\n\nThe owner was asked: \(question)\nThe owner answered: \(answer)", observation: observed.observation) {
            case let .plan(subtasks, note):
                queue = subtasks
                emitPlan(instruction, subtasks, note: note)
            case let .done(summary):
                finish(instruction, kind: .finished, summary: summary)
                return
            case .ask:
                finish(instruction, kind: .failed, summary: "The planner keeps asking instead of planning.")
                return
            case nil:
                return
            }
        case nil:
            return
        }
        }

        var completed: [AssistantSubtaskReport] = []
        var revisions = 0
        /// The last finished sub-task was reached by navigation alone (an app opened, a jump,
        /// one click): a reading goal finished that way has not been read yet.
        var lastCompletedByNavigation = false
        while !queue.isEmpty {
            if await waitWhilePausedOrStopped(instruction) { return }
            if totalSteps >= maximumSteps {
                finish(instruction, kind: .failed, summary: "Reached the step limit (\(maximumSteps)) with sub-tasks left.")
                return
            }
            let subtask = queue.removeFirst()
            emit(instruction, step: totalSteps, kind: .subtask, summary: "Sub-task \(subtask.id): \(subtask.title)")

            let result: SubtaskResult
            let stepsBefore = totalSteps
            var navigationOnly = false
            if let direct = subtask.directAction {
                result = await performDirect(direct, subtask: subtask, instruction: instruction)
            } else if let text = AssistantSubtask.quotedTyping(in: subtask.goal) {
                // "Type '12*7=' into Calculator": the text is spelled out, so type it.
                result = await performDirect(.type(text: text), subtask: subtask, instruction: instruction)
            } else if let candidate = AssistantSubtask.applicationCandidate(in: subtask.goal),
                      let application = await dependencies.resolveApplication(candidate) {
                // "Open Slack" needs no model: the app is on this Mac, so open it (once per run).
                if openedApplications.contains(application.lowercased()) {
                    result = .completed(summary: "\(application) is open")
                } else {
                    result = await performDirect(.openApplication(name: application), subtask: subtask, instruction: instruction)
                    openedApplications.insert(application.lowercased())
                }
                navigationOnly = true
            } else if let name = AssistantSubtask.conversationTarget(in: subtask.goal),
                      let jumped = await jump(to: name, subtask: subtask, instruction: instruction) {
                result = jumped
                navigationOnly = true
            } else if AssistantSubtask.isReadingGoal(subtask.goal),
                      let name = AssistantSubtask.conversationTarget(in: instruction.text),
                      let observed = await observe(instruction, screenshot: false, shapes: false),
                      Self.showsConversation(name, title: observed.observation.windowTitle ?? "",
                                             bundleIdentifier: observed.observation.frontmostBundleIdentifier) {
                // "Read Dana's last message" with his DM open: the screen holds it; the answer is
                // read off it at the end instead of an executor clicking around the conversation.
                result = .completed(summary: "\(observed.observation.windowTitle ?? name) is open")
                navigationOnly = true
            } else if let name = AssistantSubtask.targetName(in: subtask.goal),
                      let observed = await observe(instruction, screenshot: false, shapes: false),
                      let target = Self.logged(AssistantSubtask.grounded(name, in: observed.observation), name, observed.observation, dependencies.log) {
                // "Open Dana's DM": exactly one entry on screen carries that name, so click it.
                result = await performDirect(.click(target, button: .left, count: 1), subtask: subtask,
                                             instruction: instruction, observed: observed)
                navigationOnly = true
            } else {
                if let name = AssistantSubtask.mentionedConversation(in: subtask.goal),
                   let observed = await observe(instruction, screenshot: false, shapes: false),
                   !(observed.observation.windowTitle ?? "").lowercased().contains(name.lowercased()),
                   let target = Self.logged(AssistantSubtask.grounded(name, in: observed.observation), name, observed.observation, dependencies.log) {
                    // "Read the last message from Dana" while another chat is open: open his first.
                    if case .ended = await performDirect(.click(target, button: .left, count: 1), subtask: subtask,
                                                         instruction: instruction, observed: observed) { return }
                }
                result = await executeSubtask(subtask, instruction: instruction, maximumSteps: maximumSteps, screenshotsAllowed: screenshotsAllowed)
            }
            let stepsUsed = totalSteps - stepsBefore
            switch result {
            case .ended:
                return
            case let .replanned(subtasks):
                queue = subtasks
                emitPlan(instruction, subtasks, note: nil, revised: true)
                continue
            case let .answered(answer):
                if let problem = await wrongConversation(instruction) {
                    finish(instruction, kind: .failed, summary: problem)
                } else {
                    finish(instruction, kind: .finished, summary: answer)
                }
                return
            case let .completed(summary):
                let report = AssistantSubtaskReport(subtask: subtask, outcome: .completed, summary: summary, stepsUsed: stepsUsed)
                completed.append(report)
                lastCompletedByNavigation = navigationOnly
                emit(instruction, step: totalSteps, kind: .report, summary: "Sub-task \(subtask.id) done: \(summary)")
            case .stuck, .budgetExceeded:
                if totalSteps >= maximumSteps {
                    finish(instruction, kind: .failed, summary: "Reached the step limit (\(maximumSteps)) before finishing: \(subtask.title).")
                    return
                }
                let outcome: AssistantSubtaskReport.Outcome = result == .budgetExceeded ? .budgetExceeded : .stuck
                let detail: String
                if case let .stuck(reason) = result { detail = reason } else { detail = "No progress within \(configuration.stepsPerSubtask) steps." }
                let report = AssistantSubtaskReport(subtask: subtask, outcome: outcome, summary: detail, stepsUsed: stepsUsed)
                emit(instruction, step: totalSteps, kind: .report, summary: "Sub-task \(subtask.id) \(outcome == .stuck ? "stuck" : "ran out of steps"): \(detail). Asking the planner.")
                revisions += 1
                guard revisions <= Self.maximumRevisions else {
                    finish(instruction, kind: .failed, summary: "The plan was revised \(revisions - 1) times without reaching the goal: \(detail)")
                    return
                }
                guard let fresh = await observe(instruction, screenshot: false, shapes: false) else { return }
                let message = AssistantPlanner.revisionMessage(
                    instruction: instruction, completed: completed, report: report, remaining: queue,
                    observation: fresh.observation, revisions: revisions - 1
                )
                switch await plan(instruction, message: message, observation: fresh.observation) {
                case let .plan(subtasks, note):
                    queue = subtasks
                    emitPlan(instruction, subtasks, note: note, revised: true)
                    // A small planner often hands back the step that just failed; a third try
                    // would fail the same way, so go on with the rest of its plan.
                    if let first = queue.first, first.directAction == nil, queue.count > 1,
                       first.goal.lowercased() == subtask.goal.lowercased() {
                        queue.removeFirst()
                        emit(instruction, step: totalSteps, kind: .report, summary: "Skipping \"\(first.goal)\": it just failed the same way.")
                    }
                case let .done(summary):
                    // Right after a stuck step, "done" means the planner gave up, not that the goal was
                    // met; only the owner's own "no" is a proper end.
                    if detail.hasPrefix("The owner denied") {
                        finish(instruction, kind: .finished, summary: summary)
                    } else {
                        finish(instruction, kind: .failed, summary: "Not finished: \(detail). The planner ended with: \(summary)")
                    }
                    return
                case let .ask(question):
                    guard let answer = await askOwner(instruction, question: question, stepID: "\(instruction.id)#plan\(revisions)") else { return }
                    switch await plan(instruction, message: message + "\n\nThe owner was asked: \(question)\nThe owner answered: \(answer)",
                                      observation: fresh.observation) {
                    case let .plan(subtasks, note):
                        queue = subtasks
                        emitPlan(instruction, subtasks, note: note, revised: true)
                    case let .done(summary):
                        finish(instruction, kind: .finished, summary: summary)
                        return
                    case .ask, nil:
                        if !runEnded { finish(instruction, kind: .failed, summary: "The planner keeps asking instead of planning.") }
                        return
                    }
                case nil:
                    return
                }
            }
        }
        // The owner asked something: end with the answer read off the screen, not with the last click.
        if AssistantSubtask.wantsAnAnswer(instruction.text) || calculation != nil,
           lastCompletedByNavigation || !(completed.last.map { AssistantSubtask.isReadingGoal($0.subtask.goal) && !AssistantSubtask.isEmptyReport($0.summary, goal: $0.subtask.goal) } ?? false) {
            if await waitWhilePausedOrStopped(instruction) { return }
            guard let observed = await observe(instruction, screenshot: false, shapes: false) else { return }
            if let problem = Self.wrongConversation(instruction, observed.observation) {
                finish(instruction, kind: .failed, summary: problem)
                return
            }
            if let calculation, let value = AssistantSubtask.evaluate(calculation) {
                // The sum was typed into Calculator: when its display shows the value, that is
                // the answer, with no model reading a screen full of other numbers.
                let number = AssistantSubtask.displayed(value)
                if AssistantSubtask.shows(number, in: observed.observation) {
                    let pretty = calculation.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ ")
                        .replacingOccurrences(of: "+", with: " + ").replacingOccurrences(of: "-", with: " − ")
                    finish(instruction, kind: .finished, summary: "\(pretty) = \(number)")
                    return
                }
                dependencies.log("Calculator does not show \(number) for \(calculation); reading the screen instead")
            }
            emit(instruction, step: totalSteps, kind: .subtask, summary: "Reading the answer off the screen")
            let message = AssistantPlanner.answerMessage(instruction: instruction, completed: completed, observation: observed.observation)
            guard let answer = await readAnswer(instruction, message: message) else { return }
            finish(instruction, kind: .finished, summary: answer)
            return
        }
        let summary = completed.last?.summary ?? "Done."
        finish(instruction, kind: .finished, summary: completed.count > 1 ? "\(completed.count) sub-tasks done. \(summary)" : summary)
    }

    // MARK: Planner

    private func plan(_ instruction: AgentInstruction, message: String, observation: AgentObservation? = nil) async -> AssistantPlannerReply? {
        let request = AssistantModelRequest(
            model: configuration.planner.model,
            system: AssistantPlanner.system,
            messages: [AssistantModelMessage(role: .user, text: message)],
            maxTokens: 900,
            temperature: 0.1
        )
        plannerModelsUsed.insert(configuration.planner.model)
        var lastError = ""
        var lastReply = ""
        for attempt in 1...2 {
            if stopRequested || Task.isCancelled {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return nil
            }
            // The second try carries the failed reply and what was wrong with it; the same
            // request again would get the same answer from a deterministic model.
            let attemptRequest = attempt == 1 ? request : AssistantModelRequest(
                model: request.model, system: request.system,
                messages: request.messages + [
                    AssistantModelMessage(role: .assistant, text: lastReply),
                    AssistantModelMessage(role: .user, text: "That reply was not usable: \(lastError). Reply again with one JSON object whose goals are specific to the owner's goal above, in your own words; do not repeat the format description."),
                ],
                maxTokens: request.maxTokens, temperature: request.temperature)
            do {
                let reply = try await complete(configuration.planner.provider, attemptRequest)
                lastReply = reply.text
                return try AssistantPlanner.parse(reply.text, observation: observation)
            } catch is CancellationError {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return nil
            } catch {
                lastError = Self.describe(error)
                if attempt == 1 { emit(instruction, step: totalSteps, kind: .planned, summary: "Planner reply unusable, asking again: \(lastError)") }
            }
        }
        finish(instruction, kind: .failed, summary: "The planner could not make a plan: \(lastError)")
        return nil
    }

    /// The answer step: a reply of {"done": "..."}; an answer under another key or in plain
    /// words still counts (a 9B model answered in prose twice and the run failed as "could not
    /// make a plan"). Nil once the run has ended.
    private func readAnswer(_ instruction: AgentInstruction, message: String) async -> String? {
        plannerModelsUsed.insert(configuration.planner.model)
        var messages = [AssistantModelMessage(role: .user, text: message)]
        var lastError = "the reply held no answer"
        for attempt in 1...2 {
            if stopRequested || Task.isCancelled {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return nil
            }
            let request = AssistantModelRequest(model: configuration.planner.model, system: AssistantPlanner.system,
                                                messages: messages, maxTokens: 600, temperature: 0.1)
            do {
                let reply = try await complete(configuration.planner.provider, request)
                if let answer = AssistantPlanner.answerText(in: reply.text) { return answer }
                messages += [AssistantModelMessage(role: .assistant, text: reply.text),
                             AssistantModelMessage(role: .user, text: "Reply with only {\"done\":\"<the answer>\"}, quoting the screen.")]
            } catch is CancellationError {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return nil
            } catch {
                lastError = Self.describe(error)
            }
            if attempt == 1 { emit(instruction, step: totalSteps, kind: .planned, summary: "Answer reply unusable, asking again: \(lastError)") }
        }
        finish(instruction, kind: .failed, summary: "The steps ran, but no answer could be read off the screen (\(lastError)).")
        return nil
    }

    private func emitPlan(_ instruction: AgentInstruction, _ subtasks: [AssistantSubtask], note: String?, revised: Bool = false) {
        // The planner's note is left out: small planners fill it with things they did not read.
        let lines = subtasks.map { "\($0.id). \($0.title)\($0.directAction != nil ? " (direct)" : "")" }
        emit(instruction, step: totalSteps, kind: .plan, summary: (revised ? "Revised plan:\n" : "Plan:\n") + lines.joined(separator: "\n"))
    }

    private func askOwner(_ instruction: AgentInstruction, question: String, stepID: String) async -> String? {
        phase = .waitingAnswer(stepID: stepID)
        pendingAnswer = (stepID, nil)
        emit(instruction, step: totalSteps, kind: .asked, summary: question, action: .ask(question: question), stepID: stepID)
        guard let answer = await waitForAnswer(instruction) else { return nil }
        emit(instruction, step: totalSteps, kind: .answered, summary: answer, stepID: stepID)
        phase = .running(step: totalSteps, of: configuration.maximumSteps)
        return answer
    }

    // MARK: Jumping to a conversation

    /// Chat apps have a jump box (⌘K in Slack and Discord). When the conversation the owner
    /// named is not on screen, open the box, type its name and press Return. Each step still
    /// passes the policy: typing and Return are allowed only because the jump box has focus,
    /// and the run checks the window then shows that conversation. Nil when the app has no
    /// jump box or the name is already on screen to click.
    private func jump(to name: String, subtask: AssistantSubtask, instruction: AgentInstruction) async -> SubtaskResult? {
        guard let before = await observe(instruction, screenshot: false, shapes: false) else { return .ended }
        // Typing the name in the jump box beats clicking it: a person's name also shows up as
        // message authors, in group conversations and in profile panels.
        guard let shortcut = AssistantSubtask.quickSwitcher(for: before.observation.frontmostBundleIdentifier) else { return nil }
        if Self.showsConversation(name, title: before.observation.windowTitle ?? "", bundleIdentifier: before.observation.frontmostBundleIdentifier) {
            return .completed(summary: "\(before.observation.windowTitle ?? name) is already open")
        }
        let settle: UInt64 = 700_000_000
        if case .ended = await performDirect(.key(name: shortcut.key, modifiers: shortcut.modifiers), subtask: subtask,
                                             instruction: instruction, observed: before) { return .ended }
        try? await Task.sleep(nanoseconds: settle)
        guard let opened = await observe(instruction, screenshot: false, shapes: false) else { return .ended }
        guard AgentApprovalPolicy.isSearchField(opened.observation.focusedField) else {
            dependencies.log("Jump box did not take focus (\(opened.observation.focusedField ?? "nothing focused")); the executor takes over")
            _ = await performDirect(.key(name: "escape", modifiers: []), subtask: subtask, instruction: instruction, observed: opened)
            return nil
        }
        if case .ended = await performDirect(.type(text: name), subtask: subtask, instruction: instruction, observed: opened) { return .ended }
        // The box fills in as matches arrive (a channel can take longer than a recent DM):
        // Return goes once one carries the name, or after a short wait regardless. The first
        // look waits for the box to filter: the sidebar can show the name before the box does.
        var typed = opened
        try? await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<Self.jumpPolls {
            try? await Task.sleep(nanoseconds: Self.jumpPollNanoseconds)
            guard let current = await observe(instruction, screenshot: false, shapes: false) else { return .ended }
            typed = current
            if Self.lists(name, in: current.observation) { break }
        }
        if case .ended = await performDirect(.key(name: "return", modifiers: []), subtask: subtask,
                                             instruction: instruction, observed: typed) { return .ended }
        // A conversation not opened recently takes a moment to load and retitle the window.
        var title = ""
        for _ in 0..<Self.jumpPolls + 2 {
            try? await Task.sleep(nanoseconds: Self.jumpPollNanoseconds)
            guard let after = await observe(instruction, screenshot: false, shapes: false) else { return .ended }
            title = after.observation.windowTitle ?? ""
            if Self.showsConversation(name, title: title, bundleIdentifier: after.observation.frontmostBundleIdentifier) {
                dependencies.log("Jumped to \"\(name)\": the window now shows \"\(title)\"")
                return .completed(summary: "Opened \(title)")
            }
        }
        dependencies.log("Jumped to \"\(name)\": the window still shows \"\(title)\"")
        return .stuck(reason: "Jumped to \"\(name)\" but the window shows \"\(title)\"")
    }

    static let jumpPolls = 8
    static let jumpPollNanoseconds: UInt64 = 300_000_000

    /// Whether the jump box lists the conversation: a line that is the name, "# name" or
    /// "@name", or the name followed by more (a channel topic, "(you)").
    static func lists(_ name: String, in observation: AgentObservation) -> Bool {
        let wanted = name.lowercased()
        let lines = observation.elements.map(\.label) + observation.texts.map(\.text)
        return lines.contains { line in
            let cleaned = line.lowercased().trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "#@")))
            return cleaned == wanted || cleaned.hasPrefix(wanted + " ")
        }
    }

    /// When the owner named a conversation, an answer may only come from it.
    static func wrongConversation(_ instruction: AgentInstruction, _ observation: AgentObservation) -> String? {
        guard let name = AssistantSubtask.conversationTarget(in: instruction.text),
              AgentApprovalPolicy.isChatApp(bundleIdentifier: observation.frontmostBundleIdentifier) else { return nil }
        let title = observation.windowTitle ?? ""
        return showsConversation(name, title: title, bundleIdentifier: observation.frontmostBundleIdentifier)
            ? nil : "Could not open \(name): the screen shows \"\(title)\" instead, so nothing was read from it."
    }

    /// Slack titles a window "<conversation> (DM|Channel) - <workspace> - Slack": the
    /// conversation must be exactly the named one, so a group DM that includes the person does
    /// not count. Other apps: the name appears in the title.
    static func showsConversation(_ name: String, title: String, bundleIdentifier: String?) -> Bool {
        let wanted = name.lowercased()
        guard bundleIdentifier == "com.tinyspeck.slackmacgap" else { return title.lowercased().contains(wanted) }
        var conversation = title.lowercased().components(separatedBy: " - ").first ?? ""
        if let open = conversation.range(of: " (") { conversation = String(conversation[..<open.lowerBound]) }
        return conversation.trimmingCharacters(in: .whitespaces) == wanted
    }

    private func wrongConversation(_ instruction: AgentInstruction) async -> String? {
        guard let observed = try? await dependencies.observe(false, false) else { return nil }
        return Self.wrongConversation(instruction, observed.observation)
    }

    // MARK: Planner review

    private func startReview(instruction: AgentInstruction, subtask: AssistantSubtask, history: [StepRecord], token: Int) {
        let steps = history.map { record in
            "\(record.index). \(Self.describe(record.action))" + (record.reason.isEmpty ? "" : " (\(record.reason.prefix(80)))")
                + " → \(record.result)"
        }
        reviewTask = Task { [weak self] in
            guard let self else { return }
            await self.review(instruction: instruction, subtask: subtask, steps: steps, token: token)
        }
    }

    private func review(instruction: AgentInstruction, subtask: AssistantSubtask, steps: [String], token: Int) async {
        defer { if reviewToken == token { reviewTask = nil } }
        guard let observed = try? await dependencies.observe(false, false), !Task.isCancelled else { return }
        let request = AssistantModelRequest(
            model: configuration.planner.model,
            system: AssistantPlanner.system,
            messages: [AssistantModelMessage(role: .user, text: AssistantPlanner.reviewMessage(
                instruction: instruction, subtask: subtask, steps: steps, observation: observed.observation))],
            maxTokens: 500,
            temperature: 0.1
        )
        plannerModelsUsed.insert(configuration.planner.model)
        guard let reply = try? await complete(configuration.planner.provider, request),
              !Task.isCancelled, reviewToken == token else { return }
        let verdict = AssistantPlanner.parseReview(reply.text, observation: observed.observation)
        dependencies.log("Planner review of \"\(subtask.goal.prefix(60))\": \(verdict)")
        reviewResult = (token, verdict)
    }

    // MARK: Direct actions

    /// A step the planner was certain about: policy, approval if needed, then the action, no
    /// executor call.
    private func performDirect(_ action: AgentAction, subtask: AssistantSubtask, instruction: AgentInstruction,
                               observed preObserved: ScreenObservationResult? = nil) async -> SubtaskResult {
        let current: ScreenObservationResult?
        if let preObserved { current = preObserved } else { current = await observe(instruction, screenshot: false, shapes: false) }
        guard let observed = current else { return .ended }
        totalSteps += 1
        phase = .running(step: totalSteps, of: configuration.maximumSteps)
        let stepID = "\(instruction.id)#\(totalSteps)"
        emit(instruction, step: totalSteps, kind: .planned, summary: Self.describe(action, in: observed.observation), action: action, stepID: stepID)
        switch await gate(action, in: observed.observation, instruction: instruction, stepID: stepID) {
        case .ended: return .ended
        case .blocked(let reason): return .stuck(reason: "Refused by Oriel: \(reason)")
        case .denied: return .stuck(reason: "The owner denied \(Self.describe(action, in: observed.observation)).")
        case .allowed: break
        }
        do {
            try await perform(action, in: observed.observation)
            emit(instruction, step: totalSteps, kind: .executed, summary: Self.describe(action, in: observed.observation), action: action, stepID: stepID)
            try? await Task.sleep(nanoseconds: Self.settleDelayNanoseconds)
            return .completed(summary: Self.describe(action, in: observed.observation))
        } catch is CancellationError {
            finish(instruction, kind: .stopped, summary: "Stopped.")
            return .ended
        } catch {
            let detail = Self.describe(error)
            emit(instruction, step: totalSteps, kind: .blocked, summary: "Could not act: \(detail)", action: action, stepID: stepID)
            return .stuck(reason: detail)
        }
    }

    // MARK: Executor

    private func executeSubtask(
        _ subtask: AssistantSubtask,
        instruction: AgentInstruction,
        maximumSteps: Int,
        screenshotsAllowed: Bool
    ) async -> SubtaskResult {
        var history: [StepRecord] = []
        var useVisionNext = configuration.visionPolicy == .always
        var consecutiveFailures = 0
        var previousSignature: Int?
        var answerForModel: String?
        var stepsInSubtask = 0
        /// Clicks already made, with the screen they were made on: the same click on the same
        /// screen did nothing the first time and will do nothing again.
        var clicksMade: [String: Int] = [:]
        /// The control clicked last and how many times in a row: a third click on it means the
        /// executor is going round in circles, even when each click changes the screen (a
        /// popover that opens and closes).
        var lastClick: (description: String, count: Int)?
        var rejectedEmptyReport = false

        reviewToken += 1
        let token = reviewToken
        var lastReviewStep = 0
        var plannerHint: String?
        defer {
            reviewTask?.cancel()
            reviewTask = nil
            reviewResult = nil
        }

        while stepsInSubtask < configuration.stepsPerSubtask {
            if await waitWhilePausedOrStopped(instruction) { return .ended }
            if let result = reviewResult, result.token == token {
                reviewResult = nil
                switch result.review {
                case .onTrack:
                    break
                case let .hint(hint):
                    plannerHint = hint
                    emit(instruction, step: totalSteps, kind: .report, summary: "Planner steers: \(hint)")
                case let .replan(subtasks):
                    emit(instruction, step: totalSteps, kind: .report, summary: "Planner changes course.")
                    return .replanned(subtasks)
                case let .done(answer):
                    return .answered(answer)
                }
            }
            guard totalSteps < maximumSteps else { return .budgetExceeded }
            stepsInSubtask += 1
            totalSteps += 1
            let stepIndex = totalSteps
            phase = .running(step: stepIndex, of: maximumSteps)

            let wantsVision = useVisionNext || configuration.visionPolicy == .always
            guard var observed = await observe(instruction, screenshot: wantsVision && screenshotsAllowed, shapes: wantsVision) else { return .ended }
            let observation = observed.observation
            let signature = Self.signature(of: observation)
            if let previousSignature, let last = history.indices.last {
                history[last].result += signature == previousSignature ? " · screen unchanged" : " · screen changed"
            }
            previousSignature = signature
            let blind = observation.elements.count < 3 && observation.texts.count < 5
            let visionNow = (wantsVision || (configuration.visionPolicy == .auto && blind)) && configuration.visionPolicy != .never
                && configuration.executor.visionModel != nil
            if visionNow, screenshotsAllowed, observed.screenshotJPEG == nil {
                // The text picture turned out blind: take the screenshot the vision model needs.
                guard let withPixels = await observe(instruction, screenshot: true, shapes: true) else { return .ended }
                observed = withPixels
            }
            let modelName = visionNow ? (configuration.executor.visionModel ?? configuration.executor.model) : configuration.executor.model
            let imageAttached = visionNow && screenshotsAllowed ? observed.screenshotJPEG : nil
            emit(instruction, step: stepIndex, kind: .observed,
                 summary: "\(observation.frontmostApplication ?? "Screen"): \(observation.elements.count) controls, \(observation.texts.count) text lines"
                    + (imageAttached != nil ? ", screenshot to \(modelName)" : ", text to \(modelName)"))

            let request = AssistantModelRequest(
                model: modelName,
                system: AssistantPrompt.executorSystem(imageAttached: imageAttached != nil),
                messages: AssistantPrompt.executorMessages(
                    instruction: instruction, subtask: subtask, step: stepsInSubtask, budget: configuration.stepsPerSubtask,
                    history: history.suffix(Self.historyWindow), observation: observation, answer: answerForModel,
                    plannerHint: plannerHint
                ),
                imageJPEG: imageAttached,
                maxTokens: 400
            )
            answerForModel = nil
            plannerHint = nil
            executorModelsUsed.insert(modelName)
            let planned: AgentPlannedStep
            do {
                let provider = visionNow ? (configuration.executor.visionProvider ?? configuration.executor.provider) : configuration.executor.provider
                let reply = try await complete(provider, request)
                planned = try AgentModelResponseParser.parse(reply.text)
                consecutiveFailures = 0
            } catch is CancellationError {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return .ended
            } catch {
                consecutiveFailures += 1
                let detail = Self.describe(error)
                if consecutiveFailures >= 3 { return .stuck(reason: "The executor could not plan a step: \(detail)") }
                history.append(StepRecord(index: stepIndex, reason: "", action: .wait(milliseconds: 100),
                                          result: "model reply unusable (\(detail)); answer with one JSON action"))
                emit(instruction, step: stepIndex, kind: .planned, summary: "Executor reply unusable, asking again: \(detail)")
                continue
            }
            let stepID = "\(instruction.id)#\(stepIndex)"
            emit(instruction, step: stepIndex, kind: .planned,
                 summary: Self.describe(planned.action, in: observation) + (planned.reason.isEmpty ? "" : " — \(planned.reason)"),
                 action: planned.action, stepID: stepID)
            useVisionNext = false

            switch planned.action {
            case let .done(summary):
                if AssistantSubtask.isReadingGoal(subtask.goal), AssistantSubtask.isEmptyReport(summary, goal: subtask.goal),
                   !rejectedEmptyReport {
                    // "Done: read the last message" answers nothing; the owner asked for what it says.
                    rejectedEmptyReport = true
                    history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action,
                                              result: "not accepted: the summary must quote what you read on the screen"))
                    continue
                }
                return .completed(summary: summary)
            case let .escalate(reason):
                return .stuck(reason: reason.isEmpty ? "The executor asked for a new plan." : reason)
            case let .ask(question):
                guard let answer = await askOwner(instruction, question: question, stepID: stepID) else { return .ended }
                answerForModel = answer
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action, result: "owner answered: \(answer)"))
                continue
            case .look:
                useVisionNext = true
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action,
                                          result: screenshotsAllowed && configuration.executor.visionModel != nil
                                            ? "screenshot provided on the next step" : "screenshots are not shared with this model; use the text description"))
                continue
            case let .wait(milliseconds):
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action, result: "waited"))
                emit(instruction, step: stepIndex, kind: .executed, summary: "Waited \(milliseconds) ms", action: planned.action, stepID: stepID)
                continue
            default:
                break
            }

            let clickDescription = Self.describe(planned.action, in: observation)
            if case .click = planned.action {
                if clicksMade[clickDescription] == signature {
                    return .stuck(reason: "\(clickDescription) changed nothing on the screen, so it was not repeated")
                }
                if let lastClick, lastClick.description == clickDescription, lastClick.count >= Self.repeatedClickLimit {
                    return .stuck(reason: "\(clickDescription) was already clicked \(lastClick.count) times in a row without finishing the goal, so it was not clicked again")
                }
            }

            switch await gate(planned.action, in: observation, instruction: instruction, stepID: stepID) {
            case .ended:
                return .ended
            case let .blocked(reason):
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action, result: "refused by Oriel: \(reason)"))
                continue
            case .denied:
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action, result: "owner denied this step; choose another approach or escalate"))
                continue
            case .allowed:
                break
            }

            do {
                try await perform(planned.action, in: observation)
                if case .click = planned.action {
                    clicksMade[clickDescription] = signature
                    lastClick = (clickDescription, lastClick?.description == clickDescription ? (lastClick?.count ?? 0) + 1 : 1)
                } else {
                    lastClick = nil
                }
                let stagnant = history.last?.result.contains("screen unchanged") == true
                let every = configuration.reviewEverySteps
                if every > 0, reviewTask == nil, stepsInSubtask - lastReviewStep >= every || stagnant {
                    lastReviewStep = stepsInSubtask
                    startReview(instruction: instruction, subtask: subtask, history: history, token: token)
                }
                emit(instruction, step: stepIndex, kind: .executed, summary: Self.describe(planned.action, in: observation), action: planned.action, stepID: stepID)
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action, result: "done"))
                try? await Task.sleep(nanoseconds: Self.settleDelayNanoseconds)
            } catch is CancellationError {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return .ended
            } catch {
                let detail = Self.describe(error)
                emit(instruction, step: stepIndex, kind: .blocked, summary: "Could not act: \(detail)", action: planned.action, stepID: stepID)
                history.append(StepRecord(index: stepIndex, reason: planned.reason, action: planned.action, result: "failed: \(detail)"))
                if detail.contains("Accessibility") || detail.contains("not authorized") || detail.contains("controlNotAuthorized") {
                    finish(instruction, kind: .failed, summary: detail)
                    return .ended
                }
            }
        }
        return .budgetExceeded
    }

    // MARK: Policy gate

    private enum GateResult {
        case allowed
        case blocked(String)
        case denied
        case ended
    }

    private func gate(_ action: AgentAction, in observation: AgentObservation, instruction: AgentInstruction, stepID: String) async -> GateResult {
        var context = Self.context(for: action, in: observation)
        if await landsOnOriel(action, in: observation) { context = context.landingOnOriel() }
        var decision = AgentApprovalPolicy.evaluate(context)
        if case .allow = decision, case .type = action,
           AgentApprovalPolicy.isChatApp(bundleIdentifier: observation.frontmostBundleIdentifier),
           !AgentApprovalPolicy.isSearchField(observation.focusedField),
           !Self.asksToWrite(instruction.text) {
            // Nothing was asked to be written, so text typed into a chat app is a guess about
            // which box has focus; the message box is one Return away from a send.
            decision = .requireApproval(reason: "Typing in a chat app when you asked for nothing to be written; approve only if it is a search box.")
        }
        switch decision {
        case .allow:
            return .allowed
        case let .block(reason):
            emit(instruction, step: totalSteps, kind: .blocked, summary: reason, action: action, stepID: stepID)
            return .blocked(reason)
        case let .requireApproval(reason):
            phase = .waitingApproval(stepID: stepID)
            pendingApproval = (stepID, nil)
            emit(instruction, step: totalSteps, kind: .needsApproval, summary: reason, action: action, stepID: stepID)
            guard let approved = await waitForApproval(instruction) else { return .ended }
            phase = .running(step: totalSteps, of: configuration.maximumSteps)
            if approved { return .allowed }
            emit(instruction, step: totalSteps, kind: .denied, summary: "Denied on the phone.", action: action, stepID: stepID)
            return .denied
        }
    }

    /// Where the input of an action goes: clicks and scrolls to the window under their point,
    /// typing and keys to the window that has the keyboard.
    private func landsOnOriel(_ action: AgentAction, in observation: AgentObservation) async -> Bool {
        switch action {
        case let .click(target, _, _):
            guard let point = try? Self.point(for: target, in: observation) else { return false }
            return await dependencies.landsOnOriel(point)
        case let .scroll(_, _, at):
            let pointer = observation.pointerX.flatMap { x in observation.pointerY.flatMap { y in try? NormalizedPoint(x: x, y: y) } }
            let point = at.flatMap { try? Self.point(for: $0, in: observation) } ?? pointer
            return await dependencies.landsOnOriel(point)
        case .type, .key:
            return await dependencies.landsOnOriel(nil)
        case .openApplication, .wait, .look, .escalate, .done, .ask:
            return false
        }
    }

    private static func logged(_ target: AgentTargetReference?, _ name: String, _ observation: AgentObservation,
                               _ log: @Sendable (String) -> Void) -> AgentTargetReference? {
        log(AssistantSubtask.groundingNote(name, in: observation, chose: target))
        return target
    }

    /// Whether the owner asked for something to be written or sent.
    static func asksToWrite(_ instruction: String) -> Bool {
        // Whole words: "who posted" and "what it says" are questions, not requests to write.
        let pattern = #"\b(send|sending|write|writing|reply|replying|respond|post|posting|draft|type|typing|saying|and say|to say|message (him|her|them)|tell (him|her|them))\b"#
        return instruction.lowercased().range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Observation and models

    private func observe(_ instruction: AgentInstruction, screenshot: Bool, shapes: Bool) async -> ScreenObservationResult? {
        do {
            return try await dependencies.observe(screenshot, shapes)
        } catch {
            finish(instruction, kind: .failed, summary: "Could not read the screen: \(error.localizedDescription)")
            return nil
        }
    }

    private func complete(_ provider: any AssistantModelProvider, _ request: AssistantModelRequest) async throws -> AssistantModelReply {
        do {
            return try await provider.complete(request)
        } catch let error as AssistantModelProviderError {
            guard case .transport = error else { throw error }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await provider.complete(request)
        }
    }

    // MARK: Waiting

    /// True when the run ended while paused or by a stop.
    private func waitWhilePausedOrStopped(_ instruction: AgentInstruction) async -> Bool {
        if stopRequested || Task.isCancelled {
            finish(instruction, kind: .stopped, summary: "Stopped.")
            return true
        }
        guard pauseRequested else { return false }
        phase = .paused
        emit(instruction, step: totalSteps, kind: .paused, summary: "Paused.")
        while pauseRequested {
            if stopRequested || Task.isCancelled {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        phase = .running(step: totalSteps, of: configuration.maximumSteps)
        emit(instruction, step: totalSteps, kind: .resumed, summary: "Resumed.")
        return false
    }

    private func waitForApproval(_ instruction: AgentInstruction) async -> Bool? {
        let deadline = dependencies.now() + Self.approvalTimeoutNanoseconds
        while pendingApproval?.decision == nil {
            if stopRequested || Task.isCancelled {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return nil
            }
            if dependencies.now() > deadline {
                finish(instruction, kind: .failed, summary: "No approval within five minutes.")
                return nil
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let decision = pendingApproval?.decision ?? false
        pendingApproval = nil
        return decision
    }

    private func waitForAnswer(_ instruction: AgentInstruction) async -> String? {
        let deadline = dependencies.now() + Self.approvalTimeoutNanoseconds
        while pendingAnswer?.text == nil {
            if stopRequested || Task.isCancelled {
                finish(instruction, kind: .stopped, summary: "Stopped.")
                return nil
            }
            if dependencies.now() > deadline {
                finish(instruction, kind: .failed, summary: "No answer within five minutes.")
                return nil
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let text = pendingAnswer?.text ?? ""
        pendingAnswer = nil
        return text
    }

    // MARK: Acting

    private func perform(_ action: AgentAction, in observation: AgentObservation) async throws {
        switch action {
        case let .click(target, button, count):
            let point = try Self.point(for: target, in: observation)
            try await dependencies.execute(.pointerMove(point))
            try await Task.sleep(nanoseconds: 60_000_000)
            try await dependencies.execute(.mouseButton(button, count == 2 ? .doubleClick : .click))
        case let .type(text):
            // Unicode keyboard events carry a few characters at a time reliably.
            for chunk in Self.chunks(text, size: 16) {
                try await dependencies.execute(try RemoteInputEvent.text(chunk))
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        case let .key(name, modifiers):
            guard let code = AgentKeyName.keyCode(for: name) else { throw AgentProtocolError.unknownKey }
            try await dependencies.execute(.key(code: code, phase: .press, modifiers: modifiers))
        case let .scroll(deltaX, deltaY, at):
            if let at {
                try await dependencies.execute(.pointerMove(try Self.point(for: at, in: observation)))
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            try await dependencies.execute(try RemoteInputEvent.scroll(deltaX: deltaX, deltaY: deltaY))
        case let .openApplication(name):
            try await dependencies.openApplication(name)
        case let .wait(milliseconds):
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        case .look, .escalate, .done, .ask:
            break
        }
    }

    private static func point(for target: AgentTargetReference, in observation: AgentObservation) throws -> NormalizedPoint {
        switch target {
        case let .point(point):
            return point
        case let .element(id):
            if let element = observation.element(id: id) {
                return try NormalizedPoint(x: min(max(element.centerX, 0), 1), y: min(max(element.centerY, 0), 1))
            }
            if let text = observation.text(id: id) {
                return try NormalizedPoint(x: min(max(text.centerX, 0), 1), y: min(max(text.centerY, 0), 1))
            }
            throw AssistantRuntimeError.unknownElement(id)
        }
    }

    private static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= size { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Policy context and descriptions

    static func context(for action: AgentAction, in observation: AgentObservation) -> AgentActionContext {
        func target(_ reference: AgentTargetReference?) -> (label: String?, role: String?, sensitive: Bool) {
            guard case let .element(id)? = reference else { return (nil, nil, false) }
            if let element = observation.element(id: id) { return (element.label, element.role, element.isSensitive) }
            if let text = observation.text(id: id) { return (text.text, "text", text.isSensitive) }
            return (nil, nil, false)
        }
        let base = (observation.frontmostBundleIdentifier, observation.frontmostApplication, observation.windowTitle)
        switch action {
        case let .click(reference, _, _):
            let info = target(reference)
            return AgentActionContext(kind: .click, targetLabel: info.label, targetRole: info.role, targetIsSensitive: info.sensitive,
                                      frontmostBundleIdentifier: base.0, frontmostApplication: base.1, windowTitle: base.2, focusedField: observation.focusedField)
        case let .type(text):
            return AgentActionContext(kind: .type, text: text, frontmostBundleIdentifier: base.0, frontmostApplication: base.1, windowTitle: base.2, focusedField: observation.focusedField)
        case let .key(name, modifiers):
            return AgentActionContext(kind: .key, keyName: name, modifiers: Set(modifiers.map(\.rawValue)),
                                      frontmostBundleIdentifier: base.0, frontmostApplication: base.1, windowTitle: base.2, focusedField: observation.focusedField)
        case .scroll:
            return AgentActionContext(kind: .scroll, frontmostBundleIdentifier: base.0, frontmostApplication: base.1, windowTitle: base.2, focusedField: observation.focusedField)
        case let .openApplication(name):
            return AgentActionContext(kind: .openApplication, targetLabel: name, frontmostBundleIdentifier: base.0,
                                      frontmostApplication: base.1, windowTitle: base.2, focusedField: observation.focusedField)
        case .wait, .look, .escalate: return AgentActionContext(kind: .wait)
        case .done: return AgentActionContext(kind: .done)
        case .ask: return AgentActionContext(kind: .ask)
        }
    }

    static func describe(_ action: AgentAction, in observation: AgentObservation? = nil) -> String {
        switch action {
        case let .click(reference, button, count):
            let what: String
            switch reference {
            case let .element(id):
                if let element = observation?.element(id: id) { what = "\"\(element.label)\" (\(element.role))" }
                else if let text = observation?.text(id: id) { what = "text \"\(text.text)\"" }
                else { what = id }
            case let .point(point):
                what = String(format: "(%.2f, %.2f)", point.x, point.y)
            }
            let verb = count == 2 ? "Double-click" : (button == .right ? "Right-click" : "Click")
            return "\(verb) \(what)"
        case let .type(text): return "Type \"\(text.count > 60 ? String(text.prefix(57)) + "…" : text)\""
        case let .key(name, modifiers):
            let combo = modifiers.sorted { $0.rawValue < $1.rawValue }.map { $0.rawValue.capitalized } + [name.capitalized]
            return "Press " + combo.joined(separator: "+")
        case let .scroll(deltaX, deltaY, _): return "Scroll " + (deltaY < 0 ? "down" : deltaY > 0 ? "up" : (deltaX > 0 ? "right" : "left"))
        case let .openApplication(name): return "Open \(name)"
        case let .wait(milliseconds): return "Wait \(milliseconds) ms"
        case .look: return "Look at the screen"
        case let .escalate(reason): return "Ask the planner" + (reason.isEmpty ? "" : ": \(reason)")
        case let .done(summary): return "Done: \(summary)"
        case let .ask(question): return "Ask: \(question)"
        }
    }

    static func describe(_ error: any Error) -> String {
        if let providerError = error as? AssistantModelProviderError {
            switch providerError {
            case .invalidEndpoint: return "the model endpoint is not valid"
            case .missingAPIKey: return "no API key is set on the Mac"
            case let .httpStatus(status, body): return "the model endpoint answered HTTP \(status)\(body.isEmpty ? "" : ": " + body.prefix(120))"
            case .emptyReply: return "the model gave an empty reply"
            case let .transport(message): return "could not reach the model (\(message))"
            }
        }
        if let protocolError = error as? AgentProtocolError {
            switch protocolError {
            case let .unknownActionType(name): return "unknown action \"\(name)\"; use one of click, type, key, scroll, openApplication, wait, look, ask, escalate, done"
            case .missingTarget: return "click needs a target: an element id or a normalized x,y point"
            case .malformedResponse: return "the reply was not one JSON object"
            default: return "unusable action (\(protocolError))"
            }
        }
        if let plannerError = error as? AssistantPlannerError {
            switch plannerError {
            case .placeholderPlan: return "the plan repeated the format description instead of the goal"
            case .emptyPlan: return "the plan had no sub-tasks"
            case .malformed: return "the reply was not one JSON object with a plan, done or ask"
            }
        }
        return String(describing: error)
    }

    /// Clicks in a row on one control before the executor is sent back to the planner.
    static let repeatedClickLimit = 2

    static func signature(of observation: AgentObservation) -> Int {
        var hasher = Hasher()
        hasher.combine(observation.frontmostBundleIdentifier)
        hasher.combine(observation.windowTitle)
        hasher.combine(observation.elements.count)
        for element in observation.elements.prefix(30) { hasher.combine(element.label); hasher.combine(Int(element.centerY * 100)) }
        for text in observation.texts.prefix(20) { hasher.combine(text.text) }
        return hasher.finalize()
    }

    // MARK: Trace

    private func emit(_ instruction: AgentInstruction, step: Int, kind: AgentTraceKind, summary: String,
                      action: AgentAction? = nil, stepID: String? = nil) {
        guard let event = try? AgentTraceEvent(
            instructionID: instruction.id, stepIndex: step, kind: kind,
            summary: String(summary.prefix(1_800)), action: action, stepID: stepID, monotonicNanoseconds: dependencies.now()
        ) else { return }
        dependencies.emit(event)
    }

    private func finish(_ instruction: AgentInstruction, kind: AgentTraceKind, summary: String) {
        guard !runEnded else { return }
        runEnded = true
        emit(instruction, step: totalSteps, kind: kind, summary: summary)
        let outcome: String
        switch kind {
        case .finished: outcome = "done: \(summary.prefix(240))"
        case .stopped: outcome = "stopped by the owner"
        default: outcome = "failed: \(summary.prefix(240))"
        }
        episodes.append(Episode(instruction: instruction.text, outcome: outcome, endedAt: .now))
        if episodes.count > Self.episodeLimit { episodes.removeFirst(episodes.count - Self.episodeLimit) }
        switch kind {
        case .finished: phase = .finished(summary: summary)
        case .stopped: phase = .stopped
        default: phase = .failed(reason: summary)
        }
        pendingApproval = nil
        pendingAnswer = nil
    }
}

enum AssistantRuntimeError: Error, CustomStringConvertible {
    case unknownElement(String)
    case applicationNotFound(String)

    var description: String {
        switch self {
        case let .unknownElement(id): "no control \(id) on the current screen"
        case let .applicationNotFound(name): "no application named \(name)"
        }
    }
}

/// What the executor is told. One JSON action per reply, the allowlist spelled out, and the
/// rules the policy enforces anyway, so the model plans within them.
enum AssistantPrompt {
    /// Words worth keeping on screen for a goal: names, not grammar.
    static func keyWords(_ text: String) -> [String] {
        let common: Set<String> = [
            "open", "click", "read", "check", "tell", "show", "find", "search", "select", "then", "with", "from",
            "into", "that", "this", "last", "first", "next", "message", "messages", "the", "and", "for", "you",
            "your", "what", "there", "any", "new", "go", "to", "me", "it", "in", "on", "of", "a", "an", "app",
        ]
        return text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !common.contains($0) }
    }

    static func executorSystem(imageAttached: Bool) -> String {
        """
        You are Oriel's executor: you operate a Mac for its owner, one small sub-task at a time, \
        following a plan from a planner. Each turn you get a text description of the current \
        screen\(imageAttached ? " and a screenshot" : "") and you choose exactly ONE next action. \
        Reply with one JSON object and nothing else:
        {"reason": "<one short sentence>", "action": {...}}

        Actions:
        {"type":"click","target":{"element":"e12"}}            click a listed control or text line by id (add "count":2 for double-click, "button":"right" for a context menu)
        {"type":"click","target":{"x":0.42,"y":0.88}}          click a normalized screen point (0..1 from the top-left) when nothing listed fits
        {"type":"type","text":"..."}                           type into the focused field (click the field first)
        {"type":"key","key":"return"}                          press a key: return, tab, escape, space, delete, up, down, left, right, home, end, pageup, pagedown, f1..f12, a letter or digit
        {"type":"key","key":"s","modifiers":["command"]}       a shortcut (modifiers: command, option, control, shift)
        {"type":"scroll","deltaY":-300}                        negative scrolls down, positive up; optional "target"
        {"type":"openApplication","name":"Notes"}              launch or bring an app to the front
        {"type":"wait","milliseconds":800}                     let the screen settle
        {"type":"look","reason":"..."}                         ask for a screenshot when the description is not enough
        {"type":"ask","question":"..."}                        ask the owner when a choice is theirs
        {"type":"escalate","reason":"..."}                     hand the sub-task back to the planner when it cannot be done as described
        {"type":"done","summary":"..."}                        the current sub-task is complete: say what the screen shows now, and when the sub-task is to read, check or find something, quote what you found

        Rules: one action per reply; stay on the current sub-task only; prefer element ids over \
        points; never invent an id or a control that is not in the observation (escalate instead); \
        apps that take keyboard input (editors, terminals, calculators, search fields) are faster \
        with type and key than with clicks, so type "12*7=" rather than clicking digit buttons; \
        type only after the right field is focused; never type passwords, one-time codes \
        or card numbers and never operate security or permission dialogs, payments, deletions or \
        public sends without the owner (Oriel refuses those and will ask); in a chat the newest \
        message is the lowest text above the message box; read the next \
        observation before assuming an action worked; if the same action failed twice, change \
        approach or escalate; reply done only when the current screen proves the done-when (the \
        sub-task's app in front and showing the expected result), and never on the first step of a \
        sub-task that asks you to do something; when a sub-task makes no sense for the owner's \
        goal, escalate instead of pretending it is done.
        """
    }

    static func executorMessages(
        instruction: AgentInstruction,
        subtask: AssistantSubtask,
        step: Int,
        budget: Int,
        history: ArraySlice<AssistantRuntime.StepRecord>,
        observation: AgentObservation,
        answer: String?,
        plannerHint: String? = nil
    ) -> [AssistantModelMessage] {
        var text = "Overall goal (for context only): \(instruction.text)\n"
        text += "Your current sub-task: \(subtask.goal)\n"
        if let doneWhen = subtask.doneWhen { text += "It is done when: \(doneWhen)\n" }
        text += "\nStep \(step) of at most \(budget) for this sub-task."
        if history.isEmpty {
            text += " No steps taken yet in this sub-task."
        } else {
            text += " Previous steps:\n"
            for record in history {
                text += "\(record.index). \(record.action.kind)"
                switch record.action {
                case let .click(reference, _, _):
                    if case let .element(id) = reference { text += " \(id)" }
                case let .type(value): text += " \"\(value.prefix(40))\""
                case let .key(name, modifiers): text += " \(modifiers.map(\.rawValue).sorted().joined(separator: "+"))\(modifiers.isEmpty ? "" : "+")\(name)"
                case let .openApplication(name): text += " \(name)"
                default: break
                }
                if !record.reason.isEmpty { text += " (\(record.reason.prefix(80)))" }
                text += " → \(record.result)\n"
            }
        }
        if let answer { text += "\nThe owner answered your question: \(answer)\n" }
        if let plannerHint { text += "\nThe planner, watching your steps, says: \(plannerHint)\n" }
        text += "\nCurrent screen:\n" + AgentObservationRenderer.render(
            observation, maximumBytes: 7_000, pinning: AssistantPrompt.keyWords(subtask.goal + " " + instruction.text)
        )
        text += "\n\nIds: eN are controls, tN are text lines; a file, item or label named in the text is clicked by its tN id. Use the exact id of the thing you mean."
        text += "\n\nReply with the next action as one JSON object."
        return [AssistantModelMessage(role: .user, text: text)]
    }
}
