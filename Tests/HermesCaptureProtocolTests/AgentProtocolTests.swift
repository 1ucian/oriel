import Foundation
import Testing
@testable import HermesCaptureProtocol

struct AgentProtocolTests {
    // MARK: Instruction

    @Test func instructionIsTrimmedAndBounded() throws {
        let instruction = try AgentInstruction(id: "i1", text: "  open Safari  ")
        #expect(instruction.text == "open Safari")
        #expect(instruction.maximumSteps == AgentInstruction.defaultStepLimit)
        #expect(instruction.allowScreenshots == false)
        #expect(throws: AgentProtocolError.emptyInstruction) { try AgentInstruction(id: "i", text: " \n") }
        #expect(throws: AgentProtocolError.instructionTooLarge) {
            try AgentInstruction(id: "i", text: String(repeating: "x", count: AgentInstruction.maximumTextBytes + 1))
        }
        #expect(throws: AgentProtocolError.invalidStepLimit) { try AgentInstruction(id: "i", text: "go", maximumSteps: 0) }
        #expect(throws: AgentProtocolError.invalidStepLimit) { try AgentInstruction(id: "i", text: "go", maximumSteps: 61) }
        #expect(throws: AgentProtocolError.emptyIdentifier) { try AgentInstruction(id: " ", text: "go") }
    }

    @Test func instructionDecodesWithDefaults() throws {
        let data = Data(#"{"id":"abc","text":"Open Notes"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentInstruction.self, from: data)
        #expect(decoded.id == "abc" && decoded.text == "Open Notes" && decoded.maximumSteps == 25)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(AgentInstruction.self, from: encoded) == decoded)
    }

    // MARK: Control

    @Test func controlRoundTrips() throws {
        let controls: [AgentControl] = [
            .pause, .resume, .stop, .approve(stepID: "s1"), .deny(stepID: "s2"), .answer(stepID: "s3", text: "the blue one"),
        ]
        for control in controls {
            let data = try JSONEncoder().encode(control)
            #expect(try JSONDecoder().decode(AgentControl.self, from: data) == control)
        }
        #expect(throws: AgentProtocolError.self) {
            try JSONDecoder().decode(AgentControl.self, from: Data(#"{"kind":"approve","stepID":""}"#.utf8))
        }
        #expect(throws: AgentProtocolError.self) {
            try JSONDecoder().decode(AgentControl.self, from: Data(#"{"kind":"launch"}"#.utf8))
        }
    }

    // MARK: Actions

    @Test func actionsValidate() throws {
        let point = AgentTargetReference.point(try NormalizedPoint(x: 0.5, y: 0.5))
        #expect(throws: AgentProtocolError.invalidClickCount) { try AgentAction.click(point, button: .left, count: 3).validate() }
        #expect(throws: AgentProtocolError.invalidWait) { try AgentAction.wait(milliseconds: 10).validate() }
        #expect(throws: AgentProtocolError.unknownKey) { try AgentAction.key(name: "hyper", modifiers: []).validate() }
        #expect(throws: AgentProtocolError.invalidScroll) { try AgentAction.scroll(deltaX: 0, deltaY: 0, at: nil).validate() }
        #expect(throws: AgentProtocolError.emptySummary) { try AgentAction.done(summary: "  ").validate() }
        #expect(throws: AgentProtocolError.invalidText) { try AgentAction.type(text: "a\u{0}b").validate() }
        #expect(throws: AgentProtocolError.invalidApplicationName) { try AgentAction.openApplication(name: "").validate() }
        try AgentAction.click(.element(id: "e4"), button: .right, count: 1).validate()
        try AgentAction.key(name: "Return", modifiers: [.command]).validate()
        #expect(AgentKeyName.keyCode(for: "RETURN") == 36)
        #expect(AgentKeyName.keyCode(for: "F5") == 96)
        #expect(AgentAction.done(summary: "ok").isTerminal && AgentAction.ask(question: "which?").isTerminal)
        #expect(!AgentAction.wait(milliseconds: 500).isTerminal)
    }

    @Test func actionsRoundTrip() throws {
        let actions: [AgentAction] = [
            .click(.element(id: "e1"), button: .left, count: 2),
            .click(.point(try NormalizedPoint(x: 0.25, y: 0.75)), button: .right, count: 1),
            .type(text: "hello world"),
            .key(name: "s", modifiers: [.command, .shift]),
            .scroll(deltaX: 0, deltaY: -300, at: .element(id: "e9")),
            .scroll(deltaX: 10, deltaY: 0, at: nil),
            .openApplication(name: "Notes"),
            .wait(milliseconds: 750),
            .look(reason: "The toolbar has icons without labels"),
            .escalate(reason: "The export dialog never appeared"),
            .done(summary: "Exported the PDF."),
            .ask(question: "Which account?"),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(AgentAction.self, from: data) == action)
        }
        // Decoding validates too.
        #expect(throws: AgentProtocolError.self) {
            try JSONDecoder().decode(AgentAction.self, from: Data(#"{"type":"wait","milliseconds":5}"#.utf8))
        }
    }

    // MARK: Parser

    @Test func parserReadsFencedJSONWithReason() throws {
        let text = """
        Sure. Here is the next step:
        ```json
        {"reason": "The Save button is visible", "action": {"type": "click", "target": {"element": "e12"}}}
        ```
        """
        let step = try AgentModelResponseParser.parse(text)
        #expect(step.reason == "The Save button is visible")
        #expect(step.action == .click(.element(id: "e12"), button: .left, count: 1))
    }

    @Test func parserAcceptsCommonAliases() throws {
        #expect(try AgentModelResponseParser.parse(#"{"type":"double_click","element":"e3"}"#).action
                == .click(.element(id: "e3"), button: .left, count: 2))
        #expect(try AgentModelResponseParser.parse(#"{"type":"right_click","x":0.4,"y":0.6}"#).action
                == .click(.point(try NormalizedPoint(x: 0.4, y: 0.6)), button: .right, count: 1))
        #expect(try AgentModelResponseParser.parse(#"{"action":{"type":"press","key":"cmd+shift+s"}}"#).action
                == .key(name: "s", modifiers: [.command, .shift]))
        #expect(try AgentModelResponseParser.parse(#"{"type":"hotkey","keys":["ctrl","c"]}"#).action
                == .key(name: "c", modifiers: [.control]))
        #expect(try AgentModelResponseParser.parse(#"{"type":"scroll","direction":"down"}"#).action
                == .scroll(deltaX: 0, deltaY: -300, at: nil))
        #expect(try AgentModelResponseParser.parse(#"{"type":"finish","summary":"All set"}"#).action == .done(summary: "All set"))
        #expect(try AgentModelResponseParser.parse(#"{"type":"open_app","app":"Calculator"}"#).action == .openApplication(name: "Calculator"))
        #expect(try AgentModelResponseParser.parse(#"{"type":"wait","seconds":1.5}"#).action == .wait(milliseconds: 1_500))
        #expect(try AgentModelResponseParser.parse(#"{"type":"type_text","text":"4+4="}"#).action == .type(text: "4+4="))
        #expect(try AgentModelResponseParser.parse(#"{"type":"ask_user","question":"Which file?"}"#).action == .ask(question: "Which file?"))
        #expect(try AgentModelResponseParser.parse(#"{"type":"screenshot","reason":"icons only"}"#).action == .look(reason: "icons only"))
        #expect(try AgentModelResponseParser.parse(#"{"type":"stuck","reason":"no export menu"}"#).action == .escalate(reason: "no export menu"))
        #expect(try AgentModelResponseParser.parse(#"{"type":"click","target":"[t2]"}"#).action == .click(.element(id: "t2"), button: .left, count: 1))
        #expect(try AgentModelResponseParser.parse(#"{"type":"click","element":" #e7 "}"#).action == .click(.element(id: "e7"), button: .left, count: 1))
        #expect(!AgentAction.escalate(reason: "x").movesTheMac && AgentAction.type(text: "a").movesTheMac)
    }

    @Test func unknownTraceKindsReadAsObservations() throws {
        let data = Data(#"{"id":"t","instructionID":"i","stepIndex":1,"kind":"somethingNew","summary":"later version","monotonicNanoseconds":1}"#.utf8)
        let event = try JSONDecoder().decode(AgentTraceEvent.self, from: data)
        #expect(event.kind == .observed)
    }

    @Test func parserRefusesWhatTheAllowlistLacks() {
        #expect(throws: AgentProtocolError.malformedResponse) { try AgentModelResponseParser.parse("I will click save now.") }
        #expect(throws: AgentProtocolError.unknownActionType("run_shell")) { try AgentModelResponseParser.parse(#"{"type":"run_shell","command":"rm -rf /"}"#) }
        #expect(throws: AgentProtocolError.missingTarget) { try AgentModelResponseParser.parse(#"{"type":"click"}"#) }
        // Pixel coordinates are not normalized coordinates.
        #expect(throws: InputProtocolError.invalidCoordinate) { try AgentModelResponseParser.parse(#"{"type":"click","x":640,"y":400}"#) }
        #expect(throws: AgentProtocolError.unknownKey) { try AgentModelResponseParser.parse(#"{"type":"press","key":"cmd"}"#) }
    }

    @Test func parserTakesTheFirstBalancedObjectInsideProse() throws {
        let text = #"Thinking... {"reason":"x","action":{"type":"wait","milliseconds":200}} and then more words {"type":"done","summary":"no"}"#
        #expect(try AgentModelResponseParser.parse(text).action == .wait(milliseconds: 200))
    }

    // MARK: Trace and status

    @Test func traceEventRoundTripsAndBoundsItsSummary() throws {
        let event = try AgentTraceEvent(
            id: "ev1", instructionID: "i1", stepIndex: 3, kind: .needsApproval,
            summary: "Clicking \"Send\" needs your approval.",
            action: .click(.element(id: "e2"), button: .left, count: 1), stepID: "s3", monotonicNanoseconds: 99
        )
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(AgentTraceEvent.self, from: data) == event)
        #expect(throws: AgentProtocolError.summaryTooLarge) {
            try AgentTraceEvent(instructionID: "i", stepIndex: 0, kind: .observed,
                                summary: String(repeating: "s", count: AgentAction.maximumSummaryBytes + 1), monotonicNanoseconds: 1)
        }
    }

    @Test func providerSummaryClipsItsName() {
        let summary = AgentProviderSummary(displayName: String(repeating: "n", count: 300), locality: .internet,
                                           screenshotsShared: false, isConfigured: true, isRunning: false)
        #expect(summary.displayName.count == 120)
        #expect(!AgentProviderSummary.unconfigured.isConfigured)
    }

    // MARK: Packets and capabilities

    @Test func assistantPacketsRoundTripThroughTheCodec() throws {
        let packets: [SessionPacket] = [
            .agentInstruction(try AgentInstruction(id: "i1", text: "Open Notes and type hello")),
            .agentControl(.approve(stepID: "s1")),
            .agentTrace(try AgentTraceEvent(instructionID: "i1", stepIndex: 1, kind: .executed, summary: "Clicked Notes", monotonicNanoseconds: 5)),
            .agentStatus(AgentProviderSummary(displayName: "qwen3:4b (Ollama)", locality: .onThisMac, screenshotsShared: true, isConfigured: true, isRunning: true)),
        ]
        for packet in packets {
            let data = try SessionPacketCodec.encode(packet)
            #expect(try SessionPacketCodec.decode(data) == packet)
        }
    }

    @Test func approvalsMayCarryTheAssistantButNeverSecrets() throws {
        let allowed = SessionPacket.approval(.init(capabilities: SessionCapability.assistantDefaults, expiresAt: .now))
        _ = try SessionPacketCodec.encode(allowed)
        let denied = SessionPacket.approval(.init(capabilities: [.viewScreen, .enterSecrets], expiresAt: .now))
        #expect(throws: PeerSessionError.capabilityDenied) { try SessionPacketCodec.encode(denied) }
        #expect(SessionCapability.approvable.contains(.runAgentActions))
        #expect(!SessionCapability.approvable.contains(.enterSecrets))
        #expect(!SessionCapability.approvable.contains(.approveSensitiveAction))
    }
}
