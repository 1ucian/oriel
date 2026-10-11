import Foundation
import HermesCaptureCore
import HermesCaptureProtocol

/// One piece of the plan: a small goal the fast executor can finish against the screen, or
/// a direct action the planner already knows is right (no model call at all).
struct AssistantSubtask: Equatable, Sendable {
    let id: Int
    let goal: String
    let doneWhen: String?
    let directAction: AgentAction?

    var title: String {
        if let directAction { return AssistantRuntime.describe(directAction) }
        return goal
    }

    /// The thing a goal like "Open Dana's DM" or "Click the qa channel" names on screen:
    /// "dana", "qa". Nil when the goal does not start with a verb that means "go there".
    static func targetName(in goal: String) -> String? {
        let verbs = ["click on ", "click ", "open ", "select ", "go to ", "switch to ", "tap on ", "tap ",
                     "choose ", "navigate to ", "jump to ", "show ", "search for ", "find ", "look for ", "locate "]
        var trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["please ", "find and ", "search and ", "locate and ", "go and "] where trimmed.lowercased().hasPrefix(lead) {
            trimmed.removeFirst(lead.count)
        }
        guard let verb = verbs.first(where: { trimmed.lowercased().hasPrefix($0) }) else { return nil }
        return cleanedName(String(trimmed.dropFirst(verb.count)))
    }

    /// The conversation a reading goal is about: "Read the last message from Dana",
    /// "Check for new DMs from Dana", "Read Dana's DM". Nil when it names none.
    static func mentionedConversation(in goal: String) -> String? {
        // Sliced from one lowered copy: indexes of the original would not line up.
        let lowered = goal.replacingOccurrences(of: "’", with: "'").lowercased()
        if let range = lowered.range(of: #"\w+'s (dm|dms|direct message|chat|conversation|messages)"#, options: .regularExpression) {
            return cleanedName(String(lowered[range]))
        }
        for marker in [" from ", " with "] {
            if let range = lowered.range(of: marker),
               ["message", "dm", "chat", "conversation", "thread"].contains(where: { lowered[..<range.lowerBound].contains($0) }) {
                return cleanedName(String(lowered[range.upperBound...]))
            }
        }
        return nil
    }

