import Foundation

/// A control the assistant may name in an action, numbered for the model ("e12").
public struct AgentObservedElement: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let label: String
    public let centerX: Double
    public let centerY: Double
    public let width: Double
    public let height: Double
    public let isEnabled: Bool
    public let isSensitive: Bool

    public init(
        id: String,
        role: String,
        label: String,
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double,
        isEnabled: Bool,
        isSensitive: Bool
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.isEnabled = isEnabled
        self.isSensitive = isSensitive
    }
}

/// A line of on-device OCR, numbered for the model ("t4").
public struct AgentObservedText: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let centerX: Double
    public let centerY: Double
    public let width: Double
    public let height: Double
    public let isSensitive: Bool

    public init(
        id: String,
        text: String,
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double,
        isSensitive: Bool
    ) {
        self.id = id
        self.text = text
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.isSensitive = isSensitive
    }
}

/// What the Mac read from its own screen for one step. Pixels are not part of it; a
/// screenshot travels separately and only where the sharing policy allows.
public struct AgentObservation: Equatable, Sendable {
    /// Generous: the runtime matches names against everything on screen, and the renderer
    /// decides what fits in a model's prompt.
    public static let defaultElementLimit = 300
    public static let defaultTextLimit = 400

    public let frontmostApplication: String?
    public let frontmostBundleIdentifier: String?
    public let windowTitle: String?
    public let displayWidth: Int
    public let displayHeight: Int
    public let pointerX: Double?
    public let pointerY: Double?
    public let elements: [AgentObservedElement]
    public let texts: [AgentObservedText]
    public let capturedAtNanoseconds: UInt64
    /// The text input that has keyboard focus, as "role: label" ("AXTextField: Search"), so
    /// typing and Return go where the owner expects.
    public let focusedField: String?

    public init(
        frontmostApplication: String?,
        frontmostBundleIdentifier: String?,
        windowTitle: String?,
        displayWidth: Int,
        displayHeight: Int,
        pointerX: Double?,
        pointerY: Double?,
        elements: [AgentObservedElement],
        texts: [AgentObservedText],
        capturedAtNanoseconds: UInt64,
        focusedField: String? = nil
    ) {
        self.focusedField = focusedField
        self.frontmostApplication = frontmostApplication
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.windowTitle = windowTitle
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.pointerX = pointerX
        self.pointerY = pointerY
        self.elements = elements
        self.texts = texts
        self.capturedAtNanoseconds = capturedAtNanoseconds
    }

    public func element(id: String) -> AgentObservedElement? {
        elements.first { $0.id == id }
    }

    public func text(id: String) -> AgentObservedText? {
        texts.first { $0.id == id }
    }

