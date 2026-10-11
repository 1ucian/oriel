import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

struct AssistantPlannerTests {
    @Test func placeholdersAreNotAPlan() {
        let reply = #"{"plan":[{"goal":"<one outcome in plain words>","done_when":"<what the screen shows>"},{"action":{"type":"type","text":"..."}}],"note":"<optional short note for the owner>"}"#
        #expect(throws: AssistantPlannerError.placeholderPlan) { try AssistantPlanner.parse(reply) }
    }

    @Test func realSubtasksSurviveNextToPlaceholders() throws {
        let reply = #"{"plan":[{"goal":"<one outcome in plain words>"},{"action":{"type":"openApplication","name":"Calculator"}},{"goal":"Enter 12*7= in Calculator","done_when":"the display shows 84"}],"note":"the answer they asked for"}"#
        guard case let .plan(subtasks, note) = try AssistantPlanner.parse(reply) else {
            Issue.record("expected a plan"); return
        }
        #expect(subtasks.count == 2)
        #expect(subtasks[0].directAction == .openApplication(name: "Calculator"))
        #expect(subtasks[1].goal == "Enter 12*7= in Calculator")
        #expect(subtasks[1].doneWhen == "the display shows 84")
        #expect(note == nil)
    }

    @Test func goalsThatNameAnAppAreRecognised() {
        #expect(AssistantSubtask.applicationCandidate(in: "Open Slack") == "Slack")
        #expect(AssistantSubtask.applicationCandidate(in: "Go to Slack and check the DMs") == "Slack")
        #expect(AssistantSubtask.applicationCandidate(in: "open the Calculator app.") == "Calculator")
        #expect(AssistantSubtask.applicationCandidate(in: "Switch to Visual Studio Code") == "Visual Studio Code")
        #expect(AssistantSubtask.applicationCandidate(in: "Check for new DMs from Dana") == nil)
        #expect(AssistantSubtask.applicationCandidate(in: "Open a") == nil)
        // A candidate is only a guess: "Dana's DM" is not an app, and the runtime checks.
        #expect(AssistantSubtask.applicationCandidate(in: "Open Dana's DM") == "Dana's DM")
    }

    @Test func goalsThatNameAThingOnScreenAreRecognised() {
        #expect(AssistantSubtask.targetName(in: "Open Dana's DM") == "Dana")
        #expect(AssistantSubtask.targetName(in: "Open Dana’s DM") == "Dana")
        #expect(AssistantSubtask.targetName(in: "Open the #qa channel") == "qa")
        #expect(AssistantSubtask.targetName(in: "Click on Save") == "Save")
        #expect(AssistantSubtask.targetName(in: "Read the last message") == nil)
        #expect(AssistantSubtask.targetName(in: "Search for Dana’s DM") == "Dana")
        #expect(AssistantSubtask.targetName(in: "Click on the 'Dana' DM") == "Dana")
        #expect(AssistantSubtask.targetName(in: "Open 'Sales' folder") == "Sales")
    }

    @Test func readingGoalsNameTheirConversation() {
        #expect(AssistantSubtask.mentionedConversation(in: "Read the last message from Dana") == "dana")
        #expect(AssistantSubtask.mentionedConversation(in: "Check for new DMs from Dana") == "dana")
        #expect(AssistantSubtask.mentionedConversation(in: "Read Dana’s DM") == "dana")
        #expect(AssistantSubtask.mentionedConversation(in: "Read the last message") == nil)
        #expect(AssistantSubtask.mentionedConversation(in: "Compute 12 times 7") == nil)
    }

    private func spot(_ id: String, _ label: String, x: Double, y: Double, width: Double = 0.05) -> AgentObservedText {
        AgentObservedText(id: id, text: label, centerX: x, centerY: y, width: width, height: 0.015, isSensitive: false)
    }

