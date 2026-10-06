import Foundation
import Testing
@testable import HermesCaptureProtocol

struct RemoteInputEventTests {
    @Test func pointerMoveRoundTrips() throws {
        let event = RemoteInputEvent.pointerMove(
            try NormalizedPoint(x: 0.25, y: 0.75)
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RemoteInputEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func normalizedPointRejectsOutOfBoundsCoordinates() {
        #expect(throws: InputProtocolError.invalidCoordinate) {
            try NormalizedPoint(x: 1.01, y: 0.5)
        }
        #expect(throws: InputProtocolError.invalidCoordinate) {
            try NormalizedPoint(x: .nan, y: 0.5)
        }
    }

    @Test func oversizedTextIsRejected() {
        #expect(throws: InputProtocolError.textTooLarge) {
            try RemoteInputEvent.text(String(repeating: "a", count: 4_097))
        }
    }

    @Test func excessiveScrollDeltaIsRejected() {
        #expect(throws: InputProtocolError.invalidScrollDelta) {
            try RemoteInputEvent.scroll(deltaX: 0, deltaY: 1_001)
        }
    }

    @Test func unknownEventTypeFailsClosed() {
        let data = Data(#"{"type":"shell","text":"whoami"}"#.utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RemoteInputEvent.self, from: data)
        }
    }

    @Test func boundedTextRoundTrips() throws {
        let event = try RemoteInputEvent.text("Open Notes")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RemoteInputEvent.self, from: data)

        #expect(decoded == event)
    }
}
