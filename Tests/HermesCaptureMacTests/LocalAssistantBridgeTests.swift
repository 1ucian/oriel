import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

/// The local goal bridge through the files a local tool uses, with scripted models and a
/// canned screen: goal validation, busy, cancel, timeout, and the refusals of a run nobody
/// watches. No hardware, no network.
@MainActor
struct LocalAssistantBridgeTests {
    typealias Scripted = AssistantRuntimeTests.Scripted
    typealias Recorder = AssistantRuntimeTests.Recorder

    /// A model that never answers, so the run stays in progress until it is stopped.
    final class Stalling: AssistantModelProvider {
        var displayName: String { "stalling" }
        func complete(_ request: AssistantModelRequest) async throws -> AssistantModelReply {
            try await Task.sleep(for: .seconds(60))
            throw AssistantModelProviderError.emptyReply
        }
        func listModels() async throws -> [String] { [] }
    }

    struct TimedOut: Error {}

    static let onePlan = AssistantRuntimeTests.onePlan

    private func observation(elements: [(String, String)] = [("button", "Save")]) -> AgentObservation {
        let filler = [("button", "Cancel"), ("button", "Help"), ("checkbox", "Remember")]
        let observed = (elements + filler).enumerated().map { index, element in
            AgentObservedElement(id: "e\(index + 1)", role: element.0, label: element.1, centerX: 0.5,
                                 centerY: 0.5 + Double(index) * 0.05, width: 0.1, height: 0.04, isEnabled: true, isSensitive: false)
        }
        let texts = (1...6).map {
            AgentObservedText(id: "t\($0)", text: "Line \($0) of the document", centerX: 0.4, centerY: 0.1 + Double($0) * 0.05,
                              width: 0.3, height: 0.02, isSensitive: false)
        }
        return AgentObservation(frontmostApplication: "Notes", frontmostBundleIdentifier: "com.apple.Notes", windowTitle: nil,
                                displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil,
                                elements: observed, texts: texts, capturedAtNanoseconds: 1)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let recorder = Recorder()
        var bridge: LocalAssistantBridge!

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("oriel-goal-bridge-\(UUID().uuidString)", isDirectory: true)
        }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        func writeGoal(_ json: String) throws {
            try Data(json.utf8).write(to: url("goal.json"), options: .atomic)
        }

