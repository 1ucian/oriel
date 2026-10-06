import Foundation

public enum InputProtocolError: Error, Equatable, Sendable {
    case invalidCoordinate
    case invalidScrollDelta
    case textTooLarge
    case invalidText
    case unsupportedEventType
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite,
              (0...1).contains(x),
              (0...1).contains(y) else {
            throw InputProtocolError.invalidCoordinate
        }
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case center
}

public enum ButtonPhase: String, Codable, Sendable {
    case down
    case up
    case click
    case doubleClick
}

public enum KeyPhase: String, Codable, Sendable {
    case down
    case up
    case press
}

public enum KeyModifier: String, Codable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
    case function
}

public enum RemoteInputEvent: Equatable, Sendable {
    case pointerMove(NormalizedPoint)
    case mouseButton(MouseButton, ButtonPhase)
    case scrollDelta(x: Double, y: Double)
    case key(code: UInt16, phase: KeyPhase, modifiers: Set<KeyModifier>)
    case textInput(String)

    public static func scroll(
        deltaX: Double,
        deltaY: Double
    ) throws -> Self {
        guard deltaX.isFinite,
              deltaY.isFinite,
              abs(deltaX) <= 1_000,
              abs(deltaY) <= 1_000 else {
            throw InputProtocolError.invalidScrollDelta
        }
        return .scrollDelta(x: deltaX, y: deltaY)
    }

    public static func text(_ value: String) throws -> Self {
        guard value.utf8.count <= 4_096 else {
            throw InputProtocolError.textTooLarge
        }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw InputProtocolError.invalidText
        }
        return .textInput(value)
    }
}

extension RemoteInputEvent: Codable {
    private enum EventType: String, Codable {
        case pointerMove
        case mouseButton
        case scroll
        case key
        case text
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case point
        case button
        case phase
        case deltaX
        case deltaY
        case keyCode
        case modifiers
        case text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try? container.decode(EventType.self, forKey: .type) else {
            throw InputProtocolError.unsupportedEventType
        }

        switch type {
        case .pointerMove:
            self = .pointerMove(
                try container.decode(NormalizedPoint.self, forKey: .point)
            )
        case .mouseButton:
            self = .mouseButton(
                try container.decode(MouseButton.self, forKey: .button),
                try container.decode(ButtonPhase.self, forKey: .phase)
            )
        case .scroll:
            self = try .scroll(
                deltaX: container.decode(Double.self, forKey: .deltaX),
                deltaY: container.decode(Double.self, forKey: .deltaY)
            )
        case .key:
            self = .key(
                code: try container.decode(UInt16.self, forKey: .keyCode),
                phase: try container.decode(KeyPhase.self, forKey: .phase),
                modifiers: try container.decode(Set<KeyModifier>.self, forKey: .modifiers)
            )
        case .text:
            self = try .text(container.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .pointerMove(point):
            try container.encode(EventType.pointerMove, forKey: .type)
            try container.encode(point, forKey: .point)
        case let .mouseButton(button, phase):
            try container.encode(EventType.mouseButton, forKey: .type)
            try container.encode(button, forKey: .button)
            try container.encode(phase, forKey: .phase)
        case let .scrollDelta(x, y):
            try container.encode(EventType.scroll, forKey: .type)
            try container.encode(x, forKey: .deltaX)
            try container.encode(y, forKey: .deltaY)
        case let .key(code, phase, modifiers):
            try container.encode(EventType.key, forKey: .type)
            try container.encode(code, forKey: .keyCode)
            try container.encode(phase, forKey: .phase)
            try container.encode(modifiers, forKey: .modifiers)
        case let .textInput(text):
            try container.encode(EventType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}
