import Foundation

public final class RestartableAsyncStream<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: AsyncStream<Element>
    private var continuation: AsyncStream<Element>.Continuation?

    public init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        let channel = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: bufferingPolicy
        )
        stream = channel.stream
        continuation = channel.continuation
        self.bufferingPolicy = bufferingPolicy
    }

    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    public var values: AsyncStream<Element> {
        lock.withLock { stream }
    }

    public func restart() {
        let channel = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: bufferingPolicy
        )
        let previous = lock.withLock {
            let previous = continuation
            stream = channel.stream
            continuation = channel.continuation
            return previous
        }
        previous?.finish()
    }

    public func yield(_ value: Element) {
        let current = lock.withLock { continuation }
        current?.yield(value)
    }

    public func finish() {
        let current = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        current?.finish()
    }

    deinit {
        continuation?.finish()
    }
}
