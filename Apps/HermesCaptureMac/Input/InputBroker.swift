import ApplicationServices
import CoreGraphics
import Foundation
import HermesCaptureProtocol

actor InputBroker {
    enum BrokerError: Error {
        case accessibilityPermissionDenied
        case displayUnavailable
        case eventCreationFailed
    }

    private let source = CGEventSource(stateID: .hidSystemState)
    private var sessionPolicy = RemoteSessionPolicy()
    /// Oriel's own pointer position: remote moves land here, not on the system pointer.
    private var virtualPosition: CGPoint?
    /// A button held through a drag, with the system pointer borrowed until it is released.
    private var heldButton: (button: CGMouseButton, dragType: CGEventType, upType: CGEventType, start: CGPoint)?
    private var restoreAfterDrag: CGPoint?
    /// How many times Stop Control cut input off: a text being typed stops when this changes.
    private var stops = 0

    /// What a text being typed checks between two characters.
    struct TypingTicket: Equatable {
        let deviceID: String?
        let stops: Int
    }

    func register(_ request: SessionApprovalRequest) {
        sessionPolicy.register(request)
    }

    func approve(
        sessionID: String,
        capabilities: Set<SessionCapability>,
        nowNanoseconds: UInt64
    ) throws {
        try sessionPolicy.approve(
            sessionID: sessionID,
            capabilities: capabilities,
            nowNanoseconds: nowNanoseconds
        )
    }

    /// Every session's input approval ends. Text being typed stops at the next character, and a
    /// button held mid-drag goes back to where the drag began and is let go there. With
    /// `keepingRunInput` (the same phone is back while its run goes on) only the approvals end:
    /// what the run is typing or dragging carries on under the phone's new session.
    func stopControl(keepingRunInput: Bool = false) {
        sessionPolicy.stopControl()
        if keepingRunInput {
            heldButton = nil
            restoreAfterDrag = nil
        } else {
            stops &+= 1
            releaseHeldButton()
        }
        virtualPosition = nil
    }

    func resumeAcceptingNewSessions() {
        sessionPolicy.resumeAcceptingNewSessions()
    }

    /// The device's sessions lose their approval now, and it registers no new ones until the
    /// owner approves it again (`readmit`).
    func revoke(deviceID: String) {
        let hadSession = sessionPolicy.activeSessions.contains { $0.request.deviceID == deviceID }
        sessionPolicy.revoke(deviceID: deviceID)
        if hadSession { releaseHeldButton() }
    }

    func readmit(deviceID: String) {
        sessionPolicy.readmit(deviceID: deviceID)
    }

    func typingTicket(sessionID: String) -> TypingTicket {
        TypingTicket(deviceID: sessionPolicy.approvedSession(id: sessionID)?.request.deviceID, stops: stops)
    }

    /// Why a text being typed must stop before its next character: Stop Control, or a revoke of
    /// the device typing it. Nil while it may go on.
    func typingStopReason(_ ticket: TypingTicket) -> SessionPolicyError? {
        if ticket.stops != stops { return .killSwitchActive }
        if let deviceID = ticket.deviceID, sessionPolicy.revokedDeviceIDs.contains(deviceID) {
            return .deviceRevoked
        }
        return nil
    }

    func execute(
        _ event: RemoteInputEvent,
        sessionID: String,
        nowNanoseconds: UInt64,
        displayID: CGDirectDisplayID
    ) async throws {
        // Authorization runs before permission checks or CGEvent creation, so a denied
        // session cannot reach the input-injection path.
        try sessionPolicy.authorize(
            event,
            sessionID: sessionID,
            nowNanoseconds: nowNanoseconds
        )
        guard AXIsProcessTrusted() else {
            throw BrokerError.accessibilityPermissionDenied
        }

        switch event {
        case let .pointerMove(point):
            let target = try displayPoint(point, displayID: displayID)
            virtualPosition = target
            if let held = heldButton {
                // Mid-drag the system pointer follows, so the drag lands.
                try postMouseEvent(type: held.dragType, button: held.button, position: target)
            }
            await MainActor.run { OrielPointer.shared.move(to: target, display: displayID) }
        case let .mouseButton(button, phase):
            try postButton(button, phase: phase)
            if phase == .click || phase == .doubleClick {
                await MainActor.run { OrielPointer.shared.pulse() }
            }
        case let .scrollDelta(x, y):
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(y.rounded())),
                wheel2: Int32(clamping: Int(x.rounded())),
                wheel3: 0
            ) else {
                throw BrokerError.eventCreationFailed
            }
            // Scrolling goes to the window under the system pointer: borrow it briefly.
            let prior = try currentPointerLocation()
            if let target = virtualPosition {
                try postMouseEvent(type: .mouseMoved, button: .left, position: target)
            }
            event.post(tap: .cghidEventTap)
            if let target = virtualPosition { restorePointer(to: prior, from: target) }
        case let .key(code, phase, modifiers):
            try postKey(
                code: CGKeyCode(code),
                phase: phase,
                modifiers: modifiers
            )
        case let .textInput(text):
            try await postText(text, sessionID: sessionID)
        }
    }

    private func displayPoint(
        _ point: NormalizedPoint,
        displayID: CGDirectDisplayID
    ) throws -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else {
            throw BrokerError.displayUnavailable
        }
        return CGPoint(
            x: bounds.minX + bounds.width * point.x,
            y: bounds.minY + bounds.height * point.y
        )
    }

    /// A button held down mid-drag by input that just ended goes back to where the drag began and
    /// is let go there, so the drag drops nowhere new and no button stays down that nobody holds.
    private func releaseHeldButton() {
        defer {
            heldButton = nil
            restoreAfterDrag = nil
        }
        guard let held = heldButton else { return }
        try? postMouseEvent(type: held.dragType, button: held.button, position: held.start)
        try? postMouseEvent(type: held.upType, button: held.button, position: held.start)
        if let back = restoreAfterDrag { restorePointer(to: back, from: held.start) }
    }

    /// Put the system pointer back where the owner had it, unless the two already coincide.
    /// Posted as a move event so it is processed after the click events queued before it; a
    /// bare warp would run first and the click would drag the pointer back out.
    private func restorePointer(to prior: CGPoint, from target: CGPoint) {
        guard abs(prior.x - target.x) > 2 || abs(prior.y - target.y) > 2 else { return }
        try? postMouseEvent(type: .mouseMoved, button: .left, position: prior)
    }

    private func currentPointerLocation() throws -> CGPoint {
        guard let event = CGEvent(source: source) else {
            throw BrokerError.eventCreationFailed
        }
        return event.location
    }

    private func postButton(
        _ button: MouseButton,
        phase: ButtonPhase
    ) throws {
        let prior = try currentPointerLocation()
        let location = virtualPosition ?? prior
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton)
        switch button {
        case .left:
            (downType, upType, cgButton) = (.leftMouseDown, .leftMouseUp, .left)
        case .right:
            (downType, upType, cgButton) = (.rightMouseDown, .rightMouseUp, .right)
        case .center:
            (downType, upType, cgButton) = (.otherMouseDown, .otherMouseUp, .center)
        }

        let dragType: CGEventType
        switch button {
        case .left: dragType = .leftMouseDragged
        case .right: dragType = .rightMouseDragged
        case .center: dragType = .otherMouseDragged
        }
        switch phase {
        case .down:
            // The system pointer is borrowed for the whole drag and returned on release.
            restoreAfterDrag = prior
            try postMouseEvent(type: .mouseMoved, button: cgButton, position: location)
            try postMouseEvent(type: downType, button: cgButton, position: location)
            heldButton = (cgButton, dragType, upType, location)
        case .up:
            try postMouseEvent(type: upType, button: cgButton, position: location)
            heldButton = nil
            if let back = restoreAfterDrag { restorePointer(to: back, from: location) }
            restoreAfterDrag = nil
        case .click:
            try postMouseEvent(type: .mouseMoved, button: cgButton, position: location)
            try postClick(
                downType: downType,
                upType: upType,
                button: cgButton,
                position: location,
                clickCount: 1
            )
            restorePointer(to: prior, from: location)
        case .doubleClick:
            try postMouseEvent(type: .mouseMoved, button: cgButton, position: location)
            try postClick(
                downType: downType,
                upType: upType,
                button: cgButton,
                position: location,
                clickCount: 2
            )
            restorePointer(to: prior, from: location)
        }
    }

    private func postClick(
        downType: CGEventType,
        upType: CGEventType,
        button: CGMouseButton,
        position: CGPoint,
        clickCount: Int64
    ) throws {
        for clickIndex in 1...clickCount {
            let down = try mouseEvent(
                type: downType,
                button: button,
                position: position
            )
            let up = try mouseEvent(
                type: upType,
                button: button,
                position: position
            )
            down.setIntegerValueField(.mouseEventClickState, value: clickIndex)
            up.setIntegerValueField(.mouseEventClickState, value: clickIndex)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postMouseEvent(
        type: CGEventType,
        button: CGMouseButton,
        position: CGPoint
    ) throws {
        try mouseEvent(type: type, button: button, position: position)
            .post(tap: .cghidEventTap)
    }

    private func mouseEvent(
        type: CGEventType,
        button: CGMouseButton,
        position: CGPoint
    ) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: button
        ) else {
            throw BrokerError.eventCreationFailed
        }
        return event
    }

    private func postKey(
        code: CGKeyCode,
        phase: KeyPhase,
        modifiers: Set<KeyModifier>
    ) throws {
        switch phase {
        case .down:
            try keyEvent(code: code, isDown: true, modifiers: modifiers)
                .post(tap: .cghidEventTap)
        case .up:
            try keyEvent(code: code, isDown: false, modifiers: modifiers)
                .post(tap: .cghidEventTap)
        case .press:
            // Like a keyboard: modifier keys go down first and come up last. Slack ignored a
            // Command+K whose Command existed only as a flag on the K events.
            let held = Self.modifierKeys.filter { modifiers.contains($0.modifier) }
            var flags: CGEventFlags = []
            for key in held {
                flags.insert(key.flag)
                try keyEvent(code: key.code, isDown: true, flags: flags).post(tap: .cghidEventTap)
            }
            try keyEvent(code: code, isDown: true, flags: flags).post(tap: .cghidEventTap)
            try keyEvent(code: code, isDown: false, flags: flags).post(tap: .cghidEventTap)
            for key in held.reversed() {
                flags.remove(key.flag)
                try keyEvent(code: key.code, isDown: false, flags: flags).post(tap: .cghidEventTap)
            }
        }
    }

    /// The modifier keys, in the order a hand presses them.
    private static let modifierKeys: [(modifier: KeyModifier, code: CGKeyCode, flag: CGEventFlags)] = [
        (.command, 55, .maskCommand), (.shift, 56, .maskShift), (.option, 58, .maskAlternate),
        (.control, 59, .maskControl), (.function, 63, .maskSecondaryFn),
    ]

    private func keyEvent(code: CGKeyCode, isDown: Bool, flags: CGEventFlags) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else {
            throw BrokerError.eventCreationFailed
        }
        event.flags = flags
        return event
    }

    private func keyEvent(
        code: CGKeyCode,
        isDown: Bool,
        modifiers: Set<KeyModifier>
    ) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: code,
            keyDown: isDown
        ) else {
            throw BrokerError.eventCreationFailed
        }
        event.flags = eventFlags(for: modifiers)
        return event
    }

    /// One key down and one key up per character, the character set on both. A lone key down
    /// carrying the whole string reached Slack's message box but not its jump box (Chromium
    /// text inputs ignore it), so typing a name there opened whatever was listed first.
    private func postText(_ text: String, sessionID: String) async throws {
        let ticket = typingTicket(sessionID: sessionID)
        for character in text {
            // Stop Control or a revoke ends typing between two characters, not after the text.
            if let reason = typingStopReason(ticket) { throw reason }
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: isDown
                ) else {
                    throw BrokerError.eventCreationFailed
                }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func eventFlags(
        for modifiers: Set<KeyModifier>
    ) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
