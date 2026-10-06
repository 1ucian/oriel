import Foundation

/// The assistant over the session channel: the phone sends an instruction and control, the
/// Mac answers with its provider summary and a trace of every step. Actions are an allowlist;
/// anything a model says outside it is refused before it reaches the input broker.
public enum AgentProtocolError: Error, Equatable, Sendable {
    case emptyIdentifier
    case emptyInstruction
    case instructionTooLarge
    case invalidStepLimit
    case textTooLarge
    case invalidText
    case invalidClickCount
    case invalidWait
    case invalidScroll
    case unknownKey
    case invalidApplicationName
    case emptySummary
    case summaryTooLarge
    case unsupportedAction
    /// The model named an action that is not in the allowlist; the name is kept for the trace.
    case unknownActionType(String)
    /// A click or scroll named no element id and no normalized point.
    case missingTarget
    case malformedResponse
}

public struct AgentInstruction: Codable, Equatable, Sendable {
    public static let maximumTextBytes = 4_096
    public static let stepLimits = 1...60
    public static let defaultStepLimit = 25

    public let id: String
    public let text: String
    public let maximumSteps: Int
    /// The phone's wish for this run; the Mac applies its own screenshot policy on top.
    public let allowScreenshots: Bool

    public init(
        id: String = UUID().uuidString,
        text: String,
        maximumSteps: Int = Self.defaultStepLimit,
        allowScreenshots: Bool = false
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AgentProtocolError.emptyIdentifier
        }
        guard !trimmed.isEmpty else { throw AgentProtocolError.emptyInstruction }
        guard trimmed.utf8.count <= Self.maximumTextBytes else {
            throw AgentProtocolError.instructionTooLarge
        }
        guard !trimmed.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentProtocolError.invalidText
        }
        guard Self.stepLimits.contains(maximumSteps) else {
            throw AgentProtocolError.invalidStepLimit
        }
        self.id = id
        self.text = trimmed
        self.maximumSteps = maximumSteps
        self.allowScreenshots = allowScreenshots
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            text: container.decode(String.self, forKey: .text),
            maximumSteps: container.decodeIfPresent(Int.self, forKey: .maximumSteps)
                ?? Self.defaultStepLimit,
            allowScreenshots: container.decodeIfPresent(Bool.self, forKey: .allowScreenshots)
                ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case maximumSteps
        case allowScreenshots
    }
}

public enum AgentControl: Equatable, Sendable {
    case pause
    case resume
    case stop
    case approve(stepID: String)
    case deny(stepID: String)
    case answer(stepID: String, text: String)
}

extension AgentControl: Codable {
    private enum Kind: String, Codable {
        case pause
        case resume
        case stop
        case approve
        case deny
        case answer
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case stepID
        case text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try? container.decode(Kind.self, forKey: .kind) else {
            throw AgentProtocolError.unsupportedAction
        }
        switch kind {
        case .pause: self = .pause
        case .resume: self = .resume
        case .stop: self = .stop
        case .approve:
            self = .approve(stepID: try Self.identifier(container, .stepID))
        case .deny:
            self = .deny(stepID: try Self.identifier(container, .stepID))
        case .answer:
            let text = try container.decode(String.self, forKey: .text)
            guard text.utf8.count <= AgentInstruction.maximumTextBytes else {
                throw AgentProtocolError.textTooLarge
            }
            self = .answer(stepID: try Self.identifier(container, .stepID), text: text)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pause: try container.encode(Kind.pause, forKey: .kind)
        case .resume: try container.encode(Kind.resume, forKey: .kind)
        case .stop: try container.encode(Kind.stop, forKey: .kind)
        case let .approve(stepID):
            try container.encode(Kind.approve, forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
        case let .deny(stepID):
            try container.encode(Kind.deny, forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
        case let .answer(stepID, text):
            try container.encode(Kind.answer, forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
            try container.encode(text, forKey: .text)
        }
    }

    private static func identifier(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty, value.utf8.count <= 128 else {
            throw AgentProtocolError.emptyIdentifier
        }
        return value
    }
}

/// Where an action lands: a control the observation listed, or a normalized screen point.
public enum AgentTargetReference: Equatable, Sendable {
    case element(id: String)
    case point(NormalizedPoint)
}

extension AgentTargetReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case element
        case x
        case y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let element = try container.decodeIfPresent(String.self, forKey: .element) {
            guard !element.trimmingCharacters(in: .whitespaces).isEmpty, element.utf8.count <= 64 else {
                throw AgentProtocolError.emptyIdentifier
            }
            self = .element(id: element)
            return
        }
        self = .point(
            try NormalizedPoint(
                x: container.decode(Double.self, forKey: .x),
                y: container.decode(Double.self, forKey: .y)
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .element(id):
            try container.encode(id, forKey: .element)
        case let .point(point):
            try container.encode(point.x, forKey: .x)
            try container.encode(point.y, forKey: .y)
        }
    }
}

/// Key names a model may use, each bound to one macOS virtual key code.
public enum AgentKeyName {
    private static let codes: [String: UInt16] = {
        var table: [String: UInt16] = [
            "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "forwarddelete": 117, "escape": 53, "esc": 53, "left": 123, "right": 124,
            "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, ".": 47,
            "/": 44, "`": 50,
        ]
        let letters: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        let digits: [(String, UInt16)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25),
            ("7", 26), ("8", 28), ("0", 29),
        ]
        for (name, code) in letters + digits { table[name] = code }
        return table
    }()