    private static func cleanedName(_ raw: String) -> String? {
        var name = raw
        for separator in [" and ", " then ", " to read", " to see", " to check", " in ", " on ", ",", ";", ".", ":", "("] {
            if let range = name.range(of: separator, options: .caseInsensitive) {
                name = String(name[..<range.lowerBound])
            }
        }
        for article in ["the ", "a ", "an "] where name.lowercased().hasPrefix(article) {
            name.removeFirst(article.count)
        }
        name = name.replacingOccurrences(of: "’", with: "'")
        name = name.replacingOccurrences(of: #"(?<=\w)'s(?=\s|$)"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.filter { !"'\"‘“”".contains($0) }
        let generic = [" direct messages", " direct message", " dms", " dm", " conversation", " chat", " channel",
                       " thread", " tab", " button", " folder", " file", " page", " menu", " item", " link",
                       " section", " window", " messages", " inbox"]
        var stripped = true
        while stripped {
            stripped = false
            for suffix in generic where name.lowercased().hasSuffix(suffix) {
                name.removeLast(suffix.count)
                stripped = true
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#@\"'")))
        guard name.count >= 2, name.count <= 40, name.split(separator: " ").count <= 4 else { return nil }
        return name
    }

    /// The one thing on screen called `name`. Several things often share a name (a person in a
    /// sidebar and in group conversations); the one alone on its row is the navigation entry.
    /// Nil when nothing, or more than one candidate, fits.
    static func grounded(_ name: String, in observation: AgentObservation) -> AgentTargetReference? {
        struct Spot { let id: String; let label: String; let x: Double; let y: Double; let width: Double; let height: Double }
        func normalize(_ text: String) -> String {
            var words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            // OCR reads avatars, status dots, badges and "#" as short words in front of a name:
            // "Lo dana", "2 dana, Priya Nair", "# new-releases".
            while words.count > 1, let first = words.first, first.count <= 2 { words.removeFirst() }
            return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "#@•*&·"))
        }
        // Too small to be clicked: scrolled away or clipped.
        func visible(_ spot: Spot) -> Bool { spot.width >= 0.004 && spot.height >= 0.004 }
        let wanted = normalize(name)
        let controls = observation.elements.filter { !$0.isSensitive }.map {
            Spot(id: $0.id, label: $0.label, x: $0.centerX, y: $0.centerY, width: $0.width, height: $0.height)
        }
        let lines = observation.texts.filter { !$0.isSensitive }.map {
            Spot(id: $0.id, label: $0.text, x: $0.centerX, y: $0.centerY, width: $0.width, height: $0.height)
        }
        // The same thing read twice (accessibility and OCR) is one candidate.
        var matches: [Spot] = []
        for spot in controls + lines where visible(spot) && normalize(spot.label) == wanted {
            if !matches.contains(where: { abs($0.x - spot.x) < 0.02 && abs($0.y - spot.y) < 0.012 }) {
                matches.append(spot)
            }
        }
        if matches.count == 1 { return .element(id: matches[0].id) }
        let others = lines + observation.elements.filter { !$0.role.contains("image") && !$0.isSensitive }.map {
            Spot(id: $0.id, label: $0.label, x: $0.centerX, y: $0.centerY, width: $0.width, height: $0.height)
        }
        let alone = matches.filter { match in
            !others.contains { other in
                let label = normalize(other.label)
                guard label != wanted, !label.isEmpty else { return false }
                let sameRow = abs(other.y - match.y) < max(0.012, match.height * 0.6)
                let gap = abs(other.x - match.x) - (other.width + match.width) / 2
                return sameRow && gap < 0.06
            }
        }
        if alone.count == 1 { return .element(id: alone[0].id) }
        // Several entries stand alone (a sidebar and a detail panel both list the person): the
        // one clearly furthest left is the navigation list in nearly every Mac app.
        let byX = alone.sorted { $0.x < $1.x }
        if byX.count > 1, byX[1].x - byX[0].x > 0.1 { return .element(id: byX[0].id) }
        return nil
    }

    /// How a name was matched, for the activity log: every candidate and the one chosen.
    static func groundingNote(_ name: String, in observation: AgentObservation, chose: AgentTargetReference?) -> String {
        let wanted = name.lowercased()
        let ids = (observation.elements.filter { $0.label.lowercased().contains(wanted) }.map(\.id)
                   + observation.texts.filter { $0.text.lowercased().contains(wanted) }.map(\.id)).prefix(12)
        let picked: String
        if case let .element(id)? = chose { picked = id } else { picked = "none" }
        return "Matching \"\(name)\" on screen: chose \(picked) among \(ids.joined(separator: ", "))"
    }

    /// The exact text a goal like "Type '12*7=' into Calculator" spells out.
    static func quotedTyping(in goal: String) -> String? {
        let pattern = #"^\s*type\s+["'“‘](.+?)["'”’]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let range = Range(match.range(at: 1), in: goal) else { return nil }
        let text = String(goal[range])
        return text.isEmpty || text.count > 200 ? nil : text
    }

    /// Instructions that ask for information, so the run must end with an answer rather than
    /// with "clicked X".
    /// "compute 12 times 7", "what is 3.5 + 4": the arithmetic an instruction spells out, the
    /// way Calculator's keyboard takes it ("12*7"). Nil when there is none.
    static func arithmeticExpression(in text: String) -> String? {
        var lowered = " " + text.lowercased() + " "
        for (word, symbol) in [(" multiplied by ", "*"), (" times ", "*"), (" × ", "*"), (" x ", "*"),
                               (" divided by ", "/"), (" over ", "/"), (" ÷ ", "/"), (" plus ", "+"), (" minus ", "-")] {
            lowered = lowered.replacingOccurrences(of: word, with: " \(symbol) ")
        }
        lowered = lowered.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        let number = #"\d+(?:\.\d+)?"#
        guard let range = lowered.range(of: "\(number)(?:\\s*[-+*/]\\s*\(number))+", options: .regularExpression) else { return nil }
        return lowered[range].replacingOccurrences(of: " ", with: "")
    }

    /// The value of an expression from `arithmeticExpression` ("12*7", "3.5+4*2"), with * and /
    /// before + and -. Nil for anything else or a division by zero.
    static func evaluate(_ expression: String) -> Double? {
        var numbers: [Double] = []
        var operators: [Character] = []
        var current = ""
        for character in expression {
            if "+-*/".contains(character), !current.isEmpty {
                guard let number = Double(current) else { return nil }
                numbers.append(number)
                operators.append(character)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard let last = Double(current), !operators.isEmpty else { return nil }
        numbers.append(last)
        var terms = [numbers[0]]
        var additions: [Character] = []
        for (index, op) in operators.enumerated() {
            let number = numbers[index + 1]
            switch op {
            case "*": terms[terms.count - 1] *= number
            case "/":
                guard number != 0 else { return nil }
                terms[terms.count - 1] /= number
            default:
                terms.append(number)
                additions.append(op)
            }
        }
        var result = terms[0]
        for (index, op) in additions.enumerated() {
            result = op == "+" ? result + terms[index + 1] : result - terms[index + 1]
        }
        return result
    }

    /// A number the way a calculator display shows it: no decimals for whole numbers.
    static func displayed(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    /// Whether a screen line shows the number (thousands separators and direction marks aside).
    static func shows(_ number: String, in observation: AgentObservation) -> Bool {
        let lines = observation.texts.map(\.text) + observation.elements.map(\.label)
        return lines.contains { line in
            line.filter { !",\u{200E}\u{200F} ".contains($0) } == number
        }
    }

    /// The text lines right above a chat app's message box, in the conversation's own column
    /// (the sidebar is left out), oldest first: where the newest messages are.
    static func linesAboveMessageBox(in observation: AgentObservation, limit: Int = 6) -> [String] {
        let composers = observation.elements.filter { element in
            let label = element.label.lowercased()
            return label.hasPrefix("message ") || label.hasPrefix("imessage") || label.contains("type a message")
                || label.contains("write a message")
        }
        guard let box = composers.max(by: { $0.centerY < $1.centerY }) else { return [] }
        let left = box.centerX - box.width / 2 - 0.03
        let right = box.centerX + box.width / 2 + 0.03
        return observation.texts
            .filter { $0.centerY < box.centerY - box.height / 2 && (left...right).contains($0.centerX) }
            .sorted { $0.centerY < $1.centerY }
            .suffix(limit)
            .map(\.text)
    }

    /// Lines a chat app shows by the message box that are not messages: Slack's "It's 1:11 AM
    /// for dana" (the person's local time) and typing indicators.
    static func withoutChatChrome(_ observation: AgentObservation) -> AgentObservation {
        let chrome = #"(?i)^(it's|it is) \d{1,2}:\d{2}\s?(am|pm) for |\b(is|are) typing\b"#
        let texts = observation.texts.filter { $0.text.replacingOccurrences(of: "’", with: "'").range(of: chrome, options: .regularExpression) == nil }
        return AgentObservation(frontmostApplication: observation.frontmostApplication,
                                frontmostBundleIdentifier: observation.frontmostBundleIdentifier,
                                windowTitle: observation.windowTitle, displayWidth: observation.displayWidth,
                                displayHeight: observation.displayHeight, pointerX: observation.pointerX,
                                pointerY: observation.pointerY, elements: observation.elements, texts: texts,
                                capturedAtNanoseconds: observation.capturedAtNanoseconds, focusedField: observation.focusedField)
    }

    static func wantsAnAnswer(_ instruction: String) -> Bool {
        let lowered = " " + instruction.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        return [" read", "tell me", " check", "what ", "whether", "if there", "find out", "summar", "how many", " any new",
                "let me know", " show me", " who "].contains { lowered.contains($0) }
    }

    /// The conversation a goal or an instruction names: "Dana's DM", "new DMs from Dana",
    /// "#qa", "the qa channel". Nil when it names none.
    static func conversationTarget(in text: String) -> String? {
        if let name = mentionedConversation(in: text), !genericConversationNames.contains(name.lowercased()) { return name }
        let lowered = text.lowercased()
        if let range = lowered.range(of: #"#[a-z0-9][a-z0-9_-]*"#, options: .regularExpression) {
            return String(lowered[range].dropFirst())
        }
        guard ["dm", "direct message", "channel", "chat", "conversation"].contains(where: { lowered.contains($0) }),
              let name = targetName(in: text), !genericConversationNames.contains(name.lowercased()) else { return nil }
        return name
    }

    /// What is left of "Open Direct Messages" or "Open the DMs" once the kind of place is
    /// stripped: the list of conversations, not one named conversation.
    static let genericConversationNames: Set<String> = [
        "direct", "direct messages", "direct message", "dms", "dm", "messages", "message", "channels", "channel",
        "chats", "chat", "conversations", "conversation", "inbox", "threads", "unread", "unreads", "new", "all",
        "mentions", "my", "any new", "new direct", "any",
    ]

    /// App names an instruction mentions after "go to", "open", "in", "switch to" and the like,
    /// in order: "Go to Slack, open Dana's DM" gives ["Slack", "Dana's DM"]. Only names that
    /// turn out to be installed apps are used.
    static func applicationsMentioned(in instruction: String) -> [String] {
        // Verbs in any case; names must start with a capital letter.
        let pattern = #"\b(?i:go to|open|in|on|switch to|launch|start|use|using)\s+((?:(?i:the)\s+)?[A-Z][\w.&+-]*(?:\s+[A-Z][\w.&+-]*){0,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(instruction.startIndex..., in: instruction)
        let capitalised: [String] = regex.matches(in: instruction, range: range).compactMap { match in
            guard let found = Range(match.range(at: 1), in: instruction) else { return nil }
            var name = String(instruction[found])
            if name.lowercased().hasPrefix("the ") { name.removeFirst(4) }
            for suffix in [" app", " application"] where name.lowercased().hasSuffix(suffix) { name.removeLast(suffix.count) }
            return name.first?.isUppercase == true ? name : nil
        }
        // People type "open calculator" and "in slack" too: the lowercase words that follow,
        // longest first. Only an installed app's exact name is ever used.
        let lower = #"\b(?i:go to|open|switch to|launch|start|in|use|using)\s+(?:the\s+)?([a-z][\w.&+-]*(?:\s+[a-z][\w.&+-]*){0,2})"#
        guard let lowerRegex = try? NSRegularExpression(pattern: lower) else { return capitalised }
        var lowercase: [String] = []
        for match in lowerRegex.matches(in: instruction, range: range) {
            guard let found = Range(match.range(at: 1), in: instruction) else { continue }
            let words = instruction[found].split(separator: " ").map(String.init)
            for count in stride(from: words.count, through: 1, by: -1) {
                let name = words.prefix(count).joined(separator: " ")
                if !["the", "a", "an", "my", "this", "that", "it"].contains(name), !(capitalised + lowercase).contains(name) {
                    lowercase.append(name)
                }
            }
        }
        return capitalised + lowercase
    }

    /// The jump box shortcut of chat apps that have one.
    static func quickSwitcher(for bundleIdentifier: String?) -> (key: String, modifiers: Set<KeyModifier>)? {
        switch bundleIdentifier {
        case "com.tinyspeck.slackmacgap", "com.hnc.Discord": ("k", [.command])
        default: nil
        }
    }

    /// Questions about the newest part of a conversation, which is what an open conversation
    /// shows: "read me the last message", "any new DMs from Dana".
    static func asksAboutLatest(_ instruction: String) -> Bool {
        let lowered = " " + instruction.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        return [" last message", " latest message", " newest message", " new message", " new dm", " any new",
                " recent message", " last thing", " unread", " last few message", " last messages", " latest messages"]
            .contains { lowered.contains($0) }
    }

    /// Goals whose whole point is something read off the screen.
    static func isReadingGoal(_ goal: String) -> Bool {
        let lowered = goal.lowercased()
        return ["read", "check", "tell", "find out", "look up", "see if", "see what", "report", "summarize", "summarise"]
            .contains { lowered.hasPrefix($0) }
    }

    /// A done summary that says nothing beyond "done" or the goal itself.
    static func isEmptyReport(_ summary: String, goal: String) -> Bool {
        var rest = summary.lowercased()
        for filler in ["done:", "done", goal.lowercased(), "the last message", "read", "."] {
            rest = rest.replacingOccurrences(of: filler, with: " ")
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).count < 12
    }

    /// The app a goal like "Open Slack" or "Go to the Calculator app" names, before checking
    /// that such an app exists; nil for any other kind of goal.
    static func applicationCandidate(in goal: String) -> String? {
        let verbs = ["open ", "launch ", "start ", "switch to ", "go to ", "bring up ", "activate ", "focus "]
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = verbs.first(where: { trimmed.lowercased().hasPrefix($0) }) else { return nil }
        var name = String(trimmed.dropFirst(verb.count))
        for separator in [" and ", " then ", " to ", ",", ";", ".", ":", "("] {
            if let range = name.range(of: separator, options: .caseInsensitive) {
                name = String(name[..<range.lowerBound])
            }
        }
        if name.lowercased().hasPrefix("the ") { name.removeFirst(4) }
        for suffix in [" app", " application", " window"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard name.count >= 2, name.count <= 40, name.split(separator: " ").count <= 4 else { return nil }
        return name
    }
}

/// The planner's verdict on the executor's progress, asked for while the executor works.
enum AssistantReview: Equatable, Sendable {
    case onTrack
    /// One sentence the executor reads with its next step.
    case hint(String)
    /// The rest of the plan, replaced.
    case replan([AssistantSubtask])
    /// The owner's goal is already met; this is the answer.
    case done(String)
}

enum AssistantPlannerReply: Equatable, Sendable {
    case plan([AssistantSubtask], note: String?)
    /// The goal is already met, or cannot be met; the run ends with this summary.
    case done(summary: String)
    /// Only the owner can decide.
    case ask(question: String)
}

enum AssistantPlannerError: Error, Equatable {
    case malformed
    case emptyPlan
    /// Every sub-task repeated the format description instead of the goal.
    case placeholderPlan
}

/// What the executor tells the planner at a boundary.
struct AssistantSubtaskReport: Equatable, Sendable {
    enum Outcome: String, Sendable {
        case completed
        case stuck
        case budgetExceeded
    }

    let subtask: AssistantSubtask
    let outcome: Outcome
    let summary: String
    let stepsUsed: Int
}

/// The big, slow brain. It sees text only: the instruction, a text observation of the
/// screen, and the executor's reports. It never sees pixels.
enum AssistantPlanner {
    static let maximumSubtasks = 16

    /// `observation` is the screen the plan was made from: a direct click on one of its ids
    /// becomes a goal naming the control, so the executor resolves it against the live screen
    /// (ids are re-numbered every step, and small planners over-use direct clicks).
    static func parse(_ text: String, observation: AgentObservation? = nil) throws -> AssistantPlannerReply {
        guard let object = AgentModelResponseParser.firstJSONObject(in: text) else {
            throw AssistantPlannerError.malformed
        }
        if let summary = (object["done"] as? String) ?? (object["finished"] as? String), !summary.isEmpty {
            return .done(summary: summary)
        }
        if let question = (object["ask"] as? String) ?? (object["question"] as? String), !question.isEmpty {
            return .ask(question: question)
        }
        guard let items = (object["plan"] as? [Any]) ?? (object["steps"] as? [Any]) ?? (object["subtasks"] as? [Any]) else {
            throw AssistantPlannerError.malformed
        }
        var subtasks: [AssistantSubtask] = []
        var droppedPlaceholders = 0
        for item in items.prefix(maximumSubtasks) {
            let id = subtasks.count + 1
            if let goal = item as? String {
                let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if Self.isTemplateWording(trimmed) { droppedPlaceholders += 1; continue }
                subtasks.append(AssistantSubtask(id: id, goal: trimmed, doneWhen: nil, directAction: nil))
                continue
            }
            guard let entry = item as? [String: Any] else { continue }
            if let actionObject = entry["action"] as? [String: Any],
               let step = try? AgentModelResponseParser.parse(try string(from: actionObject)),
               step.action.movesTheMac || step.action.kind == "wait" {
                if Self.isTemplateAction(step.action) { droppedPlaceholders += 1; continue }
                let goal = (entry["goal"] as? String) ?? AssistantRuntime.describe(step.action, in: observation)
                if Self.isScreenDependent(step.action) {
                    // Not direct: the executor finds the control on the screen it actually sees.
                    let doneWhen = ((entry["done_when"] as? String) ?? (entry["doneWhen"] as? String))?
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    subtasks.append(AssistantSubtask(id: id, goal: goal, doneWhen: doneWhen?.isEmpty == true ? nil : doneWhen, directAction: nil))
                } else {
                    subtasks.append(AssistantSubtask(id: id, goal: goal, doneWhen: nil, directAction: step.action))
                }
                continue
            }
            let rawGoal: String? = (entry["goal"] as? String) ?? (entry["task"] as? String) ?? (entry["description"] as? String)
            guard let goal = rawGoal?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !goal.isEmpty else { continue }
            if Self.isTemplateWording(goal) { droppedPlaceholders += 1; continue }
            let rawDoneWhen: String? = (entry["done_when"] as? String) ?? (entry["doneWhen"] as? String) ?? (entry["success"] as? String)
            var doneWhen = rawDoneWhen?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if let candidate = doneWhen, Self.isTemplateWording(candidate) { doneWhen = nil }
            subtasks.append(AssistantSubtask(id: id, goal: goal, doneWhen: doneWhen?.isEmpty == true ? nil : doneWhen, directAction: nil))
        }
        // "Done" or "Finish" as a step is filler; the run ends on its own after the last real one.
        subtasks.removeAll { subtask in
            subtask.directAction == nil
                && ["done", "finish", "finished", "complete", "end", "stop"].contains(
                    subtask.goal.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
        }
        guard !subtasks.isEmpty else {
            throw droppedPlaceholders > 0 ? AssistantPlannerError.placeholderPlan : AssistantPlannerError.emptyPlan
        }
        var note = (object["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = note, Self.isTemplateWording(candidate) { note = nil }
        return .plan(subtasks, note: note)
    }

    /// Small models sometimes answer with the format description itself: angle-bracket
    /// placeholders, ellipses, or the phrases that describe a field.
    static func isTemplateWording(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "..." || trimmed == "…" { return true }
        if trimmed.contains("<"), trimmed.contains(">") { return true }
        let lowered = trimmed.lowercased()
        let phrases = ["one outcome", "in plain words", "what the screen shows", "optional short note",
                       "the answer they asked for", "only the owner can answer", "specific to the owner"]
        return phrases.contains { lowered.contains($0) }
    }

    static func isTemplateAction(_ action: AgentAction) -> Bool {
        switch action {
        case let .type(text): isTemplateWording(text)
        case let .openApplication(name): isTemplateWording(name)
        default: false
        }
    }

    /// Clicks and targeted scrolls depend on what is on screen when they run; keys, typing,
    /// opening apps and waiting do not.
    static func isScreenDependent(_ action: AgentAction) -> Bool {
        switch action {
        case .click: true
        case let .scroll(_, _, at): at != nil
        default: false
        }
    }

    private static func string(from object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}"
    }

    static let system = """
    You are the planner for Oriel, an assistant that operates a Mac for its owner. A fast, \
    small executor model carries out your plan one small sub-task at a time while reading the \
    screen; it is good at clicking listed controls, typing and pressing keys, and bad at long \
    reasoning. You see a text description of the screen (never pixels) and the executor's \
    reports. Break the owner's goal into small, screen-verifiable sub-tasks, in order. Where a \
    step is certain (a keyboard shortcut, opening an app, typing known text), give the exact \
    action instead of a goal so no model call is needed.

    Reply with one JSON object and nothing else. Its keys: "plan", an array of sub-tasks in \
    order, where each sub-task is either an object with "goal" (one outcome, in your own plain \
    words, specific to the owner's goal) and "done_when" (what the screen shows once that \
    outcome is reached), or an object with "action" (one direct action from the list below) \
    when the step is certain; and optionally "note", one short sentence for the owner that \
    carries the answer when they asked for one. Instead of "plan", reply with "done" (why \
    nothing needs doing, or why it cannot be done) or "ask" (the one question only the owner \
    can answer). Wording that is generic or describes the format instead of the goal is \
    rejected.

    Direct actions available: click {"type":"click","target":{"element":"e12"}} (only ids from the \
    screen description), type {"type":"type","text":"..."}, key {"type":"key","key":"return"} or \
    {"type":"key","key":"s","modifiers":["command"]}, scroll {"type":"scroll","deltaY":-300}, \
    openApplication {"type":"openApplication","name":"..."}, wait {"type":"wait","milliseconds":800}.

    Rules: at most \(maximumSubtasks) sub-tasks; each goal is one thing the executor can finish in \
    a few clicks; name what the screen should show when it is done; plan only what the owner \
    asked for, no extra steps such as screenshots, saving or notes unless asked; goals are \
    outcomes in plain words, never the name of a control that is not in the screen description; \
    where keyboard input works (editors, terminals, calculators, search fields) plan typing and \
    keys, for example type "12*7=" rather than clicking digit buttons; when the owner asks for a \
    value or an answer, the last goal is to read it off the screen and its done_when names what \
    to read, and the note repeats the answer; never plan to type passwords, one-time codes or \
    card numbers, operate security dialogs, pay, delete, or send publicly (Oriel asks the owner \
    for those); when revising after a report, return only the remaining plan.
    """

    static func initialMessage(instruction: AgentInstruction, observation: AgentObservation, history: [String] = [],
                               readOnly: Bool = false) -> String {
        var text = ""
        if readOnly {
            text += "This is a read-only request: do not plan any action that touches the Mac "
                + "(no clicks, typing, keys, scrolling or opening apps). Answer only from what is on the "
                + "screen now; reply with {\"done\":\"<the answer>\"} quoting the screen.\n\n"
        }
        if !history.isEmpty {
            text += "Earlier in this session, oldest first (the owner may refer to these):\n"
            for (index, line) in history.suffix(AssistantRuntime.episodeLimit).enumerated() {
                text += "\(index + 1). \(line.prefix(300))\n"
            }
            text += "\n"
        }
        text += """
        Owner's goal: \(instruction.text)

        Current screen:
        \(AgentObservationRenderer.render(observation, maximumBytes: 9_000, pinning: AssistantPrompt.keyWords(instruction.text)))

        Reply with the plan as one JSON object.
        """
        return text
    }

    /// The answer in an answer-step reply: {"done": "..."} or the same under another key, or
    /// plain words. Nil for a plan, a question or nothing usable.
    static func answerText(in reply: String) -> String? {
        var text = reply
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objects = topLevelObjects(in: text)
        if !objects.isEmpty {
            let answers = objects.filter { $0["plan"] == nil && $0["ask"] == nil }
            for object in answers {
                for key in ["done", "answer", "result", "reply", "text", "message", "summary", "note"] {
                    if let value = object[key], let answer = flattened(value) { return answer }
                }
            }
            // {"who": "...", "what": "..."}: the fields themselves are the answer.
            return answers.lazy.compactMap { flattened($0) }.first
        }
        guard !text.contains("{"), (2...600).contains(text.count) else { return nil }
        return text
    }

    /// Every top-level JSON object in a reply, in order (a small model sometimes sends a plan
    /// and then the answer).
    private static func topLevelObjects(in text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}" where depth > 0:
                depth -= 1
                if depth == 0, let begin = start,
                   let data = String(text[begin...index]).data(using: .utf8),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    objects.append(object)
                }
            default: break
            }
        }
        return objects
    }

    /// An answer value as words: text as is, an object as "field: value" pairs, a list joined.
    private static func flattened(_ value: Any) -> String? {
        let text: String
        switch value {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        case let object as [String: Any]:
            // {"sender": ..., "time": ..., "message": ...} reads as "Sender at time: message".
            func first(_ keys: [String]) -> String? { keys.lazy.compactMap { object[$0] as? String }.first }
            if let who = first(["sender", "from", "author", "who", "name", "user", "posted_by"]),
               let said = first(["message", "text", "content", "says", "said", "words", "quote", "what", "body"]) {
                text = who + (first(["time", "timestamp", "at", "when"]).map { " at \($0)" } ?? "") + ": " + said
            } else {
                text = object.keys.sorted().compactMap { key in flattened(object[key]!).map { "\(key): \($0)" } }.joined(separator: ", ")
            }
        case let list as [Any]: text = list.compactMap(flattened).joined(separator: ", ")
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(600))
    }

    /// The last word on a question: the steps are done and the answer is on the screen.
    static func answerMessage(instruction: AgentInstruction, completed: [AssistantSubtaskReport], observation: AgentObservation) -> String {
        var text = "Owner's goal: \(instruction.text)\n\n"
        if !completed.isEmpty {
            text += "Done so far:\n"
            for item in completed { text += "- \(item.subtask.title) → \(item.summary)\n" }
            text += "\n"
        }
        text += "Every step is done. The owner is waiting for the answer, and it is on the screen below. "
        text += "Reply {\"done\":\"<the answer>\"}, quoting the exact words from the screen. "
        let conversation = AgentApprovalPolicy.isChatApp(bundleIdentifier: observation.frontmostBundleIdentifier)
        if conversation {
            text += "This screen is a conversation: its newest message is the lowest message above the message box. "
            text += "Give who sent it, the time if shown, and its words. Headers, a person's status and lines such as "
            text += "\"It's 12:46 AM for dana\" (their local time) are not messages. Asked whether someone sent anything "
            text += "new, say whether the newest message is from them and quote it. "
            let newest = AssistantSubtask.linesAboveMessageBox(in: AssistantSubtask.withoutChatChrome(observation))
            if !newest.isEmpty {
                text += "\n\nThe lines just above the message box, oldest first. The last one is the newest message, and its sender is "
                text += "the nearest name above it (a name followed by a time):\n"
                text += newest.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
            }
        }
        text += "If the screen does not show the answer, say what it shows instead.\n\n"
        // In a conversation the person's name is on every header and status line; pinning it
        // would put those above the messages. Slack's local-time banner sits right above the
        // message box, where the newest message would be, so it is left out.
        let pins = conversation ? [] : AssistantPrompt.keyWords(instruction.text)
        let screen = conversation ? AssistantSubtask.withoutChatChrome(observation) : observation
        text += "Current screen:\n\(AgentObservationRenderer.render(screen, maximumBytes: 9_000, pinning: pins))\n\n"
        text += "Reply with one JSON object."
        return text
    }

    /// The planner looks over the executor's shoulder: the sub-task, its steps so far and the
    /// screen now. It can let it carry on, steer it with one sentence, replace the plan or end.
    static func reviewMessage(instruction: AgentInstruction, subtask: AssistantSubtask, steps: [String],
                              observation: AgentObservation) -> String {
        var text = "Owner's goal: \(instruction.text)\n"
        text += "The executor is working on: \(subtask.goal)\n"
        if let doneWhen = subtask.doneWhen { text += "It is done when: \(doneWhen)\n" }
        text += "\nIts steps so far:\n" + steps.suffix(8).joined(separator: "\n") + "\n\n"
        text += "You are watching it work and can steer it. Reply with one JSON object:\n"
        text += "{\"continue\":true} when it is making progress;\n"
        text += "{\"hint\":\"<one sentence: the next thing to do, naming a control or text on the screen below>\"} when it is drifting, repeating itself or misreading the screen;\n"
        text += "{\"plan\":[...]} to replace the remaining plan when this sub-task is the wrong way to the goal;\n"
        text += "{\"done\":\"<the answer, quoting the screen>\"} when the owner's goal is already met on the screen.\n\n"
        text += "Current screen:\n" + AgentObservationRenderer.render(
            observation, maximumBytes: 7_000, pinning: AssistantPrompt.keyWords(instruction.text + " " + subtask.goal))
        text += "\n\nReply with one JSON object."
        return text
    }

    static func parseReview(_ text: String, observation: AgentObservation? = nil) -> AssistantReview {
        guard let object = AgentModelResponseParser.firstJSONObject(in: text) else { return .onTrack }
        if let hint = (object["hint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty, !isTemplateWording(hint) {
            return .hint(hint)
        }
        if object["plan"] != nil, case let .plan(subtasks, _)? = try? parse(text, observation: observation) {
            return .replan(subtasks)
        }
        if let done = (object["done"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !done.isEmpty, !isTemplateWording(done) {
            return .done(done)
        }
        return .onTrack
    }

    static func revisionMessage(
        instruction: AgentInstruction,
        completed: [AssistantSubtaskReport],
        report: AssistantSubtaskReport,
        remaining: [AssistantSubtask],
        observation: AgentObservation,
        revisions: Int
    ) -> String {
        var text = "Owner's goal: \(instruction.text)\n\n"
        if !completed.isEmpty {
            text += "Finished so far:\n"
            for item in completed { text += "- \(item.subtask.title) → \(item.summary)\n" }
            text += "\n"
        }
        text += "The executor reports on \"\(report.subtask.title)\": \(report.outcome.rawValue) after \(report.stepsUsed) steps. \(report.summary)\n\n"
        if !remaining.isEmpty {
            text += "Planned but not started:\n"
            for item in remaining { text += "- \(item.title)\n" }
            text += "\n"
        }
        if revisions >= 2 {
            text += "This is revision \(revisions + 1). If the goal cannot be reached this way, reply with done and say why, or ask the owner.\n\n"
        }
        text += "Current screen:\n\(AgentObservationRenderer.render(observation, maximumBytes: 9_000))\n\n"
        text += "Reply with the remaining plan (or done, or ask) as one JSON object."
        return text
    }
}
