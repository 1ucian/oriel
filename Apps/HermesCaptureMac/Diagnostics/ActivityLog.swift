import Darwin
import Foundation
import HermesCaptureCore
import HermesCaptureProtocol

/// Oriel's activity log for troubleshooting: session events and every assistant step, one
/// line each, in ~/Library/Logs/Oriel. It never leaves the Mac. One file per day; seven days
/// are kept and each day is capped. What reaches a line is trimmed by `ActivityLogRedaction`.
final class ActivityLog: @unchecked Sendable {
    enum Category: String, Sendable {
        case app, pairing, session, relay, input, assistant
    }

    static let shared = ActivityLog(directory: resolvedDirectory(ProcessInfo.processInfo.environment))

    /// ORIEL_LOG_DIRECTORY moves the log (a development copy of the app); test runs write to a
    /// temporary folder so they never mix with the owner's log.
    static func resolvedDirectory(_ environment: [String: String]) -> URL {
        if let override = environment["ORIEL_LOG_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("oriel-test-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return defaultDirectory
    }
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Oriel", isDirectory: true)
    }
    static let retentionDays = 7
    static let filePrefix = "oriel-activity-"

    let directory: URL
    private let maximumBytesPerDay: Int
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "com.67enterprise.oriel.activity-log", qos: .utility)
    // Confined to `queue`.
    private var handle: FileHandle?
    private var openDay: String?
    private var bytesInOpenFile = 0
    private var dayIsFull = false

    init(
        directory: URL,
        maximumBytesPerDay: Int = 8 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.directory = directory
        self.maximumBytesPerDay = maximumBytesPerDay
        self.now = now
        self.calendar = calendar
    }

    func write(_ category: Category, _ message: String) {
        let date = now()
        queue.async { [self] in append(category, message, at: date) }
    }

    /// Returns once every line written so far is on disk.
    func flush() {
        queue.sync {}
    }

    func deleteAll() {
        queue.sync {
            try? handle?.close()
            handle = nil
            openDay = nil
            for url in logFiles() { try? FileManager.default.removeItem(at: url) }
        }
    }

    func logFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(".log") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    // MARK: Lines

    static func line(_ category: Category, _ message: String, at date: Date, calendar: Calendar) -> String {
        let flat = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(timestamp(date, calendar: calendar)) [\(category.rawValue)] \(flat)\n"
    }

    static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            min(999, Int((Double(parts.nanosecond ?? 0) / 1_000_000).rounded()))
        )
    }

    static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        String(timestamp(date, calendar: calendar).prefix(10))
    }

    // MARK: Files

    private func append(_ category: Category, _ message: String, at date: Date) {
        let day = Self.dayStamp(date, calendar: calendar)
        if day != openDay || handle == nil {
            open(day: day, at: date)
        }
        guard let handle, !dayIsFull else { return }
        var data = Data(Self.line(category, message, at: date, calendar: calendar).utf8)
        if bytesInOpenFile + data.count > maximumBytesPerDay {
            data = Data(Self.line(.app, "The log is full for today; lines are dropped until tomorrow.", at: date, calendar: calendar).utf8)
            dayIsFull = true
        }
        do {
            try handle.write(contentsOf: data)
            bytesInOpenFile += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func open(day: String, at date: Date) {
        try? handle?.close()
        handle = nil
        openDay = day
        dayIsFull = false
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        prune(keepingFrom: date)
        let path = directory.appendingPathComponent("\(Self.filePrefix)\(day).log").path
        // O_APPEND keeps whole lines intact if a second copy of the app writes the same day.
        let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        bytesInOpenFile = Int((try? handle?.seekToEnd()) ?? 0)
        dayIsFull = bytesInOpenFile >= maximumBytesPerDay
    }

    /// Days are read from file names, so no file timestamps are needed.
    private func prune(keepingFrom date: Date) {
        guard let oldest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: date) else { return }
        let cutoff = Self.filePrefix + Self.dayStamp(oldest, calendar: calendar)
        for url in logFiles() where url.deletingPathExtension().lastPathComponent < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// What a log line may carry. Typed text and the owner's answers are kept by length only, an
/// instruction that mentions a password, code or card number is withheld, long numbers are
/// masked everywhere, and lines are kept short.
enum ActivityLogRedaction {
    /// Six or more digits, allowing one space, dot or dash between them.
    private static let longNumber = try! NSRegularExpression(pattern: #"\d(?:[ .\-]?\d){5,}"#)

    static func scrub(_ text: String, limit: Int = 400) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let masked = longNumber.stringByReplacingMatches(
            in: flat, range: NSRange(flat.startIndex..., in: flat), withTemplate: "[number]"
        )
        return masked.count > limit ? String(masked.prefix(limit - 1)) + "…" : masked
    }

    static func instruction(_ text: String) -> String {
        if SensitiveTextClassifier.isSensitive(text) {
            return "(withheld: it mentions a password, code or card number; \(text.count) characters)"
        }
        return "\"\(scrub(text, limit: 300))\""
    }

    /// A reason string from the other device: short and plain.
    static func token(_ text: String) -> String {
        let allowed = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(allowed.prefix(64)))
        return cleaned.isEmpty ? "unspecified" : cleaned
    }

    static func trace(_ event: AgentTraceEvent) -> String {
        var summary = event.summary
        if case let .type(text)? = event.action, !text.isEmpty {
            let length = "(\(text.count) characters)"
            let shown = text.count > 60 ? String(text.prefix(57)) + "…" : text
            summary = summary.replacingOccurrences(of: "\"\(shown)\"", with: length)
            if text.count >= 4 {
                summary = summary.replacingOccurrences(of: text, with: length)
            }
        }
        if event.kind == .answered {
            summary = "(\(event.summary.count) characters)"
        }
        return "run \(event.instructionID.prefix(8)) step \(event.stepIndex) \(event.kind.rawValue): \(scrub(summary))"
    }

    static func control(_ control: AgentControl) -> String {
        switch control {
        case .pause: "pause"
        case .resume: "resume"
        case .stop: "stop"
        case .approve: "approve"
        case .deny: "deny"
        case let .answer(_, text): "answer (\(text.count) characters)"
        }
    }
}