    public static func keyCode(for name: String) -> UInt16? {
        codes[name.lowercased().replacingOccurrences(of: " ", with: "")]
    }

    public static var names: [String] { codes.keys.sorted() }
}

/// The allowlist. A model's answer is parsed into one of these or refused.
public enum AgentAction: Equatable, Sendable {
    public static let maximumSummaryBytes = 2_048
    public static let waitRange = 50...10_000

    case click(AgentTargetReference, button: MouseButton, count: Int)
    case type(text: String)
    case key(name: String, modifiers: Set<KeyModifier>)
    case scroll(deltaX: Double, deltaY: Double, at: AgentTargetReference?)
    case openApplication(name: String)
    case wait(milliseconds: Int)
    /// No input: the next step is decided with the vision model on a screenshot (where the
    /// sharing policy allows one).
    case look(reason: String)
    /// No input: the executor hands the current sub-task back to the planner.
    case escalate(reason: String)
    case done(summary: String)
    case ask(question: String)

    public var kind: String {
        switch self {
        case .click: "click"
        case .type: "type"
        case .key: "key"
        case .scroll: "scroll"
        case .openApplication: "openApplication"
        case .wait: "wait"
        case .look: "look"
        case .escalate: "escalate"
        case .done: "done"
        case .ask: "ask"
        }
    }

    /// The run ends after this action.
    public var isTerminal: Bool {
        switch self {
        case .done, .ask: true
        default: false
        }
    }

    /// Touches the Mac's input.
    public var movesTheMac: Bool {
        switch self {
        case .click, .type, .key, .scroll, .openApplication: true
        case .wait, .look, .escalate, .done, .ask: false
        }
    }

    public func validate() throws {
        switch self {
        case let .click(_, _, count):
            guard (1...2).contains(count) else { throw AgentProtocolError.invalidClickCount }
        case let .type(text):
            guard !text.isEmpty, text.utf8.count <= AgentInstruction.maximumTextBytes else {
                throw AgentProtocolError.textTooLarge
            }
            guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw AgentProtocolError.invalidText
            }
        case let .key(name, _):
            guard AgentKeyName.keyCode(for: name) != nil else { throw AgentProtocolError.unknownKey }
        case let .scroll(deltaX, deltaY, _):
            guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 1_000, abs(deltaY) <= 1_000,
                  deltaX != 0 || deltaY != 0 else {
                throw AgentProtocolError.invalidScroll
            }
        case let .openApplication(name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else {
                throw AgentProtocolError.invalidApplicationName
            }
        case let .wait(milliseconds):
            guard Self.waitRange.contains(milliseconds) else { throw AgentProtocolError.invalidWait }
        case let .look(reason), let .escalate(reason):
            guard reason.utf8.count <= Self.maximumSummaryBytes else { throw AgentProtocolError.summaryTooLarge }
        case let .done(summary), let .ask(summary):
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AgentProtocolError.emptySummary }
            guard trimmed.utf8.count <= Self.maximumSummaryBytes else {
                throw AgentProtocolError.summaryTooLarge
            }
        }
    }
}

