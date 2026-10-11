import AppKit
import CoreGraphics
import Foundation
import HermesCaptureCore
import HermesCaptureProtocol

/// One input primitive from a local tool, as input.json gives it.
struct LocalInputRequest: Equatable, Sendable {
    enum Action: String, Decodable, Sendable {
        case click, doubleClick, rightClick, key, type, scroll
    }

    struct Invalid: Error, Equatable {
        let id: String?
        let why: String
    }

    let id: String
    let action: Action
    /// The app that must be frontmost for the input to be sent.
    let app: String
    /// Screen points, for click, doubleClick, rightClick and scroll.
    let x: Double?
    let y: Double?
    let chord: String?
    let text: String?
    /// Scroll lines, positive is down (the toolkit's CGScrollWheelEvent convention).
    let lines: Double?
    /// Scroll columns, positive scrolls the content right (later columns into view).
    let columns: Double?

    private struct Header: Decodable { let id: String? }
    private struct Wire: Decodable {
        let action: String?
        let app: String?
        let x: Double?
        let y: Double?
        let chord: String?
        let text: String?
        let lines: Double?
        let columns: Double?
    }

    static func parse(_ data: Data) throws -> LocalInputRequest {
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw Invalid(id: nil, why: "input.json is not one JSON object with a string \"id\"")
        }
        guard let id = header.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(id: nil, why: "\"id\" is missing or empty")
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw Invalid(id: id, why: "input.json could not be read")
        }
        guard let actionName = wire.action, let action = Action(rawValue: actionName) else {
            throw Invalid(id: id, why: "\"action\" is missing or not one of click, doubleClick, rightClick, key, type, scroll")
        }
        guard let app = wire.app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(id: id, why: "\"app\" is missing or empty")
        }
        func point() throws {
            guard wire.x != nil, wire.y != nil else { throw Invalid(id: id, why: "\"\(actionName)\" needs \"x\" and \"y\"") }
        }
        switch action {
        case .click, .doubleClick, .rightClick:
            try point()
        case .scroll:
            try point()
            guard wire.lines != nil || wire.columns != nil else { throw Invalid(id: id, why: "\"scroll\" needs \"lines\" or \"columns\"") }
        case .key:
            guard let chord = wire.chord, !chord.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Invalid(id: id, why: "\"key\" needs \"chord\"")
            }
            guard LocalInputKeys.chord(chord) != nil else { throw Invalid(id: id, why: "\"chord\" has an unknown key") }
        case .type:
            guard let text = wire.text, !text.isEmpty else { throw Invalid(id: id, why: "\"type\" needs \"text\"") }
            guard text.utf8.count <= AgentInstruction.maximumTextBytes else { throw Invalid(id: id, why: "\"text\" is too long") }
        }
        return LocalInputRequest(id: id, action: action, app: app, x: wire.x, y: wire.y,
                                 chord: wire.chord, text: wire.text, lines: wire.lines, columns: wire.columns)
    }
}

/// input-result.json.
struct LocalInputResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case done, refused, failed, busy
    }

    let id: String?
    let status: Status
    var why: String? = nil
    var ms = 0

    private enum CodingKeys: String, CodingKey { case id, status, why, ms }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(why, forKey: .why)
        try container.encode(ms, forKey: .ms)
    }
}

/// What a local input request reads and drives on this Mac; tests replace it.
struct LocalInputMachine: Sendable {
    /// (Re)approves the broker session for this request; a session left idle expires.
    var beginRequest: @Sendable () async throws -> Void
    var execute: @Sendable (RemoteInputEvent) async throws -> Void
    var frontmostApplication: @Sendable () async -> String?
    var landsOnOriel: @Sendable (NormalizedPoint?) async -> Bool
    var displayBounds: @Sendable () async -> CGRect
    var hidePointer: @Sendable () async -> Void
}

/// Hands the Python toolkit's input through Oriel's own input pipeline, so Oriel's cursor is
/// visible when Hermes acts and the same guards apply. It reads input.json beside the goal
/// bridge's files and writes input-result.json. These are plain input primitives: the toolkit
/// already refuses sign-like labels on its side, so no approval policy runs here (see
/// docs/COMPATIBILITY.md).
@MainActor
final class LocalInputBridge {
    static var defaultDirectory: URL { LocalAssistantBridge.defaultDirectory }
    /// The pointer is hidden this long after the last action, so it stays visible through a chain.
    static let pointerIdleHide: Duration = .milliseconds(1_500)
    /// Between characters when typing, so a lookup field keeps up (the toolkit's type_keys gap).
    static let typingGap: Duration = .milliseconds(12)

