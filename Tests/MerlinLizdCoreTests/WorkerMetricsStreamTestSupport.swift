import Foundation
@testable import MerlinLizdCore

struct ChunkedInventoryProcessStreamer: InventoryProcessOutputStreaming {
    let chunks: [[UInt8]]

    func streamStandardOutput(
        _ command: CommandSpec
    ) -> InventoryProcessOutputStream {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = Task {
            for chunk in chunks {
                continuation.yield(Data(chunk))
            }
            continuation.finish()
        }
        return InventoryProcessOutputStream(chunks: stream, producer: producer)
    }
}

final class BlockingInventoryProcessStreamer: InventoryProcessOutputStreaming,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var launchCount = 0

    func streamStandardOutput(
        _ command: CommandSpec
    ) -> InventoryProcessOutputStream {
        lock.withLock {
            launchCount += 1
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            continuation.finish(throwing: CancellationError())
        }
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                producer.cancel()
            }
        }
        return InventoryProcessOutputStream(chunks: stream, producer: producer)
    }

    func launches() -> Int {
        lock.withLock { launchCount }
    }

    func waitUntilLaunchCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<200 {
            if launches() >= expectedCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return launches() >= expectedCount
    }
}
