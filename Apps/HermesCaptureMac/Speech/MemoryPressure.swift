import Foundation

/// The system's memory-pressure reports as a stream, for work that should give memory back when the Mac runs short.
enum MemoryPressure {
    enum Level: Sendable, Equatable {
        case normal
        case warning
        case critical
    }

    /// Only the rise to a warning or critical level is of interest, not the return to normal.
    static var eventMask: DispatchSource.MemoryPressureEvent { [.warning, .critical] }

    static func level(of event: DispatchSource.MemoryPressureEvent) -> Level {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }

    /// One value per event until the stream ends or its consumer is cancelled.
    static func system() -> AsyncStream<Level> {
        AsyncStream { continuation in
            let source = DispatchSource.makeMemoryPressureSource(eventMask: eventMask, queue: .global(qos: .utility))
            source.setEventHandler { [unowned source] in continuation.yield(level(of: source.data)) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