        func trace() -> [[String: String]] {
            let text = (try? String(contentsOf: url("trace.jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
            }
        }

        func cleanup() async {
            await bridge?.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(planner: any AssistantModelProvider, executor: any AssistantModelProvider = Scripted([]),
                             screen: AgentObservation? = nil, frontmost: String? = "Notes", phoneRunActive: Bool = false,
                             timeLimit: Duration = .seconds(30), goalBeforeStart: String? = nil) throws -> Fixture {
        let fixture = Fixture()
        if let goalBeforeStart {
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
            try fixture.writeGoal(goalBeforeStart)
        }
        let recorder = fixture.recorder
        let screen = screen ?? observation()
        let configuration = AssistantRunConfiguration(
            planner: AssistantModelRole(provider: planner, model: "big", visionModel: nil, locality: .onThisMac, displayName: "Planner big"),
            executor: AssistantModelRole(provider: executor, model: "fast", visionModel: "vision", locality: .onThisMac, displayName: "Executor fast"),
            visionPolicy: .auto, screenshotsAllowedToRemote: false, maximumSteps: 25, stepsPerSubtask: 8, reviewEverySteps: 0
        )
        let machine = LocalAssistantMachine(
            observe: { includeScreenshot, _ in
                recorder.observed(screenshot: includeScreenshot)
                return ScreenObservationResult(observation: screen, screenshotJPEG: nil, frameSequence: 1)
            },
            execute: { event in recorder.execute(event) },
            openApplication: { name in recorder.open(name) },
            resolveApplication: { _ in nil },
            landsOnOriel: { _ in false },
            frontmostApplication: { frontmost },
            beginInput: { _ in },
            endInput: {}
        )
        fixture.bridge = LocalAssistantBridge(directory: fixture.directory, pollInterval: .milliseconds(10), runTimeLimit: timeLimit,
                                              machine: machine, configuration: { configuration }, phoneRunActive: { phoneRunActive })
        try fixture.bridge.start()
        return fixture
    }

    private func result(_ fixture: Fixture, id: String?, timeout: Duration = .seconds(10)) async throws -> LocalAssistantResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: fixture.url("result.json")),
               let result = try? JSONDecoder().decode(LocalAssistantResult.self, from: data), result.id == id {
                return result
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimedOut()
    }

    private func waitUntilRunning(_ fixture: Fixture) async throws {
        for _ in 0..<500 where !fixture.bridge.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.bridge.isRunning)
    }

    // MARK: Goals

    @Test func goalsAreValidated() throws {
        let goal = try LocalAssistantGoal.parse(Data(#"{"id":"g1","instruction":"read the title","app":"Notes","maxSteps":5,"typeAllowed":["hello"]}"#.utf8))
        #expect(goal.id == "g1" && goal.instruction.text == "read the title" && goal.instruction.maximumSteps == 5)
        #expect(goal.app == "Notes" && goal.typeAllowed == ["hello"])
        #expect(!goal.instruction.allowScreenshots)

        func invalid(_ json: String) -> LocalAssistantGoal.Invalid? {
            do {
                _ = try LocalAssistantGoal.parse(Data(json.utf8))
                return nil
            } catch {
                return error as? LocalAssistantGoal.Invalid
            }
        }
        #expect(invalid(#"{"instruction":"x","maxSteps":3}"#) == .init(id: nil, why: "\"id\" is missing or empty"))
        #expect(invalid(#"{"id":"  ","instruction":"x","maxSteps":3}"#) == .init(id: nil, why: "\"id\" is missing or empty"))
        #expect(invalid(#"{"id":"g2","instruction":"x","maxSteps":31}"#) == .init(id: "g2", why: "\"maxSteps\" must be 1 to 30"))
        #expect(invalid(#"{"id":"g2","instruction":"x","maxSteps":0}"#)?.id == "g2")
        #expect(invalid(#"{"id":"g2","instruction":"x"}"#) == .init(id: "g2", why: "\"maxSteps\" is missing"))
        #expect(invalid(#"{"id":"g2","instruction":"x","maxSteps":"5"}"#) == .init(id: "g2", why: "\"maxSteps\" has the wrong type"))
        #expect(invalid(#"{"id":"g2","maxSteps":3}"#)?.why == "\"instruction\" is missing or empty")
        #expect(invalid(#"{"id":"g2","instruction":"x","maxSteps":3,"app":" "}"#)?.why == "\"app\" is empty")
        #expect(invalid(#"{"id":"g3","instruction":"#) == .init(id: nil, why: "goal.json is not one JSON object with a string \"id\""))
    }

    @Test func goalJSONThatCannotBeReadIsReportedInvalid() async throws {
        let fixture = try makeFixture(planner: Scripted([]))
        try fixture.writeGoal("not json")
        let reported = try await result(fixture, id: nil)
        #expect(reported.status == .invalid && reported.steps == 0)
        let raw = try String(contentsOf: fixture.url("result.json"), encoding: .utf8)
        #expect(raw.contains(#""id":null"#), "The id key is there, null")
        await fixture.cleanup()
    }

    @Test func aGoalWrittenBeforeTheBridgeStartedDoesNotRun() async throws {
        let planner = Scripted([Self.onePlan])
        let fixture = try makeFixture(planner: planner, goalBeforeStart: #"{"id":"stale","instruction":"save the note","maxSteps":3}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("result.json").path))
        #expect(planner.requests.isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        await fixture.cleanup()
    }

    // MARK: Runs

    @Test func aGoalRunsAndReportsItsAnswerStepsAndTrace() async throws {
        let planner = Scripted([Self.onePlan])
        let executor = Scripted([
            #"{"reason":"Save is visible","action":{"type":"click","target":{"element":"e1"}}}"#,
            #"{"reason":"saved","action":{"type":"done","summary":"Saved the note."}}"#,
        ])
        let fixture = try makeFixture(planner: planner, executor: executor)
        try fixture.writeGoal(#"{"id":"run-1","instruction":"save the note","app":"Notes","maxSteps":5}"#)
        let reported = try await result(fixture, id: "run-1")
        #expect(reported.status == .done && reported.answer == "Saved the note." && reported.why == nil)
        #expect(reported.steps == 2 && reported.elapsedMs > 0)
        #expect(fixture.recorder.executed.count == 2, "pointer move then click")
        let trace = fixture.trace()
        #expect(trace.first?["kind"] == "started" && trace.last?["kind"] == "finished")
        #expect(trace.allSatisfy { $0["t"]?.hasSuffix("Z") == true && $0["text"] != nil })

        // The same id written again is not a new goal.
        try fixture.writeGoal(#"{"id":"run-1","instruction":"save the note","app":"Notes","maxSteps":5}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(planner.requests.count == 1 && !fixture.bridge.isRunning)
        await fixture.cleanup()
    }

    @Test func aSecondGoalWhileOneRunsIsBusyAndTheFirstCanBeCancelled() async throws {
        let fixture = try makeFixture(planner: Stalling())
        try fixture.writeGoal(#"{"id":"first","instruction":"save the note","maxSteps":5}"#)
        try await waitUntilRunning(fixture)
        try fixture.writeGoal(#"{"id":"second","instruction":"save the note","maxSteps":5}"#)
        let busy = try await result(fixture, id: "second")
        #expect(busy.status == .busy && busy.why == "Another local run is in progress.")

        let clock = ContinuousClock()
        let asked = clock.now
        try Data("first\n".utf8).write(to: fixture.url("cancel"), options: .atomic)
        let cancelled = try await result(fixture, id: "first")
        #expect(cancelled.status == .cancelled)
        #expect(asked.duration(to: clock.now) < .seconds(2), "Cancelled promptly")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("cancel").path), "The cancel file is consumed")
        #expect(fixture.recorder.executed.isEmpty && !fixture.bridge.isRunning)
        await fixture.cleanup()
    }

    @Test func aRunFromThePhoneMakesALocalGoalBusy() async throws {
        let planner = Scripted([Self.onePlan])
        let fixture = try makeFixture(planner: planner, phoneRunActive: true)
        try fixture.writeGoal(#"{"id":"while-phone","instruction":"save the note","maxSteps":5}"#)
        let reported = try await result(fixture, id: "while-phone")
        #expect(reported.status == .busy && reported.why == "A run from the phone is in progress.")
        #expect(planner.requests.isEmpty)
        await fixture.cleanup()
    }

    @Test func aRunPastItsTimeLimitStopsAsATimeout() async throws {
        let fixture = try makeFixture(planner: Stalling(), timeLimit: .milliseconds(200))
        try fixture.writeGoal(#"{"id":"slow","instruction":"save the note","maxSteps":5}"#)
        let reported = try await result(fixture, id: "slow")
        #expect(reported.status == .timeout)
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    // MARK: Nobody is there

    @Test func aStepThatNeedsApprovalEndsTheRunWithNothingSent() async throws {
        let executor = Scripted([#"{"reason":"send it","action":{"type":"click","target":{"element":"e1"}}}"#])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor, screen: observation(elements: [("button", "Send")]))
        try fixture.writeGoal(#"{"id":"approve","instruction":"save the note","maxSteps":5}"#)
        let reported = try await result(fixture, id: "approve")
        #expect(reported.status == .needsApproval && reported.why == "Clicking \"Send\" needs your approval.")
        #expect(fixture.recorder.executed.isEmpty)
        #expect(fixture.trace().contains { $0["kind"] == "needsApproval" })
        await fixture.cleanup()
    }

    @Test func aPointClickIsRefused() async throws {
        let executor = Scripted([#"{"reason":"there","action":{"type":"click","target":{"x":0.5,"y":0.5}}}"#])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor)
        try fixture.writeGoal(#"{"id":"point","instruction":"save the note","maxSteps":5}"#)
        let reported = try await result(fixture, id: "point")
        #expect(reported.status == .blocked && reported.why?.contains("not a screen point") == true)
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    @Test func typingTextOutsideTypeAllowedIsRefusedAndKeptOutOfTheTrace() async throws {
        let executor = Scripted([#"{"reason":"type it","action":{"type":"type","text":"hello world"}}"#])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor)
        try fixture.writeGoal(#"{"id":"typing","instruction":"save the note","maxSteps":5,"typeAllowed":["goodbye"]}"#)
        let reported = try await result(fixture, id: "typing")
        #expect(reported.status == .blocked && reported.why == "Typing text that is not in typeAllowed (11 characters) was refused.")
        #expect(fixture.recorder.executed.isEmpty)
        let trace = try String(contentsOf: fixture.url("trace.jsonl"), encoding: .utf8)
        #expect(!trace.contains("hello world") && trace.contains("(11 characters)"))
        await fixture.cleanup()
    }

    @Test func typingATextInTypeAllowedGoesThrough() async throws {
        let executor = Scripted([
            #"{"reason":"type it","action":{"type":"type","text":"hello"}}"#,
            #"{"reason":"typed","action":{"type":"done","summary":"Typed hello."}}"#,
        ])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor)
        try fixture.writeGoal(#"{"id":"typed","instruction":"save the note","maxSteps":5,"typeAllowed":["hello"]}"#)
        let reported = try await result(fixture, id: "typed")
        #expect(reported.status == .done)
        #expect(fixture.recorder.executed.contains { if case .textInput("hello") = $0 { return true } else { return false } })
        await fixture.cleanup()
    }

    @Test func inputGoesOnlyToTheGoalsApp() async throws {
        let executor = Scripted([#"{"reason":"save","action":{"type":"click","target":{"element":"e1"}}}"#])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor, frontmost: "Finder")
        try fixture.writeGoal(#"{"id":"elsewhere","instruction":"save the note","app":"Notes","maxSteps":5}"#)
        let reported = try await result(fixture, id: "elsewhere")
        #expect(reported.status == .blocked && reported.why == "Notes is not in front (Finder is), so nothing was sent.")
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    @Test func aQuestionEndsTheRun() async throws {
        let executor = Scripted([#"{"reason":"unsure","action":{"type":"ask","question":"Which note?"}}"#])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor)
        try fixture.writeGoal(#"{"id":"question","instruction":"save the note","maxSteps":5}"#)
        let reported = try await result(fixture, id: "question", timeout: .seconds(5))
        #expect(reported.status == .failed && reported.why == "Asked \"Which note?\", and no one is there to answer.")
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    @Test func aReadOnlyGoalBlocksAnyActionWithNothingSent() async throws {
        let executor = Scripted([#"{"reason":"click it","action":{"type":"click","target":{"element":"e1"}}}"#])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor)
        try fixture.writeGoal(#"{"id":"ro","instruction":"what is on the screen","maxSteps":5,"readOnly":true}"#)
        let reported = try await result(fixture, id: "ro")
        #expect(reported.status == .blocked && reported.why == "read-only run")
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    @Test func aReadOnlyGoalCanStillAnswerFromTheScreen() async throws {
        let planner = Scripted([#"{"done":"Line 6 of the document."}"#])
        let fixture = try makeFixture(planner: planner, executor: Scripted([]))
        try fixture.writeGoal(#"{"id":"ro-answer","instruction":"what does the last line say","maxSteps":5,"readOnly":true}"#)
        let reported = try await result(fixture, id: "ro-answer")
        #expect(reported.status == .done && reported.answer == "Line 6 of the document.")
        #expect(planner.requests.first?.messages.first?.text.contains("read-only request") == true)
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    @Test func anExecutorThatCannotBeReachedEndsTheRun() async throws {
        let executor = Scripted([])
        let fixture = try makeFixture(planner: Scripted([Self.onePlan]), executor: executor)
        try fixture.writeGoal(#"{"id":"down","instruction":"save the note","maxSteps":20}"#)
        let reported = try await result(fixture, id: "down")
        #expect(reported.status == .failed && reported.why == "executor model unreachable")
        #expect(executor.requests.count == 2, "Two failed calls in a row, not the rest of the steps")
        #expect(fixture.recorder.executed.isEmpty)
        await fixture.cleanup()
    }

    @Test func openingAnAppIsOnlyForTheGoalsApp() throws {
        let screen = observation()
        let confined = try LocalAssistantGoal.parse(Data(#"{"id":"o","instruction":"x","app":"Notes","maxSteps":3}"#.utf8))
        let anywhere = try LocalAssistantGoal.parse(Data(#"{"id":"o","instruction":"x","maxSteps":3}"#.utf8))
        #expect(confined.vet(.openApplication(name: "notes"), in: screen, policy: .allow, frontmostApplication: "Finder") == .allow,
                "Opening the goal's app is how it comes to the front")
        #expect(confined.vet(.openApplication(name: "Slack"), in: screen, policy: .allow, frontmostApplication: "Notes") != .allow)
        #expect(anywhere.vet(.openApplication(name: "Notes"), in: screen, policy: .allow, frontmostApplication: "Notes") != .allow)
        #expect(anywhere.vet(.click(.element(id: "e1"), button: .left, count: 1), in: screen, policy: .allow, frontmostApplication: "Finder") == .allow,
                "A goal without an app is not confined to one")
        #expect(anywhere.vet(.click(.element(id: "e9"), button: .left, count: 1), in: screen, policy: .allow, frontmostApplication: "Notes") != .allow,
                "An id that is not on screen has no label")
        #expect(anywhere.vet(.click(.element(id: "e1"), button: .left, count: 1), in: screen, policy: .block(reason: "no"), frontmostApplication: "Notes")
                == .block(reason: "no"))
    }

    @Test func aShapeRegionHasNoLabelToClickBy() {
        let screen = observation(elements: [("region", "region")])
        #expect(LocalAssistantGoal.label(of: "e1", in: screen) == nil)
        #expect(LocalAssistantGoal.label(of: "e2", in: screen) == "Cancel")
        #expect(LocalAssistantGoal.label(of: "t1", in: screen) == "Line 1 of the document")
    }

    @Test func theResultFileIsReplacedNotRewrittenInPlace() async throws {
        let fixture = try makeFixture(planner: Scripted([]))
        let resultURL = fixture.url("result.json")
        try Data("old".utf8).write(to: resultURL)
        let before = fixture.url("result-before")
        try FileManager.default.linkItem(at: resultURL, to: before)
        let inode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int }
        let oldInode = try inode(resultURL)
        try fixture.writeGoal(#"{"id":"atomic","instruction":"x","maxSteps":99}"#)
        let reported = try await result(fixture, id: "atomic")
        #expect(reported.status == .invalid)
        #expect(try String(contentsOf: before, encoding: .utf8) == "old", "A reader of the old file never sees the new one half written")
        #expect(try inode(resultURL) != oldInode)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        #expect(names == ["goal.json", "result-before", "result.json"], "No temporary file is left behind")
        await fixture.cleanup()
    }

    @Test func theGoalBridgeIsOffUntilTheOwnerTurnsItOn() throws {
        let suite = "oriel.tests.goal-bridge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!OrielApplicationDelegate.assistantBridgeEnabled(in: defaults), "Off when never set")
        defaults.set(true, forKey: OrielApplicationDelegate.assistantBridgeDefaultsKey)
        #expect(OrielApplicationDelegate.assistantBridgeEnabled(in: defaults) == OrielApplicationDelegate.localBridgesCompiledIn,
                "On only in a build that includes the local bridges")
    }
}