extension AgentAction: Codable {
    private enum Kind: String, Codable {
        case click
        case type
        case key
        case scroll
        case openApplication
        case wait
        case look
        case escalate
        case done
        case ask
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case target
        case button
        case count
        case text
        case key
        case modifiers
        case deltaX
        case deltaY
        case name
        case milliseconds
        case reason
        case summary
        case question
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try? container.decode(Kind.self, forKey: .type) else {
            throw AgentProtocolError.unsupportedAction
        }
        switch kind {
        case .click:
            self = .click(
                try container.decode(AgentTargetReference.self, forKey: .target),
                button: try container.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left,
                count: try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            )
        case .type:
            self = .type(text: try container.decode(String.self, forKey: .text))
        case .key:
            self = .key(
                name: try container.decode(String.self, forKey: .key),
                modifiers: Set(try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? [])
            )
        case .scroll:
            self = .scroll(
                deltaX: try container.decodeIfPresent(Double.self, forKey: .deltaX) ?? 0,
                deltaY: try container.decodeIfPresent(Double.self, forKey: .deltaY) ?? 0,
                at: try container.decodeIfPresent(AgentTargetReference.self, forKey: .target)
            )
        case .openApplication:
            self = .openApplication(name: try container.decode(String.self, forKey: .name))
        case .wait:
            self = .wait(milliseconds: try container.decode(Int.self, forKey: .milliseconds))
        case .look:
            self = .look(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case .escalate:
            self = .escalate(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case .done:
            self = .done(summary: try container.decode(String.self, forKey: .summary))
        case .ask:
            self = .ask(question: try container.decode(String.self, forKey: .question))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .click(target, button, count):
            try container.encode(Kind.click, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(button, forKey: .button)
            try container.encode(count, forKey: .count)
        case let .type(text):
            try container.encode(Kind.type, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .key(name, modifiers):
            try container.encode(Kind.key, forKey: .type)
            try container.encode(name, forKey: .key)
            try container.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
        case let .scroll(deltaX, deltaY, at):
            try container.encode(Kind.scroll, forKey: .type)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
            try container.encodeIfPresent(at, forKey: .target)
        case let .openApplication(name):
            try container.encode(Kind.openApplication, forKey: .type)
            try container.encode(name, forKey: .name)
        case let .wait(milliseconds):
            try container.encode(Kind.wait, forKey: .type)
            try container.encode(milliseconds, forKey: .milliseconds)
        case let .look(reason):
            try container.encode(Kind.look, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .escalate(reason):
            try container.encode(Kind.escalate, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .done(summary):
            try container.encode(Kind.done, forKey: .type)
            try container.encode(summary, forKey: .summary)
        case let .ask(question):
            try container.encode(Kind.ask, forKey: .type)
            try container.encode(question, forKey: .question)
        }
    }
}

/// One planned step: the model's reason and the action Oriel will take.
public struct AgentPlannedStep: Codable, Equatable, Sendable {
    public let reason: String
    public let action: AgentAction

    public init(reason: String, action: AgentAction) throws {
        try action.validate()
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= AgentAction.maximumSummaryBytes else {
            throw AgentProtocolError.summaryTooLarge
        }
        self.reason = trimmed
        self.action = action
    }
}

public enum AgentTraceKind: String, Codable, CaseIterable, Sendable {
    case started
    /// The planner's list of sub-tasks.
    case plan
    /// A sub-task begins (the executor's current goal).
    case subtask
    /// The executor's report back to the planner.
    case report
    case observed
    case planned
    case executed
    case blocked
    case needsApproval
    case denied
    case asked
    case answered
    case paused
    case resumed
    case finished
    case failed
    case stopped

    /// A newer Mac may send kinds an older phone doesn't know; they read as observations
    /// rather than closing the session.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTraceKind(rawValue: raw) ?? .observed
    }
}

/// What the Mac tells the phone about one moment of a run.
public struct AgentTraceEvent: Codable, Equatable, Sendable {
    public let id: String
    public let instructionID: String
    public let stepIndex: Int
    public let kind: AgentTraceKind
    public let summary: String
    public let action: AgentAction?
    /// The step a `needsApproval` or `asked` event waits on; `approve`, `deny` and `answer` name it.
    public let stepID: String?
    public let monotonicNanoseconds: UInt64

    public init(
        id: String = UUID().uuidString,
        instructionID: String,
        stepIndex: Int,
        kind: AgentTraceKind,
        summary: String,
        action: AgentAction? = nil,
        stepID: String? = nil,
        monotonicNanoseconds: UInt64
    ) throws {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= AgentAction.maximumSummaryBytes else {
            throw AgentProtocolError.summaryTooLarge
        }
        guard !id.isEmpty, !instructionID.isEmpty, stepIndex >= 0 else {
            throw AgentProtocolError.emptyIdentifier
        }
        self.id = id
        self.instructionID = instructionID
        self.stepIndex = stepIndex
        self.kind = kind
        self.summary = trimmed
        self.action = action
        self.stepID = stepID
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            instructionID: container.decode(String.self, forKey: .instructionID),
            stepIndex: container.decode(Int.self, forKey: .stepIndex),
            kind: container.decode(AgentTraceKind.self, forKey: .kind),
            summary: container.decode(String.self, forKey: .summary),
            action: container.decodeIfPresent(AgentAction.self, forKey: .action),
            stepID: container.decodeIfPresent(String.self, forKey: .stepID),
            monotonicNanoseconds: container.decode(UInt64.self, forKey: .monotonicNanoseconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case instructionID
        case stepIndex
        case kind
        case summary
        case action
        case stepID
        case monotonicNanoseconds
    }
}

/// What the phone shows about the Mac's model before and during a run.
public struct AgentProviderSummary: Codable, Equatable, Sendable {
    public enum Locality: String, Codable, Sendable {
        case onThisMac
        case localNetwork
        case internet
    }

    public let displayName: String
    public let locality: Locality
    /// The model receives screenshots this session; otherwise text only.
    public let screenshotsShared: Bool
    public let isConfigured: Bool
    public let isRunning: Bool

    public init(
        displayName: String,
        locality: Locality,
        screenshotsShared: Bool,
        isConfigured: Bool,
        isRunning: Bool
    ) {
        self.displayName = String(displayName.prefix(120))
        self.locality = locality
        self.screenshotsShared = screenshotsShared
        self.isConfigured = isConfigured
        self.isRunning = isRunning
    }

    public static let unconfigured = AgentProviderSummary(
        displayName: "No model configured",
        locality: .onThisMac,
        screenshotsShared: false,
        isConfigured: false,
        isRunning: false
    )
}

/// Turns a model's answer into one planned step. Accepts a bare JSON object, a fenced one,
/// or JSON inside prose, and the aliases models reach for (`double_click`, `press`, `finish`).
public enum AgentModelResponseParser {
    public static func parse(_ text: String) throws -> AgentPlannedStep {
        guard let object = firstJSONObject(in: text) else {
            throw AgentProtocolError.malformedResponse
        }
        let reason = (object["reason"] as? String)
            ?? (object["thought"] as? String)
            ?? (object["rationale"] as? String)
            ?? ""
        let actionObject = (object["action"] as? [String: Any]) ?? object
        let action = try action(from: actionObject)
        return try AgentPlannedStep(reason: reason, action: action)
    }

    private static func action(from object: [String: Any]) throws -> AgentAction {
        guard let rawType = (object["type"] as? String) ?? (object["name"] as? String)
                ?? (object["action"] as? String) else {
            throw AgentProtocolError.unsupportedAction
        }
        let type = rawType.lowercased().replacingOccurrences(of: " ", with: "_")
        let arguments = (object["arguments"] as? [String: Any])
            ?? (object["parameters"] as? [String: Any])
            ?? (object["args"] as? [String: Any])
            ?? object
        switch type {
        case "click", "left_click", "tap", "single_click":
            return .click(try target(from: arguments), button: .left, count: 1)
        case "double_click", "doubleclick", "double_tap":
            return .click(try target(from: arguments), button: .left, count: 2)
        case "right_click", "rightclick", "context_click", "secondary_click":
            return .click(try target(from: arguments), button: .right, count: 1)
        case "type", "type_text", "input", "input_text", "write", "enter_text":
            guard let text = (arguments["text"] as? String) ?? (arguments["value"] as? String)
                    ?? (arguments["content"] as? String) else {
                throw AgentProtocolError.invalidText
            }
            return .type(text: text)
        case "key", "press", "hotkey", "keypress", "press_key", "shortcut", "key_press":
            var combo = (arguments["key"] as? String) ?? (arguments["keys"] as? String)
                ?? (arguments["name"] as? String) ?? ""
            if let list = arguments["keys"] as? [String] { combo = list.joined(separator: "+") }
            var modifiers = Set<KeyModifier>()
            if let names = arguments["modifiers"] as? [String] {
                for name in names {
                    guard let modifier = modifier(named: name) else { throw AgentProtocolError.unknownKey }
                    modifiers.insert(modifier)
                }
            }
            // "cmd+shift+s" style combos carry their modifiers in the string.
            let parts = combo.split(whereSeparator: { $0 == "+" || $0 == "-" }).map { String($0).trimmingCharacters(in: .whitespaces) }
            var keyName = parts.last ?? combo
            if parts.count > 1 {
                for part in parts.dropLast() {
                    if let modifier = modifier(named: part) { modifiers.insert(modifier) } else { throw AgentProtocolError.unknownKey }
                }
            }
            keyName = keyName.lowercased()
            if keyName == "cmd" || keyName == "command" || keyName == "ctrl" || keyName == "shift" || keyName == "alt" || keyName == "option" {
                throw AgentProtocolError.unknownKey
            }
            return .key(name: keyName, modifiers: modifiers)
        case "scroll", "scroll_down", "scroll_up":
            var deltaY = number(arguments["deltaY"]) ?? number(arguments["dy"]) ?? number(arguments["amount"]) ?? 0
            let deltaX = number(arguments["deltaX"]) ?? number(arguments["dx"]) ?? 0
            if let direction = (arguments["direction"] as? String)?.lowercased() {
                let magnitude = abs(deltaY) > 0 ? abs(deltaY) : 300
                switch direction {
                case "down": deltaY = -magnitude
                case "up": deltaY = magnitude
                default: break
                }
            }
            if type == "scroll_down" { deltaY = -(abs(deltaY) > 0 ? abs(deltaY) : 300) }
            if type == "scroll_up" { deltaY = abs(deltaY) > 0 ? abs(deltaY) : 300 }
            return .scroll(deltaX: deltaX, deltaY: deltaY, at: try? target(from: arguments))
        case "open", "open_app", "open_application", "launch", "launch_app", "openapplication":
            guard let name = (arguments["name"] as? String) ?? (arguments["app"] as? String)
                    ?? (arguments["application"] as? String) else {
                throw AgentProtocolError.invalidApplicationName
            }
            return .openApplication(name: name)
        case "wait", "sleep", "pause":
            let seconds = number(arguments["seconds"])
            let milliseconds = number(arguments["milliseconds"]) ?? number(arguments["ms"])
                ?? seconds.map { $0 * 1_000 } ?? 1_000
            return .wait(milliseconds: Int(milliseconds.rounded()))
        case "look", "screenshot", "inspect", "zoom", "see", "view_screen", "take_screenshot":
            let reason = (arguments["reason"] as? String) ?? (arguments["text"] as? String) ?? ""
            return .look(reason: reason)
        case "escalate", "stuck", "help", "cannot", "blocked", "replan", "need_help":
            let reason = (arguments["reason"] as? String) ?? (arguments["text"] as? String)
                ?? (arguments["message"] as? String) ?? ""
            return .escalate(reason: reason)
        case "done", "finish", "finished", "complete", "completed", "stop", "end", "final_answer", "answer":
            let summary = (arguments["summary"] as? String) ?? (arguments["message"] as? String)
                ?? (arguments["text"] as? String) ?? (arguments["answer"] as? String) ?? "Done."
            return .done(summary: summary)
        case "ask", "question", "ask_user", "clarify", "request_input":
            let question = (arguments["question"] as? String) ?? (arguments["text"] as? String)
                ?? (arguments["message"] as? String) ?? ""
            return .ask(question: question)
        default:
            throw AgentProtocolError.unknownActionType(String(rawType.prefix(40)))
        }
    }

    private static func target(from arguments: [String: Any]) throws -> AgentTargetReference {
        if let targetObject = arguments["target"] as? [String: Any] {
            return try target(from: targetObject)
        }
        if let element = (arguments["element"] as? String) ?? (arguments["element_id"] as? String)
            ?? (arguments["id"] as? String) ?? (arguments["target"] as? String) {
            return .element(id: normalizedElementID(element))
        }
        if let x = number(arguments["x"]), let y = number(arguments["y"]) {
            // Pixel-looking numbers are refused: the model is told to use normalized coordinates.
            return .point(try NormalizedPoint(x: x, y: y))
        }
        if let coordinate = arguments["coordinate"] as? [Any], coordinate.count == 2,
           let x = number(coordinate[0]), let y = number(coordinate[1]) {
            return .point(try NormalizedPoint(x: x, y: y))
        }
        throw AgentProtocolError.missingTarget
    }

    /// Models echo ids the way they were listed ("[e3]", "#t2", "e3 "); the id is the bare token.
    public static func normalizedElementID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]#<> \t\n\"'"))
    }

    private static func modifier(named name: String) -> KeyModifier? {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "meta", "super": .command
        case "alt", "option", "opt": .option
        case "ctrl", "control": .control
        case "shift": .shift
        case "fn", "function": .function
        default: nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// The first balanced `{ ... }` in the text, with fences stripped.
    public static func firstJSONObject(in text: String) -> [String: Any]? {
        var candidates: [String] = []
        let stripped = text.replacingOccurrences(of: "```json", with: "```")
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in stripped.indices {
            let character = stripped[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = start {
                    candidates.append(String(stripped[begin...index]))
                    start = nil
                }
            default: break
            }
        }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }
}