    @Test func theNameAloneOnItsRowIsTheNavigationEntry() {
        // A Slack sidebar: the 1:1 DM, then group DMs that also contain the name, and the name
        // as an author next to a time in the open channel.
        let texts = [
            spot("t1", "dana", x: 0.45, y: 0.30),
            spot("t2", "Morgan Hale", x: 0.45, y: 0.33, width: 0.07), spot("t3", ", ", x: 0.49, y: 0.33, width: 0.005),
            spot("t4", "dana", x: 0.515, y: 0.33), spot("t5", ", ", x: 0.545, y: 0.33, width: 0.005),
            spot("t6", "Priya Nair", x: 0.58, y: 0.33, width: 0.06),
            spot("t7", "dana", x: 0.70, y: 0.60), spot("t8", "10:23 AM", x: 0.74, y: 0.60, width: 0.03),
            spot("t9", "dana", x: 0.452, y: 0.301),
        ]
        let observation = AgentObservation(frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap",
                                           windowTitle: "general", displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil,
                                           elements: [], texts: texts, capturedAtNanoseconds: 1)
        #expect(AssistantSubtask.grounded("Dana", in: observation) == .element(id: "t1"))
        #expect(AssistantSubtask.grounded("Priya Nair", in: observation) == .element(id: "t6"))
        #expect(AssistantSubtask.grounded("Bobbi", in: observation) == nil)
    }

    @Test func ocrAvatarWordsAndInvisibleControlsDoNotHideTheEntry() {
        // What Slack really gave: the DM entry read as "Lo dana", a group as "2 dana, Priya
        // Nair", author names next to their times, and a zero-height button scrolled away.
        let texts = [
            spot("t60", "dana 11:51 AM", x: 0.633, y: 0.383, width: 0.04),
            spot("t105", "2 dana, Priya Nair", x: 0.498, y: 0.660, width: 0.08),
            spot("t126", "Lo dana", x: 0.469, y: 0.759, width: 0.04),
            spot("t71", "# new-releases", x: 0.482, y: 0.449, width: 0.05),
        ]
        let elements = [
            AgentObservedElement(id: "e45", role: "button", label: "dana", centerX: 0.616, centerY: 0.107,
                                 width: 0.026, height: 0.001, isEnabled: true, isSensitive: false),
            AgentObservedElement(id: "e72", role: "button", label: "dana", centerX: 0.616, centerY: 0.380,
                                 width: 0.026, height: 0.020, isEnabled: true, isSensitive: false),
        ]
        let observation = AgentObservation(frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap",
                                           windowTitle: "general", displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil,
                                           elements: elements, texts: texts, capturedAtNanoseconds: 1)
        #expect(AssistantSubtask.grounded("Dana", in: observation) == .element(id: "t126"))
        #expect(AssistantSubtask.grounded("new-releases", in: observation) == .element(id: "t71"))

        // A profile panel on the right also lists him: the sidebar entry on the left wins.
        let withPanel = AgentObservation(
            frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: "general",
            displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil,
            elements: elements + [AgentObservedElement(id: "e81", role: "button", label: "dana", centerX: 0.858, centerY: 0.652,
                                                       width: 0.044, height: 0.029, isEnabled: true, isSensitive: false)],
            texts: texts, capturedAtNanoseconds: 1
        )
        #expect(AssistantSubtask.grounded("Dana", in: withPanel) == .element(id: "t126"))
    }

    @Test func fillerStepsAreDroppedAndEmptyReportsRecognised() throws {
        guard case let .plan(subtasks, _) = try AssistantPlanner.parse(
            #"{"plan":[{"goal":"Open Slack"},{"goal":"Read the last message"},{"goal":"Done."}]}"#
        ) else { Issue.record("expected a plan"); return }
        #expect(subtasks.map(\.goal) == ["Open Slack", "Read the last message"])
        #expect(AssistantSubtask.isReadingGoal("Read the last message"))
        #expect(!AssistantSubtask.isReadingGoal("Open Slack"))
        #expect(AssistantSubtask.isEmptyReport("Done: Read the last message.", goal: "Read the last message"))
        #expect(!AssistantSubtask.isEmptyReport("Dana wrote: In old days we would hire two QA people.", goal: "Read the last message"))
        #expect(AssistantPrompt.keyWords("Open Dana’s DM and read me the last message") == ["dana"])
    }