    /// Numbers accessibility controls and OCR lines from the perception providers. Controls
    /// come first by reading order; a text line fully inside a labelled control is dropped as
    /// a duplicate.
    public static func make(
        candidates: [TargetCandidate],
        frontmostApplication: String?,
        frontmostBundleIdentifier: String?,
        windowTitle: String?,
        displayWidth: Int,
        displayHeight: Int,
        pointerX: Double?,
        pointerY: Double?,
        capturedAtNanoseconds: UInt64,
        focusedField: String? = nil,
        elementLimit: Int = defaultElementLimit,
        textLimit: Int = defaultTextLimit
    ) -> AgentObservation {
        func readingOrder(_ a: TargetCandidate, _ b: TargetCandidate) -> Bool {
            let rowA = (a.bounds.y * 40).rounded(), rowB = (b.bounds.y * 40).rounded()
            return rowA == rowB ? a.bounds.x < b.bounds.x : rowA < rowB
        }
        // The window reports itself as a control named after its title; clicking it does nothing.
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let controls = candidates
            .filter { $0.source == .accessibility && $0.role != .text }
            .filter { title.isEmpty || $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != title }
            // Scrolled away or clipped: a control a few pixels tall cannot be clicked.
            .filter { $0.bounds.width >= 0.004 && $0.bounds.height >= 0.004 }
            .sorted(by: readingOrder)
        let staticTexts = candidates
            .filter { $0.source == .accessibility && $0.role == .text }
        let ocr = candidates
            .filter { $0.source == .visionOCR }
            .sorted(by: readingOrder)
        // Shape detection (contours) fills in when the app exposes little or no accessibility.
        let regions = candidates
            .filter { $0.source == .openCV || $0.source == .ownedCoreML }
            .sorted(by: readingOrder)

        var elements: [AgentObservedElement] = []
        for candidate in (controls + regions).prefix(elementLimit) {
            elements.append(AgentObservedElement(
                id: "e\(elements.count + 1)",
                role: candidate.source == .accessibility ? candidate.role.rawValue : "region",
                label: candidate.isSensitive ? "secure field" : candidate.label,
                centerX: candidate.bounds.x + candidate.bounds.width / 2,
                centerY: candidate.bounds.y + candidate.bounds.height / 2,
                width: candidate.bounds.width,
                height: candidate.bounds.height,
                isEnabled: candidate.isEnabled,
                isSensitive: candidate.isSensitive
            ))
        }

        // All text in reading order. When there is more than the limit, the middle goes: the
        // top of a window and its bottom (where chats put the newest message) both stay.
        var readable: [TargetCandidate] = []
        var seen = Set<String>()
        for candidate in (staticTexts + ocr).sorted(by: readingOrder) {
            let normalized = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized + "@\(Int(candidate.bounds.y * 100))").inserted else { continue }
            let duplicatesControl = controls.contains { control in
                control.label.lowercased() == normalized
                    && control.bounds.overlapRatio(with: candidate.bounds) > 0.8
            }
            guard !duplicatesControl else { continue }
            readable.append(candidate)
        }
        var texts: [AgentObservedText] = []
        for candidate in keepingEnds(readable, limit: textLimit) {
            texts.append(AgentObservedText(
                id: "t\(texts.count + 1)",
                text: candidate.isSensitive ? "[redacted]" : candidate.label,
                centerX: candidate.bounds.x + candidate.bounds.width / 2,
                centerY: candidate.bounds.y + candidate.bounds.height / 2,
                width: candidate.bounds.width,
                height: candidate.bounds.height,
                isSensitive: candidate.isSensitive
            ))
        }

        return AgentObservation(
            frontmostApplication: frontmostApplication,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            windowTitle: windowTitle,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            pointerX: pointerX,
            pointerY: pointerY,
            elements: elements,
            texts: texts,
            capturedAtNanoseconds: capturedAtNanoseconds,
            focusedField: focusedField
        )
    }
}

/// The observation as the model reads it: compact lines, normalized coordinates, a byte
/// budget, and secrets already gone.
/// The first 40 percent and the last 60 percent of `items` when there are more than `limit`.
func keepingEnds<T>(_ items: [T], limit: Int) -> [T] {
    guard items.count > limit, limit > 0 else { return items }
    let head = limit * 2 / 5
    return Array(items.prefix(head)) + Array(items.suffix(limit - head))
}

