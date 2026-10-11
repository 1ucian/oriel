import Foundation
import Testing
@testable import HermesCaptureCore

struct AgentPolicyTests {
    @Test func secretsAreNeverTyped() {
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .type, targetIsSensitive: true, text: "hello"))
                == .block(reason: "Oriel never types into secure fields."))
        if case .block = AgentApprovalPolicy.evaluate(.init(kind: .type, text: "483921")) {} else {
            Issue.record("A six-digit code must be blocked")
        }
        if case .block = AgentApprovalPolicy.evaluate(.init(kind: .type, targetLabel: "Password", text: "hunter2")) {} else {
            Issue.record("A password field must be blocked")
        }
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .type, targetLabel: "Search", text: "quarterly report")) == .allow)
    }

    @Test func moneyAndPublicSendsNeedApproval() {
        for label in ["Pay now", "Buy", "Send", "Post", "Delete", "Empty Trash", "Place Order", "Allow", "Install",
                      "Deny", "Don't Allow", "Open System Settings"] {
            if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: label)) {} else {
                Issue.record("\(label) must need approval")
            }
        }
        for label in ["Save", "Open", "Sender", "Ascend", "Next", "OK", "Postpone"] {
            #expect(AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: label)) == .allow, "\(label) is ordinary")
        }
    }

    @Test func orielNeverOperatesItsOwnWindows() {
        for context in [AgentActionContext(kind: .click, targetLabel: "Allow Control"),
                        AgentActionContext(kind: .click, targetLabel: "Copy Code"),
                        AgentActionContext(kind: .click, targetLabel: "Stop Assistant"),
                        AgentActionContext(kind: .type, text: "http://example.com"),
                        AgentActionContext(kind: .key, keyName: "return"),
                        AgentActionContext(kind: .scroll)] {
            if case .block = AgentApprovalPolicy.evaluate(context.landingOnOriel()) {} else {
                Issue.record("\(context.kind) \(context.targetLabel ?? context.text ?? context.keyName ?? "") in Oriel must be blocked")
            }
        }
        // Leaving Oriel for another app is how the assistant gets back to work.
        #expect(AgentApprovalPolicy.evaluate(AgentActionContext(kind: .openApplication, targetLabel: "Slack").landingOnOriel()) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: "Copy Code")) == .allow, "Elsewhere it is an ordinary button")
    }

    @Test func returnInAChatAppNeedsApproval() {
        let slack = "com.tinyspeck.slackmacgap"
        for (key, modifiers) in [("return", Set<String>()), ("enter", []), ("return", ["command"]), ("return", ["shift"])] {
            if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: key, modifiers: modifiers, frontmostBundleIdentifier: slack)) {} else {
                Issue.record("\(modifiers) \(key) in Slack can send a message")
            }
        }
        if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .type, text: "on my way\n", frontmostBundleIdentifier: "com.apple.MobileSMS")) {} else {
            Issue.record("A typed line break in Messages can send")
        }
        // Moving around a chat app and drafting text stay free; so does Return elsewhere.
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "k", modifiers: ["command"], frontmostBundleIdentifier: slack)) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .type, text: "on my way", frontmostBundleIdentifier: slack)) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: "dana", frontmostBundleIdentifier: slack)) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "return", frontmostBundleIdentifier: "com.apple.TextEdit")) == .allow)

        // Return in Slack's search or jump box opens a result; in the message box it sends.
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "return", frontmostBundleIdentifier: slack,
                                                   focusedField: "AXTextField: Search")) == .allow)
        if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "return", frontmostBundleIdentifier: slack,
                                                                      focusedField: "AXTextArea: Message to general")) {} else {
            Issue.record("Return in the message box can send")
        }
        #expect(!AgentApprovalPolicy.isSearchField("AXTextArea: Message to search-team"))
        #expect(AgentApprovalPolicy.isSearchField("AXComboBox: Query"), "Slack's jump box")
        #expect(!AgentApprovalPolicy.isSearchField("AXTextArea: Message to general"))
    }

    @Test func protectedSurfacesAreBlocked() {
        if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: "Continue", frontmostBundleIdentifier: "com.apple.SecurityAgent")) {} else {
            Issue.record("Security dialogs are never operated")
        }
        if case .block = AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: "I'm not a robot")) {} else {
            Issue.record("CAPTCHA is never operated")
        }
        if case .block = AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: "Sign Note")) {} else {
            Issue.record("Medical-record signing is never operated")
        }
        if case .block = AgentApprovalPolicy.evaluate(.init(kind: .click, targetLabel: "Password", targetIsSensitive: true)) {} else {
            Issue.record("Secure fields are never clicked")
        }
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .done, frontmostBundleIdentifier: "com.apple.SecurityAgent")) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .ask, frontmostBundleIdentifier: "com.apple.loginwindow")) == .allow)
    }

    @Test func destructiveShortcutsNeedApproval() {
        if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "q", modifiers: ["command"])) {} else {
            Issue.record("Command-Q needs approval")
        }
        if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "delete", modifiers: ["command"])) {} else {
            Issue.record("Command-Delete needs approval")
        }
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "s", modifiers: ["command"])) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "return", modifiers: [])) == .allow)
        if case .requireApproval = AgentApprovalPolicy.evaluate(.init(kind: .key, keyName: "return", windowTitle: "Checkout")) {} else {
            Issue.record("Return inside a checkout window needs approval")
        }
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .scroll)) == .allow)
        #expect(AgentApprovalPolicy.evaluate(.init(kind: .openApplication, targetLabel: "Mail")) == .allow)
    }

    @Test func screenshotsStayHomeUnlessTheUserSaysOtherwise() {
        #expect(ScreenshotSharingPolicy.locality(ofHost: "127.0.0.1") == .onThisMac)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "localhost") == .onThisMac)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "::1") == .onThisMac)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "192.168.1.20") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "10.0.0.7") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "172.20.3.4") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "100.100.10.20") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "gpu-box.tail0000.ts.net") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "studio.local") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "api.openai.com") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "8.8.8.8") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "172.32.0.1") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "127.1.2.3") == .onThisMac)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "0.0.0.0") == .onThisMac)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "fd12:3456::1") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "[fe80::1]") == .localNetwork)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "2001:4860::8888") == .internet)
        // Names that only look like addresses are internet names.
        #expect(ScreenshotSharingPolicy.locality(ofHost: "127.example.com") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "fd.example.com") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "fcbarcelona.com") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "134744072") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "0x08080808") == .internet)
        #expect(ScreenshotSharingPolicy.locality(ofHost: "gpu-box") == .localNetwork)
        #expect(ScreenshotSharingPolicy.mayShareScreenshots(locality: .onThisMac, remoteSharingEnabled: false, instructionAllows: false))
        #expect(ScreenshotSharingPolicy.mayShareScreenshots(locality: .localNetwork, remoteSharingEnabled: false, instructionAllows: false))
        #expect(!ScreenshotSharingPolicy.mayShareScreenshots(locality: .internet, remoteSharingEnabled: false, instructionAllows: true))
        #expect(!ScreenshotSharingPolicy.mayShareScreenshots(locality: .internet, remoteSharingEnabled: true, instructionAllows: false))
        #expect(ScreenshotSharingPolicy.mayShareScreenshots(locality: .internet, remoteSharingEnabled: true, instructionAllows: true))
    }

    // MARK: Observation

    private func candidate(
        _ id: String, label: String, role: TargetRole, source: TargetSource,
        x: Double, y: Double, width: Double = 0.1, height: Double = 0.04,
        enabled: Bool = true, sensitive: Bool = false
    ) throws -> TargetCandidate {
        try TargetCandidate.validated(
            stableIdentifier: id, bounds: .init(x: x, y: y, width: width, height: height), label: label, role: role,
            source: source, frameSequence: 1, monotonicTimestampNanoseconds: 10, confidence: 0.9,
            isEnabled: enabled, isSensitive: sensitive
        )
    }

    @Test func observationNumbersControlsHidesSecretsAndDropsDuplicateText() throws {
        let candidates = [
            try candidate("b-save", label: "Save", role: .button, source: .accessibility, x: 0.4, y: 0.8),
            try candidate("b-cancel", label: "Cancel", role: .button, source: .accessibility, x: 0.2, y: 0.8),
            try candidate("f-pass", label: "Password", role: .unknown, source: .accessibility, x: 0.2, y: 0.5, sensitive: true),
            try candidate("t-title", label: "Untitled", role: .text, source: .accessibility, x: 0.1, y: 0.1),
            try candidate("ocr-save", label: "Save", role: .text, source: .visionOCR, x: 0.41, y: 0.805, width: 0.08, height: 0.03),
            try candidate("ocr-code", label: "Your code is 123456", role: .text, source: .visionOCR, x: 0.3, y: 0.3, sensitive: true),
            try candidate("ocr-body", label: "Quarterly numbers look good", role: .text, source: .visionOCR, x: 0.1, y: 0.4),
        ]
        let observation = AgentObservation.make(
            candidates: candidates, frontmostApplication: "Notes", frontmostBundleIdentifier: "com.apple.Notes",
            windowTitle: "Untitled", displayWidth: 1_920, displayHeight: 1_080, pointerX: 0.5, pointerY: 0.5,
            capturedAtNanoseconds: 10
        )
        #expect(observation.elements.map(\.id) == ["e1", "e2", "e3"])
        #expect(observation.elements[0].label == "secure field" && observation.elements[0].isSensitive, "Reading order puts the field first and hides its label")
        #expect(observation.elements[1].label == "Cancel" && observation.elements[2].label == "Save")
        #expect(abs(observation.elements[2].centerX - 0.45) < 0.001 && abs(observation.elements[2].centerY - 0.82) < 0.001)
        #expect(!observation.texts.contains { $0.text == "Save" }, "OCR of a labelled control is a duplicate")
        #expect(observation.texts.contains { $0.text == "[redacted]" }, "Sensitive OCR text is redacted")
        #expect(observation.texts.contains { $0.text == "Untitled" } && observation.texts.contains { $0.text == "Quarterly numbers look good" })

        let rendered = AgentObservationRenderer.render(observation)
        #expect(rendered.contains("Frontmost app: Notes | Window: Untitled"))
        #expect(rendered.contains("[e3] button \"Save\" center (0.450, 0.820)"))
        #expect(rendered.contains("SENSITIVE, not available"))
        #expect(!rendered.contains("123456"))
        #expect(!rendered.contains("Password"))
    }

    @Test func theBottomOfALongScreenSurvivesBothLimits() throws {
        // A chat: 500 lines, the newest at the bottom.
        var candidates: [TargetCandidate] = []
        for index in 0..<500 {
            candidates.append(try candidate("m\(index)", label: "Message number \(index)", role: .text,
                                            source: .accessibility, x: 0.5, y: Double(index) / 530))
        }
        let observation = AgentObservation.make(
            candidates: candidates, frontmostApplication: "Slack", frontmostBundleIdentifier: nil, windowTitle: nil,
            displayWidth: 100, displayHeight: 100, pointerX: nil, pointerY: nil, capturedAtNanoseconds: 1
        )
        #expect(observation.texts.count == AgentObservation.defaultTextLimit)
        #expect(observation.texts.first?.text == "Message number 0")
        #expect(observation.texts.last?.text == "Message number 499", "The newest line is kept")
        let rendered = AgentObservationRenderer.render(observation, maximumBytes: 2_000, pinning: ["number 300"])
        #expect(rendered.contains("Message number 499"))
        #expect(rendered.contains("Message number 300"), "A line the goal names is listed even from the middle")
        #expect(rendered.contains("more text lines not listed (middle of the screen)"))
        #expect(rendered.utf8.count <= 2_200)
    }

    @Test func rendererKeepsToItsBudget() throws {
        var candidates: [TargetCandidate] = []
        for index in 0..<100 {
            candidates.append(try candidate("b\(index)", label: "Button number \(index) with a long label", role: .button,
                                            source: .accessibility, x: Double(index % 10) / 10, y: Double(index / 10) / 10))
        }
        let observation = AgentObservation.make(
            candidates: candidates, frontmostApplication: nil, frontmostBundleIdentifier: nil, windowTitle: nil,
            displayWidth: 100, displayHeight: 100, pointerX: nil, pointerY: nil, capturedAtNanoseconds: 1
        )
        let rendered = AgentObservationRenderer.render(observation, maximumBytes: 2_000)
        #expect(rendered.utf8.count <= 2_200)
        #expect(rendered.contains("more controls not listed"))
        #expect(rendered.contains("Controls: ") == false || rendered.contains("none readable") == false)
    }
}