    private let directory: URL
    private let pollInterval: Duration
    private let pointerIdleHide: Duration
    private let machine: LocalInputMachine
    private let goalRunActive: @MainActor () -> Bool
    private var pollTask: Task<Void, Never>?
    private var idleHideTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var lastInputFile: FileStamp?
    private var usedIDs: Set<String> = []
    private var active = false

    private var inputURL: URL { directory.appendingPathComponent("input.json") }
    private var resultURL: URL { directory.appendingPathComponent("input-result.json") }

    init(
        directory: URL,
        pollInterval: Duration = .milliseconds(50),
        pointerIdleHide: Duration = LocalInputBridge.pointerIdleHide,
        machine: LocalInputMachine,
        goalRunActive: @escaping @MainActor () -> Bool
    ) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.pointerIdleHide = pointerIdleHide
        self.machine = machine
        self.goalRunActive = goalRunActive
    }

    static func makeDefault(goalRunActive: @escaping @MainActor () -> Bool) -> LocalInputBridge {
        let displayID = CGMainDisplayID()
        let session = LocalInputSession(displayID: displayID)
        let machine = LocalInputMachine(
            beginRequest: { try await session.beginRequest() },
            execute: { event in try await session.execute(event) },
            frontmostApplication: { await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName } },
            landsOnOriel: { point in await OrielWindows.receiveInput(at: point, displayID: displayID) },
            displayBounds: { CGDisplayBounds(displayID) },
            hidePointer: { await session.hidePointer() }
        )
        return LocalInputBridge(directory: defaultDirectory, machine: machine, goalRunActive: goalRunActive)
    }

    var isRunning: Bool { active }

    func start() throws {
        guard pollTask == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A request written before the bridge started may be stale; only new ones run.
        lastInputFile = FileStamp(inputURL)
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        idleHideTask?.cancel()
        idleHideTask = nil
        runTask?.cancel()
        await runTask?.value
        await machine.hidePointer()
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
        guard let stamp = FileStamp(inputURL), stamp != lastInputFile else { return }
        lastInputFile = stamp
        guard let data = try? Data(contentsOf: inputURL) else { return }
        await accept(data)
    }

    private func accept(_ data: Data) async {
        let request: LocalInputRequest
        do {
            request = try LocalInputRequest.parse(data)
        } catch {
            let invalid = error as? LocalInputRequest.Invalid ?? .init(id: nil, why: String(describing: error))
            ActivityLog.shared.write(.input, "Local input refused: \(ActivityLogRedaction.scrub(invalid.why))")
            write(LocalInputResult(id: invalid.id, status: .refused, why: invalid.why))
            return
        }
        guard !usedIDs.contains(request.id) else { return }
        if active {
            write(LocalInputResult(id: request.id, status: .busy, why: "Another local input request is in progress."))
            ActivityLog.shared.write(.input, "Local input \(request.id.prefix(8)) (\(request.action.rawValue)): busy")
            return
        }
        usedIDs.insert(request.id)
        active = true
        idleHideTask?.cancel()
        idleHideTask = nil
        let start = ContinuousClock.now
        runTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.perform(request, start: start)
            self.write(result)
            ActivityLog.shared.write(.input, "Local input \(request.id.prefix(8)) (\(request.action.rawValue)): \(result.status.rawValue)"
                + (result.why.map { " (\(ActivityLogRedaction.scrub($0)))" } ?? ""))
            self.active = false
            if result.status == .done { self.schedulePointerHide() }
        }
    }

    private func perform(_ request: LocalInputRequest, start: ContinuousClock.Instant) async -> LocalInputResult {
        func elapsed() -> Int {
            let parts = start.duration(to: .now).components
            return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
        }
        func refused(_ why: String) -> LocalInputResult { LocalInputResult(id: request.id, status: .refused, why: why, ms: elapsed()) }

        // Something else is driving the Mac: a goal run, or another input request (checked in accept).
        if goalRunActive() { return LocalInputResult(id: request.id, status: .busy, why: "A goal run is in progress.", ms: elapsed()) }
        let frontmost = await machine.frontmostApplication()
        guard frontmost?.caseInsensitiveCompare(request.app) == .orderedSame else {
            return refused("\(request.app) is not in front (\(frontmost ?? "no app") is), so nothing was sent.")
        }

        // The events for this request, in order, and whether input lands in Oriel's own windows.
        let events: [RemoteInputEvent]
        let point: NormalizedPoint?
        do {
            switch request.action {
            case .click, .doubleClick, .rightClick, .scroll:
                let normalized = try self.normalized(request.x ?? 0, request.y ?? 0, in: await machine.displayBounds())
                point = normalized
                events = try Self.pointerEvents(request, at: normalized)
            case .key:
                point = nil
                events = [try Self.keyEvent(request)]
            case .type:
                point = nil
                events = []
            }
        } catch let error as LocalInputRequest.Invalid {
            return refused(error.why)
        } catch {
            return refused("the request could not be turned into input")
        }
        // Oriel's own windows stay off limits: a point on them, or keyboard input while Oriel is active.
        if await machine.landsOnOriel(point) {
            return refused("Oriel does not accept input into its own windows.")
        }

        do {
            try await machine.beginRequest()
            for event in events { try await machine.execute(event) }
            if request.action == .type { try await typeText(request.text ?? "") }
            return LocalInputResult(id: request.id, status: .done, ms: elapsed())
        } catch {
            return LocalInputResult(id: request.id, status: .failed, why: String(describing: error), ms: elapsed())
        }
    }

    /// One key down and up per character with real virtual key codes and shift (a Citrix lookup
    /// field ignores unicode-string key events); a character with no key code goes as a unicode
    /// event, and a newline as Return.
    private func typeText(_ text: String) async throws {
        for (index, character) in text.enumerated() {
            if index > 0 { try await Task.sleep(for: Self.typingGap) }
            if character == "\n" || character == "\r" {
                try await machine.execute(.key(code: 36, phase: .press, modifiers: []))
            } else if let stroke = LocalInputKeys.stroke(for: character) {
                try await machine.execute(.key(code: stroke.code, phase: .press, modifiers: stroke.shift ? [.shift] : []))
            } else {
                try await machine.execute(try RemoteInputEvent.text(String(character)))
            }
        }
    }

    private func normalized(_ x: Double, _ y: Double, in bounds: CGRect) throws -> NormalizedPoint {
        guard bounds.width > 0, bounds.height > 0 else { throw LocalInputRequest.Invalid(id: nil, why: "the display has no size") }
        let fractionX = (x - bounds.minX) / bounds.width
        let fractionY = (y - bounds.minY) / bounds.height
        guard (0...1).contains(fractionX), (0...1).contains(fractionY) else {
            throw LocalInputRequest.Invalid(id: nil, why: "the point (\(Int(x)), \(Int(y))) is off the display")
        }
        return try NormalizedPoint(x: fractionX, y: fractionY)
    }

    private static func pointerEvents(_ request: LocalInputRequest, at point: NormalizedPoint) throws -> [RemoteInputEvent] {
        switch request.action {
        case .click:
            return [.pointerMove(point), .mouseButton(.left, .click)]
        case .doubleClick:
            return [.pointerMove(point), .mouseButton(.left, .doubleClick)]
        case .rightClick:
            return [.pointerMove(point), .mouseButton(.right, .click)]
        case .scroll:
            // Oriel's wheel is in pixels; the toolkit's lines are positive-down (negative deltaY)
            // and its columns positive-right (positive deltaX).
            func clamp(_ value: Double) -> Double { max(-1_000, min(1_000, value)) }
            let deltaY = clamp(-(request.lines ?? 0) * Double(Self.pixelsPerLine))
            let deltaX = clamp((request.columns ?? 0) * Double(Self.pixelsPerLine))
            return [.pointerMove(point), try RemoteInputEvent.scroll(deltaX: deltaX, deltaY: deltaY)]
        case .key, .type:
            return []
        }
    }

    private static func keyEvent(_ request: LocalInputRequest) throws -> RemoteInputEvent {
        guard let chord = request.chord, let stroke = LocalInputKeys.chord(chord) else {
            throw LocalInputRequest.Invalid(id: request.id, why: "\"chord\" has an unknown key")
        }
        return .key(code: stroke.code, phase: .press, modifiers: stroke.modifiers)
    }

    /// A line of the toolkit's scroll is this many pixels of Oriel's wheel.
    static let pixelsPerLine = 16

    private func schedulePointerHide() {
        idleHideTask?.cancel()
        idleHideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.pointerIdleHide)
            guard !Task.isCancelled else { return }
            await self.machine.hidePointer()
        }
    }

    private func write(_ result: LocalInputResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(result).write(to: resultURL, options: .atomic)
        } catch {
            NSLog("Oriel could not write the local input result: %@", String(describing: error))
        }
    }
}