    @Test func questionsAndPlannerPhrasingsAreRecognised() {
        #expect(AssistantSubtask.wantsAnAnswer("Go to Slack, open Dana’s DM and read me the last message."))
        #expect(AssistantSubtask.wantsAnAnswer("go to Slack and check if there are any new DM’s from Dana"))
        #expect(!AssistantSubtask.wantsAnAnswer("Open Calculator and compute 12 times 7"))
        #expect(AssistantSubtask.targetName(in: "Find and open Dana's direct message in Slack.") == "Dana")
        #expect(AssistantSubtask.mentionedConversation(in: "Open Dana's DM to read his last message.") == "dana")
    }

    @Test func namedConversationsAndJumpBoxesAreRecognised() {
        #expect(AssistantSubtask.conversationTarget(in: "Go to Slack, open Dana’s DM and read me the last message.") == "dana")
        #expect(AssistantSubtask.conversationTarget(in: "In Slack, open #qa and tell me who posted last") == "qa")
        #expect(AssistantSubtask.conversationTarget(in: "Open the qa channel") == "qa")
        #expect(AssistantSubtask.conversationTarget(in: "Open Calculator and compute 12 times 7") == nil)
        #expect(AssistantSubtask.quickSwitcher(for: "com.tinyspeck.slackmacgap")?.key == "k")
        #expect(AssistantSubtask.quickSwitcher(for: "com.apple.Notes") == nil)
    }

