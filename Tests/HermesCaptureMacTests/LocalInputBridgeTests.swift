import CoreGraphics
import Foundation
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

/// The local input bridge through input.json: malformed and wrong-app refusals with nothing
/// sent, a click reaching the broker at the right point, busy while a goal or another request
/// runs, the result written atomically, and the pointer hidden after the idle timer. No
/// hardware, no network.
@MainActor
struct LocalInputBridgeTests {
    struct TimedOut: Error {}

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var executed: [RemoteInputEvent] = []
        private(set) var begins = 0
        private(set) var hides = 0
        private var slow: Duration?

        init(slow: Duration? = nil) { self.slow = slow }

        func begin() { lock.withLock { begins += 1 } }
        func execute(_ event: RemoteInputEvent) async {
            let pause = lock.withLock { () -> Duration? in executed.append(event); return slow }
            if let pause { try? await Task.sleep(for: pause) }
        }
        func hide() { lock.withLock { hides += 1 } }
        var events: [RemoteInputEvent] { lock.withLock { executed } }
        var beginCount: Int { lock.withLock { begins } }
        var hideCount: Int { lock.withLock { hides } }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let recorder: Recorder
        var frontmost: String?
        var orielAt: Bool
        var goalActive: Bool
        var bridge: LocalInputBridge!

