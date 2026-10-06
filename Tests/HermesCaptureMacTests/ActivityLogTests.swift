import Foundation
import HermesCaptureProtocol
import Testing
@testable import HermesCaptureMac

struct ActivityLogTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func set(_ date: Date) { lock.withLock { value = date } }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-log-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test func linesCarryTimeCategoryAndOneLineMessage() {
        let line = ActivityLog.line(
            .session, "Session ended:\nno heartbeat", at: Self.date("2026-10-05T15:56:17.715Z"), calendar: Self.utc
        )
        #expect(line == "2026-10-05 15:56:17.715 [session] Session ended: no heartbeat\n")
    }

    @Test func writesOneFilePerDayKeepsSevenDaysAndIsPrivate() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Two stale days and one inside the window, as an earlier run would have left them.
        for day in ["2026-09-20", "2026-09-28", "2026-09-30"] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("\(ActivityLog.filePrefix)\(day).log").path,
                contents: Data("old\n".utf8)
            )
        }
        let clock = Clock(Self.date("2026-10-05T23:59:59Z"))
        let log = ActivityLog(directory: directory, now: { clock.now }, calendar: Self.utc)

        log.write(.app, "first")
        log.write(.relay, "second")
        clock.set(Self.date("2026-10-06T00:00:01Z"))
        log.write(.app, "next day")
        log.flush()

        let names = log.logFiles().map(\.lastPathComponent)
        #expect(names == [
            "oriel-activity-2026-09-30.log",
            "oriel-activity-2026-10-05.log",
            "oriel-activity-2026-10-06.log",
        ])
        #expect(try Self.lines(log.logFiles()[1]) == [
            "2026-10-05 23:59:59.000 [app] first",
            "2026-10-05 23:59:59.000 [relay] second",
        ])
        #expect(try Self.lines(log.logFiles()[2]) == ["2026-10-06 00:00:01.000 [app] next day"])
        let attributes = try FileManager.default.attributesOfItem(atPath: log.logFiles()[2].path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aFullDayWritesOneNoticeAndDropsTheRestUntilTomorrow() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(Self.date("2026-10-05T10:00:00Z"))
        let log = ActivityLog(directory: directory, maximumBytesPerDay: 120, now: { clock.now }, calendar: Self.utc)

        for index in 0..<10 { log.write(.assistant, "line \(index)") }
        clock.set(Self.date("2026-10-06T10:00:00Z"))
        log.write(.assistant, "tomorrow")
        log.flush()

        let today = try Self.lines(log.logFiles()[0])
        #expect(today.count < 10)
        #expect(today.last?.contains("The log is full for today") == true)
        #expect(try Self.lines(log.logFiles()[1]) == ["2026-10-06 10:00:00.000 [assistant] tomorrow"])
    }

    @Test func deleteAllRemovesTheFilesAndLoggingStartsAgain() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ActivityLog(directory: directory, calendar: Self.utc)
        log.write(.app, "before")
        log.flush()
        #expect(log.logFiles().count == 1)

        log.deleteAll()
        #expect(log.logFiles().isEmpty)

        log.write(.app, "after")
        log.flush()
        #expect(try Self.lines(log.logFiles()[0]).count == 1)
    }

    @Test func testRunsNeverWriteToTheOwnersLog() {
        let directory = ActivityLog.resolvedDirectory(["XCTestConfigurationFilePath": "/tmp/x"])
        #expect(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(ActivityLog.resolvedDirectory(["ORIEL_LOG_DIRECTORY": "/tmp/oriel-dev"]).path == "/tmp/oriel-dev")
        #expect(ActivityLog.resolvedDirectory([:]) == ActivityLog.defaultDirectory)
    }

    @Test func longNumbersAreMaskedAndShortOnesKept() {
        #expect(ActivityLogRedaction.scrub("Enter code 123456 now") == "Enter code [number] now")
        #expect(ActivityLogRedaction.scrub("Card 4111 1111 1111 1111 saved") == "Card [number] saved")
        #expect(ActivityLogRedaction.scrub("Result 78995 at 15:55") == "Result 78995 at 15:55")
        #expect(ActivityLogRedaction.scrub(String(repeating: "a", count: 500), limit: 10).count == 10)
    }

    @Test func instructionsThatMentionSecretsAreWithheld() {
        #expect(ActivityLogRedaction.instruction("Open Calculator and add 7 and 8") == "\"Open Calculator and add 7 and 8\"")
        let withheld = ActivityLogRedaction.instruction("Log in with my password hunter2")
        #expect(withheld.hasPrefix("(withheld"))
        #expect(!withheld.contains("hunter2"))
    }

    @Test func typedTextAndAnswersAreKeptByLengthOnly() throws {
        let typed = try AgentTraceEvent(
            instructionID: "ABCDEFGH-1234", stepIndex: 3, kind: .planned,
            summary: "Type \"see you at noon\" — fill the message", action: .type(text: "see you at noon"),
            monotonicNanoseconds: 1
        )
        let line = ActivityLogRedaction.trace(typed)
        #expect(line == "run ABCDEFGH step 3 planned: Type (15 characters) — fill the message")

        let answered = try AgentTraceEvent(
            instructionID: "ABCDEFGH-1234", stepIndex: 4, kind: .answered,
            summary: "the blue one", monotonicNanoseconds: 2
        )
        #expect(ActivityLogRedaction.trace(answered) == "run ABCDEFGH step 4 answered: (12 characters)")
        #expect(ActivityLogRedaction.control(.answer(stepID: "s", text: "the blue one")) == "answer (12 characters)")
    }

    @Test func peerReasonsAreReducedToAPlainToken() {
        #expect(ActivityLogRedaction.token("disconnected-on-ios") == "disconnected-on-ios")
        #expect(ActivityLogRedaction.token("bad\nreason <script>") == "badreasonscript")
        #expect(ActivityLogRedaction.token("") == "unspecified")
    }
}