    @Test func answersComeOnlyFromTheConversationTheOwnerNamed() throws {
        func screen(_ title: String) -> AgentObservation {
            AgentObservation(frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: title,
                             displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil, elements: [], texts: [],
                             capturedAtNanoseconds: 1)
        }
        let instruction = try AgentInstruction(id: "w1", text: "Open Dana's DM and read me the last message")
        #expect(AssistantRuntime.wrongConversation(instruction, screen("dana (DM) - acme - Slack")) == nil)
        #expect(AssistantRuntime.wrongConversation(instruction, screen("general (Channel) - acme - Slack"))?.hasPrefix("Could not open dana") == true)
        #expect(AssistantRuntime.wrongConversation(instruction, screen("Sam Lee, dana (DM) - acme - Slack")) != nil,
                "A group DM that includes him is not his DM")
    }

    @Test func appsNamedInAnInstructionAreFound() {
        #expect(AssistantSubtask.applicationsMentioned(in: "Go to Slack, open Dana's DM and read me the last message.").first == "Slack")
        #expect(AssistantSubtask.applicationsMentioned(in: "In Slack, open #qa and tell me who posted last").first == "Slack")
        #expect(AssistantSubtask.applicationsMentioned(in: "Open Calculator, compute 12 times 7").first == "Calculator")
        #expect(AssistantSubtask.applicationsMentioned(in: "open the Notes app and type hello").first == "Notes")
        #expect(AssistantSubtask.applicationsMentioned(in: "compute 12 times 7").isEmpty)
        #expect(AssistantSubtask.applicationsMentioned(in: "Open calculator, compute 12 times 7").contains("calculator"))
        #expect(AssistantSubtask.applicationsMentioned(in: "go to slack and check if there are any new DMs from Dana").contains("slack"))
        #expect(AssistantSubtask.applicationsMentioned(in: "open system settings").first == "system settings", "Longest first")
        #expect(AssistantSubtask.applicationsMentioned(in: "Go to Slack and open messages").first == "Slack", "Capitalised names first")
        #expect(AssistantSubtask.applicationsMentioned(in: "what's 12 times 7 in calculator").contains("calculator"))
    }

    @Test func theListOfConversationsIsNotAConversation() {
        #expect(AssistantSubtask.conversationTarget(in: "Open Direct Messages in Slack") == nil)
        #expect(AssistantSubtask.conversationTarget(in: "Open the DMs") == nil)
        #expect(AssistantSubtask.conversationTarget(in: "Check the channel list") == nil)
        #expect(AssistantSubtask.conversationTarget(in: "go to Slack and check if there are any new DM’s from Dana") == "dana")
        #expect(AssistantSubtask.conversationTarget(in: "Read any new messages from Dana in this chat window.") == "dana")
    }

    @Test func arithmeticIsReadOutOfTheInstruction() {
        #expect(AssistantSubtask.arithmeticExpression(in: "Open Calculator, compute 12 times 7 and tell me the result.") == "12*7")
        #expect(AssistantSubtask.arithmeticExpression(in: "In Calculator, what is 3.5 + 4 * 2?") == "3.5+4*2")
        #expect(AssistantSubtask.arithmeticExpression(in: "Calculator: 1,200 divided by 8 minus 15") == "1200/8-15")
        #expect(AssistantSubtask.arithmeticExpression(in: "Open Calculator and multiply 6 x 9") == "6*9")
        #expect(AssistantSubtask.arithmeticExpression(in: "Open Calculator") == nil)
        #expect(AssistantSubtask.arithmeticExpression(in: "Open Slack and read the last 3 messages") == nil)
    }

    @Test func sumsAreWorkedOutAndFoundOnScreen() {
        #expect(AssistantSubtask.evaluate("12*7") == 84)
        #expect(AssistantSubtask.evaluate("3.5+4*2") == 11.5)
        #expect(AssistantSubtask.evaluate("1200/8-15") == 135)
        #expect(AssistantSubtask.evaluate("5/0") == nil)
        #expect(AssistantSubtask.evaluate("7") == nil)
        #expect(AssistantSubtask.displayed(84) == "84")
        #expect(AssistantSubtask.displayed(2.4) == "2.4")
        let screen = AgentObservation(frontmostApplication: "Calculator", frontmostBundleIdentifier: "com.apple.calculator", windowTitle: nil,
                                      displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil, elements: [],
                                      texts: [AgentObservedText(id: "t1", text: "\u{200E}1,284", centerX: 0.1, centerY: 0.1, width: 0.1,
                                                                height: 0.05, isSensitive: false)],
                                      capturedAtNanoseconds: 1)
        #expect(AssistantSubtask.shows("1284", in: screen))
        #expect(!AssistantSubtask.shows("84", in: screen))
    }

    @Test func theNewestLinesAreTheOnesRightAboveTheMessageBox() {
        func line(_ id: Int, _ text: String, x: Double, y: Double) -> AgentObservedText {
            AgentObservedText(id: "t\(id)", text: text, centerX: x, centerY: y, width: 0.2, height: 0.02, isSensitive: false)
        }
        let box = AgentObservedElement(id: "e1", role: "textArea", label: "Message #qa", centerX: 0.62, centerY: 0.93,
                                       width: 0.6, height: 0.05, isEnabled: true, isSensitive: false)
        let screen = AgentObservation(
            frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: "qa (Channel) - acme - Slack",
            displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil, elements: [box],
            texts: [line(1, "# qa", x: 0.15, y: 0.40), line(2, "Dana Okafor 4:29 PM", x: 0.45, y: 0.70),
                    line(3, "Fixed both issues, deploying.", x: 0.55, y: 0.74), line(4, "Alex Rivera 4:31 PM", x: 0.45, y: 0.82),
                    line(5, "Yes please", x: 0.42, y: 0.86), line(6, "Message #qa", x: 0.40, y: 0.93)],
            capturedAtNanoseconds: 1)
        #expect(AssistantSubtask.linesAboveMessageBox(in: screen)
                == ["Dana Okafor 4:29 PM", "Fixed both issues, deploying.", "Alex Rivera 4:31 PM", "Yes please"],
                "The sidebar's # qa and the box's own placeholder are not messages")
        let message = AssistantPlanner.answerMessage(instruction: try! AgentInstruction(id: "q", text: "who posted last in #qa?"),
                                                     completed: [], observation: screen)
        #expect(message.contains("4. Yes please"))
    }

    @Test func slacksLocalTimeBannerIsNotAMessage() {
        let lines = ["dana", "Lunch at noon works for me", "It’s 1:11 AM for dana", "Dana is typing…"]
        let screen = AgentObservation(frontmostApplication: "Slack", frontmostBundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: nil,
                                      displayWidth: 1_000, displayHeight: 1_000, pointerX: nil, pointerY: nil, elements: [],
                                      texts: lines.enumerated().map { AgentObservedText(id: "t\($0.offset)", text: $0.element, centerX: 0.5,
                                                                                     centerY: 0.2 + Double($0.offset) * 0.1, width: 0.3,
                                                                                     height: 0.03, isSensitive: false) },
                                      capturedAtNanoseconds: 1)
        #expect(AssistantSubtask.withoutChatChrome(screen).texts.map(\.text) == ["dana", "Lunch at noon works for me"])
    }

    @Test func answersAreFoundInLooseReplies() {
        #expect(AssistantPlanner.answerText(in: #"{"done":"Alex Rivera: Yes please"}"#) == "Alex Rivera: Yes please")
        #expect(AssistantPlanner.answerText(in: "```json\n{\"answer\": \"84\"}\n```") == "84")
        #expect(AssistantPlanner.answerText(in: "<think>the bottom line</think>The last message is from Alex: Yes please.")
                == "The last message is from Alex: Yes please.")
        #expect(AssistantPlanner.answerText(in: #"{"plan":[{"goal":"Read it","done_when":"read"}]}"#) == nil)
        #expect(AssistantPlanner.answerText(in: #"{"done":{"sender":"Alex Rivera","message":"Yes please"}}"#)
                == "Alex Rivera: Yes please")
        #expect(AssistantPlanner.answerText(in: #"{"done":{"sender":"Alex Rivera","time":"4:31 PM","text":"Yes please"}}"#)
                == "Alex Rivera at 4:31 PM: Yes please")
        #expect(AssistantPlanner.answerText(in: #"{"who":"Alex Rivera","what":"Yes please"}"#) == "Alex Rivera: Yes please")
        #expect(AssistantPlanner.answerText(in: #"{"done":{"sender":"Alex Rivera","time":"5:06 PM","words":"Lunch at noon"}}"#)
                == "Alex Rivera at 5:06 PM: Lunch at noon")
        #expect(AssistantPlanner.answerText(in: #"{"channel":"qa","count":3}"#) == "channel: qa, count: 3")
        #expect(AssistantPlanner.answerText(in: "{\"plan\":[{\"goal\":\"Read it\"}]}\n{\"done\":\"Alex Rivera: Yes please\"}")
                == "Alex Rivera: Yes please", "A plan and then the answer")
        #expect(AssistantPlanner.answerText(in: #"{"done":"He wrote {braces} and \"quotes\""}"#) == #"He wrote {braces} and "quotes""#)
        #expect(AssistantPlanner.answerText(in: "  ") == nil)
    }

    @Test func profilesKeepNavigationSmallAndGrowThePlanner() throws {
        let lite = try #require(AssistantProfile.lite.endpoints(appleModelAvailable: true))
        #expect(lite.planner.kind == .ollama && lite.planner.model == "qwen3.5:4b")
        #expect(lite.executor.kind == .appleOnDevice)
        #expect(lite.vision == "qwen3.5:4b")
        let standard = try #require(AssistantProfile.standard.endpoints(appleModelAvailable: false))
        #expect(standard.planner.model == "qwen3.5:9b")
        #expect(standard.executor.kind == .ollama && standard.executor.model == "qwen3.5:4b", "Without Apple's model, navigation stays on the 4B")
        #expect(standard.vision == "qwen3.5:4b")
        #expect(AssistantProfile.lite.models == ["qwen3.5:4b"])
        #expect(AssistantProfile.standard.models == ["qwen3.5:4b", "qwen3.5:9b"])
        #expect(AssistantProfile.custom.endpoints(appleModelAvailable: true) == nil)
    }

    @Test func memoryPicksTheProfile() {
        #expect(AssistantProfile.recommended(memoryGigabytes: 8) == .lite)
        #expect(AssistantProfile.recommended(memoryGigabytes: 16) == .lite)
        #expect(AssistantProfile.recommended(memoryGigabytes: 24) == .lite)
        #expect(AssistantProfile.recommended(memoryGigabytes: 32) == .standard)
        #expect(AssistantProfile.recommended(memoryGigabytes: 64) == .standard)
        #expect(AssistantProfile.lite.fits(memoryGigabytes: 16))
        #expect(!AssistantProfile.standard.fits(memoryGigabytes: 16))
        #expect(AssistantProfile.standard.fits(memoryGigabytes: 32))
    }

    @Test func existingSettingsAreRecognisedAsAProfile() throws {
        let lite = try #require(AssistantProfile.lite.endpoints(appleModelAvailable: true))
        #expect(AssistantProfile.matching(planner: lite.planner, executor: lite.executor, vision: lite.vision) == .lite)
        let standard = try #require(AssistantProfile.standard.endpoints(appleModelAvailable: false))
        #expect(AssistantProfile.matching(planner: standard.planner, executor: standard.executor, vision: standard.vision) == .standard)
        #expect(AssistantProfile.matching(planner: standard.planner, executor: standard.executor, vision: "qwen2.5vl:7b") == .custom)
        let apple = AssistantEndpointSettings(kind: .appleOnDevice, baseURL: AssistantSettings.defaultOllamaURL, model: AppleModelProvider.modelID)
        #expect(AssistantProfile.matching(planner: apple, executor: apple, vision: "qwen2.5vl:7b") == .custom)
    }

    @Test func ollamaDownloadProgressIsReadFromItsStream() throws {
        var progress = OllamaPullProgress()
        #expect(try progress.read(#"{"status":"pulling manifest"}"#) == nil)
        #expect(try progress.read(#"{"status":"pulling a1","digest":"sha256:a1","total":100,"completed":50}"#) == 0.5)
        #expect(try progress.read(#"{"status":"pulling b2","digest":"sha256:b2","total":300,"completed":0}"#) == 0.125)
        #expect(try progress.read(#"{"status":"pulling b2","digest":"sha256:b2","total":300,"completed":300}"#) == 0.875)
        #expect(!progress.succeeded)
        #expect(try progress.read(#"{"status":"success"}"#) == 1)
        #expect(progress.succeeded)
        var failing = OllamaPullProgress()
        #expect(throws: OllamaLibraryError.self) { try failing.read(#"{"error":"pull model manifest: file does not exist"}"#) }
    }

    @Test func writingIntentIsRecognised() {
        #expect(!AssistantRuntime.asksToWrite("Go to Slack, open Dana's DM and read me the last message."))
        #expect(!AssistantRuntime.asksToWrite("check if there are any new DMs from Dana"))
        #expect(AssistantRuntime.asksToWrite("Reply to Dana that I am on it"))
        #expect(AssistantRuntime.asksToWrite("send Priya the link"))
        #expect(!AssistantRuntime.asksToWrite("In Slack, open #qa and tell me who posted the last message there and what it says."))
        #expect(AssistantRuntime.asksToWrite("Post the link in #qa"))
        #expect(AssistantRuntime.asksToWrite("Reply saying I'm on my way"))
        #expect(AssistantRuntime.asksToWrite("Message him that the build is green"))
    }

    @Test func templateWordingIsRecognised() {
        #expect(AssistantPlanner.isTemplateWording("<app the goal needs>"))
        #expect(AssistantPlanner.isTemplateWording("..."))
        #expect(AssistantPlanner.isTemplateWording("One outcome in plain words"))
        #expect(!AssistantPlanner.isTemplateWording("Open Calculator and type 12*7="))
    }
}
