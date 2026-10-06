import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

/// The two-brain loop with scripted models and a canned screen: plan, direct actions,
/// executor steps, policy, approval, questions, escalation and re-planning, stop, step
/// limits, screenshot gating. No hardware, no network.
@MainActor
struct AssistantRuntimeTests {
    final class Scripted: AssistantModelProvider, @unchecked Sendable {
        private var replies: [String]
        private(set) var requests: [AssistantModelRequest] = []
        private(set) var released: [String] = []
        private let lock = NSLock()
        init(_ replies: [String]) { self.replies = replies }
        var displayName: String { "scripted" }

        func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
            let reply: String? = lock.withLock {
                requests.append(request)
                return replies.isEmpty ? nil : replies.removeFirst()
            }
            guard let reply else { throw AssistantModelProviderError.emptyReply }
            return AssistantModelReply(text: reply, model: request.model, latencyMilliseconds: 1)
        }

        func listModels() async throws -> [String] { ["fast", "vision"] }
        func release(models: [String]) async { lock.withLock { released += models } }
    }

    final class Recorder: @unchecked Sendable {
        private(set) var executed: [RemoteInputEvent] = []
        private(set) var opened: [String] = []
        private(set) var events: [AgentTraceEvent] = []
        private(set) var observations = 0
        private(set) var screenshotRequests = 0
        private let lock = NSLock()

        func observed(screenshot: Bool) { lock.withLock { observations += 1; if screenshot { screenshotRequests += 1 } } }
        func execute(_ event: RemoteInputEvent) { lock.withLock { executed.append(event) } }
        func open(_ name: String) { lock.withLock { opened.append(name) } }
        func emit(_ event: AgentTraceEvent) { lock.withLock { events.append(event) } }
        func has(_ kind: AgentTraceKind) -> Bool { lock.withLock { events.contains { $0.kind == kind } } }
        var kinds: [AgentTraceKind] { lock.withLock { events.map(\.kind) } }
        var last: AgentTraceEvent? { lock.withLock { events.last } }
        func first(_ kind: AgentTraceKind) -> AgentTraceEvent? { lock.withLock { events.first { $0.kind == kind } } }
    }

    static let onePlan = #"{"plan":[{"goal":"do the thing","done_when":"it is done"}]}"#

    /// A screen with enough on it for the fast model (the first element is the one under test);
    /// `sparse` gives the near-empty screen that sends the executor to its vision model.
    private func observation(elements: [(String, String, Bool)] = [("button", "Save", false)], app: String = "Notes",
                             bundle: String = "com.apple.Notes", sparse: Bool = false) -> AgentObservation {
        var observed: [AgentObservedElement] = []
        let filler: [(String, String, Bool)] = sparse ? [] : [("button", "Cancel", false), ("button", "Help", false), ("checkbox", "Remember", false)]
        for (index, element) in (elements + filler).enumerated() {
            observed.append(AgentObservedElement(id: "e\(index + 1)", role: element.0, label: element.1,
                                                 centerX: 0.5, centerY: 0.5 + Double(index) * 0.05, width: 0.1, height: 0.04,
                                                 isEnabled: true, isSensitive: element.2))
        }
        let texts: [AgentObservedText] = sparse ? [] : (1...6).map {
            AgentObservedText(id: "t\($0)", text: "Line \($0) of the document", centerX: 0.4, centerY: 0.1 + Double($0) * 0.05,
                              width: 0.3, height: 0.02, isSensitive: false)
        }
        return AgentObservation(frontmostApplication: app, frontmostBundleIdentifier: bundle, windowTitle: nil,
                                displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil,
                                elements: observed, texts: texts, capturedAtNanoseconds: 1)
    }

    private func configuration(planner: Scripted, executor: Scripted, locality: ModelLocality = .onThisMac,
                               remoteScreenshots: Bool = false, vision: AssistantVisionPolicy = .auto,
                               steps: Int = 25, perSubtask: Int = 8, review: Int = 0) -> AssistantRunConfiguration {
        AssistantRunConfiguration(
            planner: AssistantModelRole(provider: planner, model: "big", visionModel: nil, locality: .onThisMac, displayName: "Planner big"),
            executor: AssistantModelRole(provider: executor, model: "fast", visionModel: "vision", locality: locality, displayName: "Executor fast"),
            visionPolicy: vision, screenshotsAllowedToRemote: remoteScreenshots, maximumSteps: steps, stepsPerSubtask: perSubtask,
            reviewEverySteps: review
        )
    }

    /// `changing` gives every look a different window title, the way a popover that opens and
    /// closes keeps changing the screen.
    private func makeRuntime(_ configuration: AssistantRunConfiguration, observation: AgentObservation, changing: Bool = false,
                             screens: [AgentObservation] = [],
                             resolve: @escaping @Sendable (String) async -> String? = { _ in nil },
                             orielAt: @escaping @Sendable (NormalizedPoint?) async -> Bool = { _ in false }) -> (AssistantRuntime, Recorder) {
        let recorder = Recorder()
        let dependencies = AssistantRuntime.Dependencies(
            observe: { includeScreenshot, _ in
                recorder.observed(screenshot: includeScreenshot)
                // `screens` plays out one look at a time and then stays on the last.
                var screen = screens.isEmpty ? observation : screens[min(recorder.observations - 1, screens.count - 1)]
                if changing {
                    screen = AgentObservation(frontmostApplication: observation.frontmostApplication,
                                              frontmostBundleIdentifier: observation.frontmostBundleIdentifier,
                                              windowTitle: "View \(recorder.observations)",
                                              displayWidth: observation.displayWidth, displayHeight: observation.displayHeight,
                                              pointerX: nil, pointerY: nil, elements: observation.elements, texts: observation.texts,
                                              capturedAtNanoseconds: 1)
                }
                return ScreenObservationResult(observation: screen, screenshotJPEG: includeScreenshot ? Data([1, 2, 3]) : nil, frameSequence: 1)
            },
            execute: { event in recorder.execute(event) },
            openApplication: { name in recorder.open(name) },
            emit: { event in recorder.emit(event) },
            phaseChanged: { _ in },
            now: { DispatchTime.now().uptimeNanoseconds },
            resolveApplication: resolve,
            landsOnOriel: orielAt
        )
        return (AssistantRuntime(configuration: configuration, dependencies: dependencies), recorder)
    }

    private func waitUntilDone(_ runtime: AssistantRuntime, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await runtime.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitFor(_ recorder: Recorder, _ kind: AgentTraceKind, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !recorder.has(kind), Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @Test func plannerThenExecutorThenDone() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted([
            #"{"reason":"Save is visible","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"saved","action":{"type":"done","summary":"Saved the note."}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i1", text: "save the note"))
        await waitUntilDone(runtime)

        #expect(planner.requests.count == 1 && planner.requests[0].model == "big" && planner.requests[0].imageJPEG == nil)
        #expect(planner.requests[0].messages[0].text.contains("Owner's goal: save the note"))
        #expect(executor.requests.map(\.model) == ["fast", "fast"])
        #expect(executor.requests[0].messages[0].text.contains("Your current sub-task: do the thing"))
        #expect(recorder.executed.count == 2, "pointer move then click")
        #expect(recorder.kinds.contains(.plan) && recorder.kinds.contains(.subtask) && recorder.kinds.contains(.report))
        #expect(recorder.last?.kind == .finished && recorder.last?.summary == "Saved the note.")
        #expect(recorder.screenshotRequests == 0)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(planner.released == ["big"] && executor.released == ["fast"], "Both brains are released when the run ends")
    }

    @Test func directActionsNeedNoExecutorCall() async throws {
        let planner = Scripted([
            #"{"plan":[{"action":{"type":"openApplication","name":"Notes"}},{"action":{"type":"key","key":"n","modifiers":["command"]}},{"goal":"type the title","done_when":"title shown"}]}"#,
        ])
        let executor = Scripted([#"{"action":{"type":"done","summary":"Title typed."}}"#])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i2", text: "new note"))
        await waitUntilDone(runtime)
        #expect(recorder.opened == ["Notes"])
        #expect(recorder.executed.contains { if case .key(45, .press, let modifiers) = $0 { return modifiers == [.command] } else { return false } })
        #expect(executor.requests.count == 1, "Only the screen-dependent sub-task used the executor")
        #expect(recorder.first(.plan)?.summary.contains("(direct)") == true)
        #expect(recorder.last?.kind == .finished)
    }

    @Test func aGoalThatNamesAnInstalledAppOpensItWithoutTheExecutor() async throws {
        let planner = Scripted([#"{"plan":[{"goal":"Open Slack","done_when":"Slack is in front"},{"goal":"Open Dana's DM","done_when":"the DM is open"}]}"#])
        let executor = Scripted([#"{"action":{"type":"done","summary":"Dana's DM is open."}}"#])
        let (runtime, recorder) = makeRuntime(
            configuration(planner: planner, executor: executor), observation: observation(),
            resolve: { $0.lowercased() == "slack" ? "Slack" : nil }
        )
        await runtime.run(try AgentInstruction(id: "i2b", text: "go to Slack and open Dana's DM"))
        await waitUntilDone(runtime)
        #expect(recorder.opened == ["Slack"])
        #expect(executor.requests.count == 1, "Only the DM step needed the executor; \"Dana's DM\" is not an app")
        #expect(recorder.last?.kind == .finished)
    }

    @Test func theAppTheOwnerNamedComesToTheFrontBeforePlanning() async throws {
        let planner = Scripted([#"{"done":"Nothing else to do."}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(
            configuration(planner: planner, executor: executor), observation: observation(app: "Simulator", bundle: "com.apple.iphonesimulator"),
            resolve: { $0.lowercased() == "slack" ? "Slack" : nil }
        )
        await runtime.run(try AgentInstruction(id: "i2h", text: "Go to Slack, open Dana's DM"))
        await waitUntilDone(runtime)
        #expect(recorder.opened == ["Slack"], "Slack opens before the planner is asked")
    }

    @Test func aGoalThatNamesOneThingOnScreenClicksItWithoutTheExecutor() async throws {
        let planner = Scripted([#"{"plan":[{"goal":"Open the Help page","done_when":"help is open"}]}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i2d", text: "open help"))
        await waitUntilDone(runtime)
        #expect(executor.requests.isEmpty, "The planner named a control that is on screen once")
        #expect(recorder.executed.contains { if case .mouseButton(_, .click) = $0 { return true } else { return false } })
        #expect(recorder.last?.kind == .finished)
    }

    @Test func thePlannerWatchesAndSteersWithoutWaitingForTheExecutor() async throws {
        // The executor dithers on an unchanged screen; the planner's review hint reaches its
        // next step, and a later review that sees the goal met ends the run with its answer.
        let planner = Scripted([
            Self.onePlan,
            #"{"hint":"Click Help, it is the button you need"}"#,
            #"{"done":"Help is open and says what you asked."}"#,
        ])
        let executor = Scripted([
            #"{"reason":"try","action":{"type":"key","key":"tab"}}"#,
            #"{"reason":"try again","action":{"type":"key","key":"tab"}}"#,
            #"{"reason":"follow the planner","action":{"type":"click","target":{"element":"e3"}}}"#,
            #"{"reason":"wait","action":{"type":"key","key":"down"}}"#,
            #"{"reason":"wait","action":{"type":"key","key":"down"}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor, review: 2), observation: observation())
        await runtime.run(try AgentInstruction(id: "i2f", text: "open help"))
        await waitUntilDone(runtime)
        #expect(recorder.events.contains { $0.kind == .report && $0.summary.contains("Planner steers: Click Help") })
        #expect(executor.requests.contains { $0.messages[0].text.contains("The planner, watching your steps, says: Click Help") })
        #expect(await runtime.phase == .finished(summary: "Help is open and says what you asked."))
    }

    @Test func aGoalThatSpellsOutTextTypesItWithoutTheExecutor() async throws {
        let planner = Scripted([#"{"plan":[{"goal":"Type '12*7=' into the Calculator display","done_when":"84 shows"}]}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation(app: "Calculator", bundle: "com.apple.calculator"))
        await runtime.run(try AgentInstruction(id: "i2g", text: "compute 12 times 7"))
        await waitUntilDone(runtime)
        #expect(executor.requests.isEmpty)
        #expect(recorder.events.contains { $0.kind == .executed && $0.summary == "Type \"12*7=\"" })
    }

    @Test func aQuestionEndsWithTheAnswerReadOffTheScreen() async throws {
        let planner = Scripted([
            #"{"plan":[{"goal":"Open the Help page","done_when":"help is open"}]}"#,
            #"{"done":"Line 6 of the document says what you asked."}"#,
        ])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i2e", text: "open help and tell me what it says"))
        await waitUntilDone(runtime)
        #expect(planner.requests.count == 2, "One more planner call for the answer")
        #expect(planner.requests[1].messages[0].text.contains("The owner is waiting for the answer"))
        #expect(await runtime.phase == .finished(summary: "Line 6 of the document says what you asked."))
    }

    @Test func theSameClickOnAnUnchangedScreenGoesBackToThePlanner() async throws {
        let planner = Scripted([
            Self.onePlan,
            #"{"done":"Could not find it this way."}"#,
        ])
        let executor = Scripted([
            #"{"reason":"try Save","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"try Save again","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"and again","action":{"type":"click","target":{"element":"e1"}}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i2c", text: "save it"))
        await waitUntilDone(runtime)
        #expect(recorder.executed.filter { if case .mouseButton(_, .click) = $0 { return true } else { return false } }.count == 1,
                "The second identical click was not made")
        #expect(planner.requests.count == 2)
        #expect(recorder.first(.report)?.summary.contains("changed nothing on the screen") == true)
        #expect(recorder.last?.kind == .failed, "Giving up after a stuck step is not a success")
    }

    @Test func aThirdClickInARowOnOneControlGoesBackToThePlannerEvenWhenTheScreenChanges() async throws {
        let planner = Scripted([
            Self.onePlan,
            #"{"done":"Could not find it this way."}"#,
        ])
        let executor = Scripted([
            #"{"reason":"open it","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"open it again","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"and again","action":{"type":"click","target":{"element":"e1"}}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation(), changing: true)
        await runtime.run(try AgentInstruction(id: "i3c", text: "open it"))
        await waitUntilDone(runtime)
        #expect(recorder.executed.filter { if case .mouseButton(_, .click) = $0 { return true } else { return false } }.count == 2,
                "Two clicks were made, the third was not")
        #expect(planner.requests.count == 2, "The planner was asked what to do next")
        #expect(recorder.first(.report)?.summary.contains("clicked 2 times in a row") == true)
    }

    @Test func clicksAndKeysThatWouldLandInOrielAreRefused() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted([
            #"{"reason":"stop it","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"confirm","action":{"type":"key","key":"return"}}"#,
            #"{"reason":"done","action":{"type":"done","summary":"Done."}}"#,
        ])
        // Oriel's window is under the first control and holds the keyboard.
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: observation(elements: [("button", "Stop Assistant", false)]),
                                              orielAt: { point in point == nil || (point!.y < 0.52) })
        await runtime.run(try AgentInstruction(id: "own", text: "stop the assistant"))
        await waitUntilDone(runtime)
        #expect(recorder.executed.isEmpty, "Nothing reached Oriel's own windows")
        let refusals = recorder.events.filter { $0.kind == .blocked }.map(\.summary)
        #expect(refusals.count == 2)
        #expect(refusals.allSatisfy { $0.contains("does not operate its own windows") })
        let lastPrompt = executor.requests.last?.messages.last?.text ?? ""
        #expect(lastPrompt.contains("refused by Oriel"), "The executor is told why")
    }

    private func slack(_ title: String, focus: String? = nil, lines: [String] = []) -> AgentObservation {
        let texts = lines.enumerated().map { index, line in
            AgentObservedText(id: "t\(index + 1)", text: line, centerX: 0.5, centerY: 0.3 + Double(index) * 0.05,
                              width: 0.2, height: 0.02, isSensitive: false)
        }
        return AgentObservation(frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: title,
                                displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil, elements: [], texts: texts,
                                capturedAtNanoseconds: 1, focusedField: focus)
    }

    @Test func theJumpBoxWaitsForTheChannelThenTheAnswerIsRead() async throws {
        let planner = Scripted([#"{"done":"Sam Lee posted last: the build is green."}"#])
        let executor = Scripted([])
        let general = "general (Channel) - acme - Slack"
        let (runtime, recorder) = makeRuntime(
            configuration(planner: planner, executor: executor), observation: slack(general),
            screens: [
                slack(general),                                                         // before the jump
                slack(general, focus: "AXComboBox: Query"),                             // the box is open
                slack(general, focus: "AXComboBox: Query"),                             // no matches yet
                slack(general, focus: "AXComboBox: Query", lines: ["# qa", "Quality"]),  // #qa is listed
                slack(general),                                                         // still loading
                slack("qa (Channel) - acme - Slack"),
            ]
        )
        await runtime.run(try AgentInstruction(id: "qa", text: "In Slack, open #qa and tell me who posted the last message there and what it says."))
        await waitUntilDone(runtime)
        let typed = recorder.executed.compactMap { event -> String? in
            if case let .textInput(text) = event { return text } else { return nil }
        }.joined()
        #expect(typed == "qa")
        #expect(recorder.executed.filter { if case .key = $0 { return true } else { return false } }.count == 2, "Command+K and Return")
        #expect(planner.requests.count == 1, "Nothing to plan: the channel is open and its last message is on screen")
        #expect(executor.requests.isEmpty)
        #expect(recorder.last?.summary == "Sam Lee posted last: the build is green.")
    }

    @Test func aReadingStepReachedByNavigationIsStillRead() async throws {
        let planner = Scripted([
            #"{"plan":[{"goal":"Read the messages from Dana in this chat window.","done_when":"his messages are read"}]}"#,
            #"{"done":"He wrote that the release moves to Friday."}"#,
        ])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: slack("dana (DM) - acme - Slack"))
        await runtime.run(try AgentInstruction(id: "dm", text: "go to Slack and check what Dana wrote about the release"))
        await waitUntilDone(runtime)
        #expect(planner.requests.count == 2, "The plan, then the answer read off the screen")
        #expect(executor.requests.isEmpty)
        #expect(recorder.last?.kind == .finished)
        #expect(recorder.last?.summary == "He wrote that the release moves to Friday.")
    }

    @Test func theLastMessageOfAnOpenConversationIsReadWithoutPlanning() async throws {
        let planner = Scripted([#"{"done":"Alex Rivera: Lunch at noon works for me."}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: slack("dana (DM) - acme - Slack"))
        await runtime.run(try AgentInstruction(id: "last", text: "Go to Slack, open Dana's DM and read me the last message."))
        await waitUntilDone(runtime)
        #expect(planner.requests.count == 1, "One call, and it reads the answer")
        #expect(planner.requests.first?.messages.last?.text.contains("Every step is done") == true)
        #expect(executor.requests.isEmpty)
        #expect(recorder.last?.summary == "Alex Rivera: Lunch at noon works for me.")
    }

    @Test func aReadingStepInAnOpenConversationSkipsTheExecutor() async throws {
        let planner = Scripted([
            #"{"plan":[{"goal":"Read what Dana said about the release","done_when":"his message is read"}]}"#,
            #"{"done":"He said the release goes out on Friday."}"#,
        ])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: slack("dana (DM) - acme - Slack"))
        await runtime.run(try AgentInstruction(id: "about", text: "In Slack, open Dana's DM and tell me what he said about the release"))
        await waitUntilDone(runtime)
        #expect(executor.requests.isEmpty, "The conversation was open; the answer was read off it")
        #expect(planner.requests.count == 2)
        #expect(recorder.last?.summary == "He said the release goes out on Friday.")
    }

    @Test func aNamedConversationIsJumpedToBeforePlanning() async throws {
        let planner = Scripted([#"{"done":"Nothing left to do."}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: slack("general (Channel) - acme - Slack"))
        await runtime.run(try AgentInstruction(id: "jump", text: "In Slack, open Dana's DM and read me the last message"))
        await waitUntilDone(runtime)
        let keys = recorder.executed.compactMap { event -> Set<KeyModifier>? in
            if case let .key(_, _, modifiers) = event { return modifiers } else { return nil }
        }
        #expect(keys.first == [.command], "Command+K opened the jump box before anything was planned")
        #expect(keys.count == 2, "The box did not take focus here, so Escape closed it")
        #expect(planner.requests.count == 1)
    }

    @Test func anAnswerInPlainWordsIsStillTheAnswer() async throws {
        let planner = Scripted(["The last message is from Alex Rivera at 4:31 PM and says 'Yes please'."])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: slack("qa (Channel) - acme - Slack"))
        await runtime.run(try AgentInstruction(id: "prose", text: "In Slack, open #qa and tell me who posted the last message there and what it says."))
        await waitUntilDone(runtime)
        #expect(recorder.last?.kind == .finished)
        #expect(recorder.last?.summary == "The last message is from Alex Rivera at 4:31 PM and says 'Yes please'.")
    }

    @Test func calculatorsDisplayIsTheAnswerWhenItShowsTheSum() async throws {
        let planner = Scripted([])
        let executor = Scripted([])
        let display = AgentObservation(
            frontmostApplication: "Calculator", frontmostBundleIdentifier: "com.apple.calculator", windowTitle: "Calculator",
            displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil, elements: [],
            texts: [AgentObservedText(id: "t1", text: "12×7", centerX: 0.1, centerY: 0.6, width: 0.05, height: 0.02, isSensitive: false),
                    AgentObservedText(id: "t2", text: "84", centerX: 0.1, centerY: 0.65, width: 0.05, height: 0.04, isSensitive: false),
                    AgentObservedText(id: "t3", text: "1:17 AM", centerX: 0.9, centerY: 0.01, width: 0.05, height: 0.02, isSensitive: false)],
            capturedAtNanoseconds: 1)
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: display)
        await runtime.run(try AgentInstruction(id: "calc2", text: "open calculator, compute 12 times 7 and tell me the result"))
        await waitUntilDone(runtime)
        #expect(planner.requests.isEmpty, "No model call at all")
        #expect(recorder.last?.kind == .finished)
        #expect(recorder.last?.summary == "12 × 7 = 84")
    }

    @Test func calculatorSumsAreTypedWithoutPlanningAndAnswered() async throws {
        let planner = Scripted([#"{"done":"84"}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: observation(app: "Calculator", bundle: "com.apple.calculator"))
        await runtime.run(try AgentInstruction(id: "calc", text: "compute 12 times 7"))
        await waitUntilDone(runtime)
        let typed = recorder.executed.compactMap { event -> String? in
            if case let .textInput(text) = event { return text } else { return nil }
        }.joined()
        #expect(typed == "12*7=")
        #expect(recorder.executed.filter { if case .key = $0 { return true } else { return false } }.count == 2, "Escape twice clears the display")
        #expect(planner.requests.count == 1, "The planner only reads the answer")
        #expect(executor.requests.isEmpty)
        #expect(recorder.last?.kind == .finished)
        #expect(recorder.last?.summary == "84")
    }

    @Test func plannerCanFinishWithoutTheExecutor() async throws {
        let planner = Scripted([#"{"done":"Notes is already open."}"#])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i3", text: "open notes"))
        await waitUntilDone(runtime)
        #expect(executor.requests.isEmpty && recorder.executed.isEmpty)
        #expect(await runtime.phase == .finished(summary: "Notes is already open."))
    }

    @Test func escalationBringsARevisedPlan() async throws {
        let planner = Scripted([
            #"{"plan":[{"goal":"export via toolbar","done_when":"pdf saved"}]}"#,
            #"{"plan":[{"goal":"export via File menu","done_when":"pdf saved"}],"note":"toolbar has no export"}"#,
        ])
        let executor = Scripted([
            #"{"action":{"type":"escalate","reason":"no export button here"}}"#,
            #"{"action":{"type":"done","summary":"Exported from the File menu."}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i4", text: "export pdf"))
        await waitUntilDone(runtime)
        #expect(planner.requests.count == 2)
        #expect(planner.requests[1].messages[0].text.contains("stuck") && planner.requests[1].messages[0].text.contains("no export button here"))
        #expect(recorder.kinds.filter { $0 == .plan }.count == 2)
        #expect(recorder.first(.report)?.summary.contains("stuck") == true)
        #expect(recorder.last?.kind == .finished)
    }

    @Test func protectedActionsAreRefusedAndTheExecutorIsTold() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted([
            #"{"action":{"type":"type","text":"483921"}}"#,
            #"{"action":{"type":"done","summary":"Left the code to the owner."}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i5", text: "enter the code"))
        await waitUntilDone(runtime)
        #expect(recorder.executed.isEmpty, "Nothing reaches the input broker")
        #expect(recorder.has(.blocked))
        #expect(executor.requests.count == 2 && executor.requests[1].messages[0].text.contains("refused by Oriel"))
    }

    @Test func approvalWaitsForThePhone() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted([
            #"{"action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"action":{"type":"done","summary":"Sent."}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor),
                                              observation: observation(elements: [("button", "Send", false)]))
        await runtime.run(try AgentInstruction(id: "i6", text: "send it"))
        await waitFor(recorder, .needsApproval)
        #expect(recorder.first(.needsApproval)?.stepID == "i6#1")
        #expect(recorder.executed.isEmpty, "Nothing happens before approval")
        if case .waitingApproval = await runtime.phase {} else { Issue.record("runtime should wait") }
        await runtime.control(.approve(stepID: "i6#1"))
        await waitUntilDone(runtime)
        #expect(recorder.executed.count == 2, "Approved: the click happens")
        #expect(recorder.last?.kind == .finished)
    }

    @Test func deniedDirectActionGoesBackToThePlanner() async throws {
        let planner = Scripted([
            #"{"plan":[{"action":{"type":"key","key":"q","modifiers":["command"]}}]}"#,
            #"{"done":"Left the app open as the owner wants."}"#,
        ])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i7", text: "quit notes"))
        await waitFor(recorder, .needsApproval)
        await runtime.control(.deny(stepID: "i7#1"))
        await waitUntilDone(runtime)
        #expect(recorder.executed.isEmpty)
        #expect(recorder.has(.denied) && planner.requests.count == 2)
        #expect(recorder.last?.kind == .finished)
    }

    @Test func questionsPauseUntilAnswered() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted([
            #"{"action":{"type":"ask","question":"Which note?"}}"#,
            #"{"action":{"type":"done","summary":"Opened the blue one."}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i8", text: "open my note"))
        await waitFor(recorder, .asked)
        await runtime.control(.answer(stepID: "i8#1", text: "the blue one"))
        await waitUntilDone(runtime)
        #expect(recorder.has(.answered))
        #expect(executor.requests.count == 2 && executor.requests[1].messages[0].text.contains("owner answered your question: the blue one"))
        #expect(recorder.last?.kind == .finished)
    }

    @Test func plannerQuestionsReachTheOwnerToo() async throws {
        let planner = Scripted([
            #"{"ask":"Which account should I use?"}"#,
            #"{"done":"Using the work account; nothing else needed."}"#,
        ])
        let executor = Scripted([])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i9", text: "send the report"))
        await waitFor(recorder, .asked)
        await runtime.control(.answer(stepID: "i9#plan", text: "work"))
        await waitUntilDone(runtime)
        #expect(planner.requests.count == 2 && planner.requests[1].messages[0].text.contains("The owner answered: work"))
        #expect(recorder.last?.kind == .finished)
    }

    @Test func stopEndsTheRun() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted(Array(repeating: #"{"action":{"type":"wait","milliseconds":300}}"#, count: 20))
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i10", text: "wait around"))
        try? await Task.sleep(nanoseconds: 250_000_000)
        await runtime.stop()
        await waitUntilDone(runtime)
        #expect(await runtime.phase == .stopped)
        #expect(recorder.last?.kind == .stopped)
    }

    @Test func subtaskBudgetAsksThePlannerAndTheRunLimitEndsIt() async throws {
        let planner = Scripted([Self.onePlan, Self.onePlan, Self.onePlan])
        let executor = Scripted(Array(repeating: #"{"action":{"type":"wait","milliseconds":60}}"#, count: 30))
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: executor, steps: 5, perSubtask: 2), observation: observation())
        await runtime.run(try AgentInstruction(id: "i11", text: "loop", maximumSteps: 5))
        await waitUntilDone(runtime)
        #expect(planner.requests.count >= 2, "A sub-task that runs out of steps goes back to the planner")
        #expect(recorder.last?.kind == .failed)
        #expect(recorder.last?.summary.contains("step limit") == true)
        #expect(executor.requests.count == 5)
    }

    @Test func lookSwitchesToTheVisionModelOnlyWhereScreenshotsMayGo() async throws {
        let local = Scripted([#"{"action":{"type":"look","reason":"icons only"}}"#, #"{"action":{"type":"done","summary":"Seen."}}"#])
        let (runtime, recorder) = makeRuntime(configuration(planner: Scripted([Self.onePlan]), executor: local), observation: observation())
        await runtime.run(try AgentInstruction(id: "i12", text: "look"))
        await waitUntilDone(runtime)
        #expect(local.requests.map(\.model) == ["fast", "vision"])
        #expect(local.requests.count == 2 && local.requests[1].imageJPEG != nil && recorder.screenshotRequests == 1)

        let remote = Scripted([#"{"action":{"type":"look","reason":"icons only"}}"#, #"{"action":{"type":"done","summary":"Seen."}}"#])
        let (remoteRuntime, remoteRecorder) = makeRuntime(configuration(planner: Scripted([Self.onePlan]), executor: remote, locality: .internet), observation: observation())
        await remoteRuntime.run(try AgentInstruction(id: "i13", text: "look", allowScreenshots: true))
        await waitUntilDone(remoteRuntime)
        #expect(remote.requests.allSatisfy { $0.imageJPEG == nil } && remoteRecorder.screenshotRequests == 0)
        #expect(remote.requests.count == 2 && remote.requests[1].messages[0].text.contains("screenshots are not shared"))

        let consented = Scripted([#"{"action":{"type":"look","reason":"icons only"}}"#, #"{"action":{"type":"done","summary":"Seen."}}"#])
        let (consentedRuntime, consentedRecorder) = makeRuntime(configuration(planner: Scripted([Self.onePlan]), executor: consented, locality: .internet, remoteScreenshots: true), observation: observation())
        await consentedRuntime.run(try AgentInstruction(id: "i14", text: "look", allowScreenshots: true))
        await waitUntilDone(consentedRuntime)
        #expect(consented.requests.count == 2 && consented.requests[1].imageJPEG != nil && consentedRecorder.screenshotRequests == 1)
    }

    @Test func nearEmptyScreensGoStraightToTheVisionModel() async throws {
        let executor = Scripted([#"{"action":{"type":"done","summary":"Nothing here."}}"#])
        let (runtime, recorder) = makeRuntime(configuration(planner: Scripted([Self.onePlan]), executor: executor),
                                              observation: observation(sparse: true))
        await runtime.run(try AgentInstruction(id: "i17", text: "look around"))
        await waitUntilDone(runtime)
        #expect(executor.requests.map(\.model) == ["vision"], "No controls and no text: the text picture is blind")
        #expect(executor.requests.first?.imageJPEG != nil && recorder.screenshotRequests == 1)

        let never = Scripted([#"{"action":{"type":"done","summary":"Nothing here."}}"#])
        let (neverRuntime, neverRecorder) = makeRuntime(configuration(planner: Scripted([Self.onePlan]), executor: never, vision: .never),
                                                        observation: observation(sparse: true))
        await neverRuntime.run(try AgentInstruction(id: "i18", text: "look around"))
        await waitUntilDone(neverRuntime)
        #expect(never.requests.map(\.model) == ["fast"] && neverRecorder.screenshotRequests == 0, "Vision switched off stays off")
    }

    @Test func unusablePlannerRepliesFailTheRun() async throws {
        let planner = Scripted(["I would open Notes first.", "still prose"])
        let (runtime, recorder) = makeRuntime(configuration(planner: planner, executor: Scripted([])), observation: observation())
        await runtime.run(try AgentInstruction(id: "i15", text: "save"))
        await waitUntilDone(runtime)
        #expect(recorder.last?.kind == .failed && planner.requests.count == 2)
    }

    @Test func openApplicationAndTypingUseTheirPaths() async throws {
        let executor = Scripted([
            #"{"action":{"type":"openApplication","name":"Notes"}}"#,
            #"{"action":{"type":"type","text":"hello there, this is a long line of text"}}"#,
            #"{"action":{"type":"key","key":"return","modifiers":[]}}"#,
            #"{"action":{"type":"done","summary":"Typed."}}"#,
        ])
        let (runtime, recorder) = makeRuntime(configuration(planner: Scripted([Self.onePlan]), executor: executor), observation: observation())
        await runtime.run(try AgentInstruction(id: "i16", text: "type hello in notes"))
        await waitUntilDone(runtime)
        #expect(recorder.opened == ["Notes"])
        let typed = recorder.executed.compactMap { event -> String? in
            if case let .textInput(text) = event { return text } else { return nil }
        }.joined()
        #expect(typed == "hello there, this is a long line of text")
        #expect(recorder.executed.contains { if case .key(36, .press, _) = $0 { return true } else { return false } })
    }

    @Test func plannerRepliesParse() throws {
        if case let .plan(subtasks, note) = try AssistantPlanner.parse("""
        ```json
        {"plan":[{"action":{"type":"openApplication","name":"Safari"}},{"goal":"Search for weather","done_when":"results show"},"Read the first result"],"note":"quick"}
        ```
        """) {
            #expect(subtasks.count == 3 && subtasks[0].directAction == .openApplication(name: "Safari"))
            #expect(subtasks[1].goal == "Search for weather" && subtasks[1].doneWhen == "results show" && subtasks[1].directAction == nil)
            #expect(subtasks[2].goal == "Read the first result" && subtasks[2].id == 3)
            #expect(note == "quick")
        } else {
            Issue.record("expected a plan")
        }
        // A direct click on a screen id is not direct: the executor resolves the named control live.
        if case let .plan(subtasks, _) = try AssistantPlanner.parse(
            #"{"plan":[{"action":{"type":"click","target":"[e1]"}},{"action":{"type":"key","key":"return"}}]}"#,
            observation: observation()
        ) {
            #expect(subtasks.count == 2 && subtasks[0].directAction == nil && subtasks[0].goal == "Click \"Save\" (button)")
            #expect(subtasks[1].directAction == .key(name: "return", modifiers: []))
        } else {
            Issue.record("expected a plan")
        }
        #expect(try AssistantPlanner.parse(#"{"done":"Already there."}"#) == .done(summary: "Already there."))
        #expect(try AssistantPlanner.parse(#"{"ask":"Which one?"}"#) == .ask(question: "Which one?"))
        #expect(throws: AssistantPlannerError.malformed) { try AssistantPlanner.parse("no json here") }
        #expect(throws: AssistantPlannerError.emptyPlan) { try AssistantPlanner.parse(#"{"plan":[]}"#) }
        // A direct "done" or "ask" inside a plan item is not an action; it becomes a goal or is dropped.
        if case let .plan(subtasks, _) = try AssistantPlanner.parse(#"{"plan":[{"action":{"type":"done","summary":"x"},"goal":"finish up"}]}"#) {
            #expect(subtasks.count == 1 && subtasks[0].directAction == nil && subtasks[0].goal == "finish up")
        } else {
            Issue.record("expected a plan")
        }
    }
}