public enum AgentObservationRenderer {
    /// `pinning`: words from the goal; lines that contain one are listed even when the screen
    /// is too long for the budget, so the thing the owner named is never the part left out.
    public static func render(_ observation: AgentObservation, maximumBytes: Int = 12_000, pinning: [String] = []) -> String {
        var lines: [String] = []
        var header = "Frontmost app: \(observation.frontmostApplication ?? "unknown")"
        if let title = observation.windowTitle, !title.isEmpty { header += " | Window: \(title)" }
        lines.append(header)
        if let focused = observation.focusedField, !focused.isEmpty {
            lines.append("Keyboard focus: \(clip(focused, 80)) (typed text goes here)")
        }
        var geometry = "Display: \(observation.displayWidth)x\(observation.displayHeight) px; coordinates below are normalized 0..1 (x right, y down)."
        if let x = observation.pointerX, let y = observation.pointerY {
            geometry += " Pointer at (\(format(x)), \(format(y)))."
        }
        lines.append(geometry)

        lines.append(observation.elements.isEmpty
            ? "Controls: none readable (the app exposes no accessibility tree; use OCR text or points)."
            : "Controls (click by id):")
        var budget = maximumBytes - lines.joined(separator: "\n").utf8.count - 200
        let controlLines = observation.elements.map { element -> String in
            var line = "[\(element.id)] \(element.role) \"\(clip(element.label, 80))\" center (\(format(element.centerX)), \(format(element.centerY))) size \(format(element.width))x\(format(element.height))"
            if !element.isEnabled { line += " disabled" }
            if element.isSensitive { line += " SENSITIVE, not available" }
            return line
        }
        let textLines = observation.texts.map {
            "[\($0.id)] \"\(clip($0.text, 120))\" center (\(format($0.centerX)), \(format($0.centerY)))"
        }
        // Controls may use half of the room when there is text too, so neither crowds out the other.
        let textBytes = textLines.reduce(0) { $0 + $1.utf8.count + 1 }
        var controlBudget = textLines.isEmpty ? budget : max(budget / 2, budget - textBytes)
        let words = pinning.map { $0.lowercased() }.filter { $0.count >= 3 }
        func pinned(_ lines: [String], _ labels: [String]) -> Set<Int> {
            guard !words.isEmpty else { return [] }
            return Set(labels.indices.filter { index in words.contains { labels[index].lowercased().contains($0) } })
        }
        let controls = fit(controlLines, budget: &controlBudget, pinned: pinned(controlLines, observation.elements.map(\.label)))
        budget -= controlLines.reduce(0) { $0 + $1.utf8.count + 1 } - controls.droppedBytes
        lines += controls.head
        if controls.dropped > 0 { lines.append("… \(controls.dropped) more controls not listed (middle of the list)") }
        lines += controls.tail

        lines.append(observation.texts.isEmpty ? "Text: none read." : "Text on screen (OCR, click by id or near its center):")
        let texts = fit(textLines, budget: &budget, pinned: pinned(textLines, observation.texts.map(\.text)))
        lines += texts.head
        if texts.dropped > 0 { lines.append("… \(texts.dropped) more text lines not listed (middle of the screen)") }
        lines += texts.tail
        return lines.joined(separator: "\n")
    }

    /// Lines that fit the budget: from the top up to 40 percent of it, the rest from the
    /// bottom, so the middle is what gets left out.
    private static func fit(_ lines: [String], budget: inout Int, pinned: Set<Int> = []) -> (head: [String], dropped: Int, tail: [String], droppedBytes: Int) {
        let total = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        guard total > budget else {
            budget -= total
            return (lines, 0, [], 0)
        }
        // Pinned lines first, up to half the room; then the top and the bottom of the rest.
        var chosen = Set<Int>()
        var used = 0
        for index in pinned.sorted() where used + lines[index].utf8.count + 1 <= budget / 2 {
            used += lines[index].utf8.count + 1
            chosen.insert(index)
        }
        let headBudget = max(0, budget * 2 / 5)
        var index = 0
        var headEnd = 0
        while index < lines.count, used + lines[index].utf8.count + 1 <= headBudget || chosen.contains(index) {
            if !chosen.contains(index) {
                used += lines[index].utf8.count + 1
                chosen.insert(index)
            }
            index += 1
            headEnd = index
        }
        var last = lines.count - 1
        while last >= headEnd {
            if !chosen.contains(last) {
                guard used + lines[last].utf8.count + 1 <= budget else { break }
                used += lines[last].utf8.count + 1
                chosen.insert(last)
            }
            last -= 1
        }
        budget -= used
        let head = (0..<headEnd).filter(chosen.contains).map { lines[$0] }
        let tail = (headEnd..<lines.count).filter(chosen.contains).map { lines[$0] }
        return (head, lines.count - chosen.count, tail, total - used)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit - 1)) + "…"
    }
}