/// US-layout key strokes for the toolkit's input: chords for the key action, and the single
/// keystroke (code plus shift) for a character when typing.
enum LocalInputKeys {
    struct Stroke: Equatable {
        let code: UInt16
        let shift: Bool
    }

    struct Chord: Equatable {
        let code: UInt16
        let modifiers: Set<KeyModifier>
    }

    /// A chord like "cmd+f", "return" or "pagedown": the last token is the key, the rest are
    /// modifiers; nil when the key is not one Oriel knows.
    static func chord(_ text: String) -> Chord? {
        let tokens = text.split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = tokens.last else { return nil }
        guard let code = AgentKeyName.keyCode(for: keyName) else { return nil }
        var modifiers = Set<KeyModifier>()
        for token in tokens.dropLast() {
            guard let modifier = modifier(named: token) else { return nil }
            modifiers.insert(modifier)
        }
        return Chord(code: code, modifiers: modifiers)
    }

    static func modifier(named name: String) -> KeyModifier? {
        switch name.lowercased() {
        case "cmd", "command", "meta", "super": return .command
        case "alt", "option", "opt": return .option
        case "ctrl", "control": return .control
        case "shift": return .shift
        case "fn", "function": return .function
        default: return nil
        }
    }

    static func stroke(for character: Character) -> Stroke? {
        table[character]
    }