        init(frontmost: String? = "Citrix Viewer", orielAt: Bool = false, goalActive: Bool = false,
             slow: Duration? = nil, idleHide: Duration = .milliseconds(1_500)) {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("oriel-input-bridge-\(UUID().uuidString)", isDirectory: true)
            recorder = Recorder(slow: slow)
            self.frontmost = frontmost
            self.orielAt = orielAt
            self.goalActive = goalActive
            let recorder = self.recorder
            let machine = LocalInputMachine(
                beginRequest: { recorder.begin() },
                execute: { await recorder.execute($0) },
                frontmostApplication: { [weak self] in await MainActor.run { self?.frontmost } },
                landsOnOriel: { [weak self] _ in await MainActor.run { self?.orielAt ?? false } },
                displayBounds: { CGRect(x: 0, y: 0, width: 1_000, height: 1_000) },
                hidePointer: { recorder.hide() }
            )
            bridge = LocalInputBridge(directory: directory, pollInterval: .milliseconds(10), pointerIdleHide: idleHide,
                                      machine: machine, goalRunActive: { [weak self] in self?.goalActive ?? false })
        }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func write(_ json: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url("input.json"), options: .atomic)
        }
        func cleanup() async {
            await bridge?.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func result(_ fixture: Fixture, id: String?, timeout: Duration = .seconds(5)) async throws -> LocalInputResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: fixture.url("input-result.json")),
               let result = try? JSONDecoder().decode(LocalInputResult.self, from: data), result.id == id {
                return result
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut()
    }

    // MARK: Parsing

    @Test func requestsAreValidated() throws {
        let click = try LocalInputRequest.parse(Data(#"{"id":"r1","action":"click","app":"Citrix Viewer","x":12,"y":34}"#.utf8))
        #expect(click.action == .click && click.app == "Citrix Viewer" && click.x == 12 && click.y == 34)

        func invalid(_ json: String) -> LocalInputRequest.Invalid? {
            do { _ = try LocalInputRequest.parse(Data(json.utf8)); return nil } catch { return error as? LocalInputRequest.Invalid }
        }
        #expect(invalid(#"{"action":"click","app":"A","x":1,"y":2}"#)?.id == nil, "No id")
        #expect(invalid(#"{"id":"r","action":"fly","app":"A"}"#)?.why.contains("\"action\"") == true)
        #expect(invalid(#"{"id":"r","action":"click","x":1,"y":2}"#)?.why.contains("\"app\"") == true)
        #expect(invalid(#"{"id":"r","action":"click","app":"A","x":1}"#)?.why.contains("\"x\" and \"y\"") == true)
        #expect(invalid(#"{"id":"r","action":"scroll","app":"A","x":1,"y":2}"#)?.why.contains("\"lines\" or \"columns\"") == true)
        #expect(invalid(#"{"id":"r","action":"key","app":"A","chord":"cmd+zzz"}"#)?.why.contains("unknown key") == true)
        #expect(invalid(#"{"id":"r","action":"type","app":"A","text":""}"#)?.why.contains("\"text\"") == true)
        #expect(invalid("not json")?.id == nil)
    }

    @Test func chordsAndStrokesMapToKeyCodes() {
        #expect(LocalInputKeys.chord("return")?.code == 36 && LocalInputKeys.chord("return")?.modifiers.isEmpty == true)
        #expect(LocalInputKeys.chord("pagedown")?.code == 121)
        #expect(LocalInputKeys.chord("cmd+f") == .init(code: 3, modifiers: [.command]))
        #expect(LocalInputKeys.chord("cmd+shift+a") == .init(code: 0, modifiers: [.command, .shift]))
        #expect(LocalInputKeys.chord("cmd+zzz") == nil)
        #expect(LocalInputKeys.stroke(for: "a") == .init(code: 0, shift: false))
        #expect(LocalInputKeys.stroke(for: "A") == .init(code: 0, shift: true))
        #expect(LocalInputKeys.stroke(for: "!") == .init(code: 18, shift: true))
        #expect(LocalInputKeys.stroke(for: " ") == .init(code: 49, shift: false))
        #expect(LocalInputKeys.stroke(for: "é") == nil, "No key code; typed as a unicode event")
    }

    // MARK: Refusals, with nothing sent

    @Test func aMalformedRequestIsRefused() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write("not json")
        let reported = try await result(fixture, id: nil)
        #expect(reported.status == .refused && reported.id == nil)
        #expect(fixture.recorder.events.isEmpty && fixture.recorder.beginCount == 0)
        await fixture.cleanup()
    }

    @Test func aRequestForAnAppThatIsNotFrontmostIsRefusedWithNothingSent() async throws {
        let fixture = Fixture(frontmost: "Finder")
        try fixture.bridge.start()
        try fixture.write(#"{"id":"wrong-app","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        let reported = try await result(fixture, id: "wrong-app")
        #expect(reported.status == .refused && reported.why == "Citrix Viewer is not in front (Finder is), so nothing was sent.")
        #expect(fixture.recorder.events.isEmpty && fixture.recorder.beginCount == 0)
        await fixture.cleanup()
    }

    @Test func inputIntoOrielsOwnWindowsIsRefused() async throws {
        let fixture = Fixture(orielAt: true)
        try fixture.bridge.start()
        try fixture.write(#"{"id":"oriel","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        let reported = try await result(fixture, id: "oriel")
        #expect(reported.status == .refused && reported.why?.contains("its own windows") == true)
        #expect(fixture.recorder.events.isEmpty)
        await fixture.cleanup()
    }

    @Test func aPointOffTheDisplayIsRefused() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write(#"{"id":"far","action":"click","app":"Citrix Viewer","x":5000,"y":250}"#)
        let reported = try await result(fixture, id: "far")
        #expect(reported.status == .refused && reported.why?.contains("off the display") == true)
        #expect(fixture.recorder.events.isEmpty)
        await fixture.cleanup()
    }

    // MARK: Performing

    @Test func aClickGoesToTheBrokerAtTheRightPoint() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write(#"{"id":"c1","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        let reported = try await result(fixture, id: "c1")
        #expect(reported.status == .done && reported.ms >= 0)
        #expect(fixture.recorder.beginCount == 1)
        let events = fixture.recorder.events
        #expect(events.count == 2)
        if case let .pointerMove(point) = events.first {
            #expect(abs(point.x - 0.5) < 0.0001 && abs(point.y - 0.25) < 0.0001)
        } else {
            Issue.record("first event is not a pointer move")
        }
        #expect(events.last == .mouseButton(.left, .click))
        await fixture.cleanup()
    }

    @Test func typingSendsKeyStrokesNotUnicodeForAsciiAndReturnForNewline() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write(#"{"id":"t1","action":"type","app":"Citrix Viewer","text":"Hi!\n"}"#)
        let reported = try await result(fixture, id: "t1")
        #expect(reported.status == .done)
        let events = fixture.recorder.events
        #expect(events == [
            .key(code: 4, phase: .press, modifiers: [.shift]),   // H
            .key(code: 34, phase: .press, modifiers: []),        // i
            .key(code: 18, phase: .press, modifiers: [.shift]),  // !
            .key(code: 36, phase: .press, modifiers: []),        // newline -> return
        ])
        await fixture.cleanup()
    }

    @Test func aScrollMovesToThePointAndScrollsDownForPositiveLines() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write(#"{"id":"s1","action":"scroll","app":"Citrix Viewer","x":500,"y":500,"lines":3}"#)
        let reported = try await result(fixture, id: "s1")
        #expect(reported.status == .done)
        let events = fixture.recorder.events
        #expect(events.count == 2)
        if case let .scrollDelta(x, y) = events.last {
            #expect(x == 0 && y < 0, "positive lines scroll down, which is a negative wheel delta")
        } else {
            Issue.record("last event is not a scroll")
        }
        await fixture.cleanup()
    }

    @Test func aScrollWithColumnsScrollsRightWithNoVerticalMovement() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write(#"{"id":"s2","action":"scroll","app":"Citrix Viewer","x":500,"y":500,"lines":0,"columns":2}"#)
        let reported = try await result(fixture, id: "s2")
        #expect(reported.status == .done)
        if case let .scrollDelta(x, y) = fixture.recorder.events.last {
            #expect(y == 0 && x > 0, "positive columns scroll right with no vertical movement")
        } else {
            Issue.record("last event is not a scroll")
        }
        await fixture.cleanup()
    }

    @Test func aKeyChordGoesToTheBroker() async throws {
        let fixture = Fixture()
        try fixture.bridge.start()
        try fixture.write(#"{"id":"k1","action":"key","app":"Citrix Viewer","chord":"cmd+f"}"#)
        let reported = try await result(fixture, id: "k1")
        #expect(reported.status == .done)
        #expect(fixture.recorder.events == [.key(code: 3, phase: .press, modifiers: [.command])])
        await fixture.cleanup()
    }

    // MARK: Busy and lifecycle

    @Test func aRequestWhileAGoalRunsIsBusy() async throws {
        let fixture = Fixture(goalActive: true)
        try fixture.bridge.start()
        try fixture.write(#"{"id":"during-goal","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        let reported = try await result(fixture, id: "during-goal")
        #expect(reported.status == .busy && reported.why == "A goal run is in progress.")
        #expect(fixture.recorder.events.isEmpty)
        await fixture.cleanup()
    }

    @Test func aSecondRequestWhileOneRunsIsBusy() async throws {
        let fixture = Fixture(slow: .milliseconds(400))
        try fixture.bridge.start()
        try fixture.write(#"{"id":"first","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        for _ in 0..<200 where !fixture.bridge.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fixture.bridge.isRunning)
        try fixture.write(#"{"id":"second","action":"click","app":"Citrix Viewer","x":100,"y":100}"#)
        let busy = try await result(fixture, id: "second")
        #expect(busy.status == .busy && busy.why == "Another local input request is in progress.")
        await fixture.cleanup()
    }

    @Test func theResultIsReplacedNotRewrittenInPlace() async throws {
        let fixture = Fixture()
        try fixture.write("placeholder")
        try fixture.bridge.start()
        let resultURL = fixture.url("input-result.json")
        try Data("old".utf8).write(to: resultURL)
        let before = fixture.url("result-before")
        try FileManager.default.linkItem(at: resultURL, to: before)
        let inode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int }
        let oldInode = try inode(resultURL)
        try fixture.write("not json either")
        let reported = try await result(fixture, id: nil)
        #expect(reported.status == .refused)
        #expect(try String(contentsOf: before, encoding: .utf8) == "old", "A reader of the old file never sees the new one half written")
        #expect(try inode(resultURL) != oldInode)
        await fixture.cleanup()
    }

    @Test func thePointerIsHiddenAfterTheIdleTimer() async throws {
        let fixture = Fixture(idleHide: .milliseconds(80))
        try fixture.bridge.start()
        try fixture.write(#"{"id":"hide","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        let reported = try await result(fixture, id: "hide")
        #expect(reported.status == .done)
        #expect(fixture.recorder.hideCount == 0, "Still visible right after the action")
        for _ in 0..<100 where fixture.recorder.hideCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.recorder.hideCount >= 1, "Hidden once the idle timer fires")
        await fixture.cleanup()
    }

    @Test func aRequestLeftFromBeforeTheBridgeStartedDoesNotRun() async throws {
        let fixture = Fixture()
        try fixture.write(#"{"id":"stale","action":"click","app":"Citrix Viewer","x":500,"y":250}"#)
        try fixture.bridge.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("input-result.json").path))
        #expect(fixture.recorder.events.isEmpty)
        await fixture.cleanup()
    }
}
