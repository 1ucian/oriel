import Testing
@testable import HermesCaptureCore

struct RestartableAsyncStreamTests {
    @Test func deliversAfterFirstConsumerCancellationAndRestart() async {
        let values = RestartableAsyncStream<Int>(bufferingPolicy: .bufferingNewest(3))
        let first = Task {
            for await _ in values.values {}
        }
        await Task.yield()
        first.cancel()
        _ = await first.result

        values.restart()
        let second = Task { () -> Int? in
            for await value in values.values { return value }
            return nil
        }
        values.yield(2)

        #expect(await second.value == 2)
    }
}