    private static let table: [Character: Stroke] = {
        var table: [Character: Stroke] = [:]
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (character, code) in letters {
            table[character] = Stroke(code: code, shift: false)
            table[Character(character.uppercased())] = Stroke(code: code, shift: true)
        }
        // digit: (code, the character its Shift types)
        let digits: [(Character, UInt16, Character)] = [
            ("1", 18, "!"), ("2", 19, "@"), ("3", 20, "#"), ("4", 21, "$"), ("5", 23, "%"),
            ("6", 22, "^"), ("7", 26, "&"), ("8", 28, "*"), ("9", 25, "("), ("0", 29, ")"),
        ]
        for (character, code, shifted) in digits {
            table[character] = Stroke(code: code, shift: false)
            table[shifted] = Stroke(code: code, shift: true)
        }
        // symbol: (unshifted, code, shifted)
        let symbols: [(Character, UInt16, Character)] = [
            ("-", 27, "_"), ("=", 24, "+"), ("[", 33, "{"), ("]", 30, "}"), ("\\", 42, "|"),
            (";", 41, ":"), ("'", 39, "\""), (",", 43, "<"), (".", 47, ">"), ("/", 44, "?"),
            ("`", 50, "~"),
        ]
        for (character, code, shifted) in symbols {
            table[character] = Stroke(code: code, shift: false)
            table[shifted] = Stroke(code: code, shift: true)
        }
        table[" "] = Stroke(code: 49, shift: false)
        table["\t"] = Stroke(code: 48, shift: false)
        return table
    }()
}

/// The input broker for the local input bridge, re-approved for each request so an idle
/// session does not expire between Hermes's chains.
actor LocalInputSession {
    private let broker = InputBroker()
    private let displayID: CGDirectDisplayID
    private let sessionID = "local-input-bridge"

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func beginRequest() async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let capabilities: Set<SessionCapability> = [.controlPointer, .typeText]
        await broker.resumeAcceptingNewSessions()
        await broker.register(SessionApprovalRequest(
            sessionID: sessionID, deviceID: "local-input-bridge", deviceName: "Local input bridge",
            requestedCapabilities: capabilities, expiresAtNanoseconds: now + 60 * 60 * 1_000_000_000
        ))
        try await broker.approve(sessionID: sessionID, capabilities: capabilities, nowNanoseconds: now)
    }

    func execute(_ event: RemoteInputEvent) async throws {
        try await broker.execute(event, sessionID: sessionID, nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                 displayID: displayID)
    }

    func hidePointer() async {
        await MainActor.run { OrielPointer.shared.hide() }
    }
}
