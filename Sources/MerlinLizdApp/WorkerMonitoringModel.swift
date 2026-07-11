import Foundation
import MerlinLizdCore
import SwiftUI

@MainActor
final class WorkerMonitoringModel: ObservableObject {
    @Published private(set) var state: WorkerMonitoringPanelState = .loading()

    private let streamer = WorkerMetricsStreamer()
    private var activeGeneration: UUID?
    private var activeTarget: TerminalTarget?
    private var samples: [WorkerMetricsSample] = []
    private let retentionWindow: TimeInterval = 5 * 60

    func monitor(target: TerminalTarget) async {
        let generation = UUID()
        activeGeneration = generation

        if activeTarget != target {
            activeTarget = target
            samples = []
        }
        state = .loading(previous: currentData)

        let heartbeat = WorkerMetricsHeartbeat()
        do {
            let stream = streamer.stream(target: target, intervalSeconds: 3)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for try await sample in stream {
                        try Task.checkCancellation()
                        await heartbeat.recordSample()
                        guard await self?.accept(sample, generation: generation) == true else {
                            throw CancellationError()
                        }
                    }
                    throw WorkerMetricsStreamingError.connectionEnded
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        if await heartbeat.hasExpired(after: .seconds(30)) {
                            throw WorkerMonitoringWatchdogError.stalled
                        }
                    }
                }
                defer { group.cancelAll() }
                guard let _ = try await group.next() else {
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeGeneration == generation else { return }
            state = .failed(
                message: Self.message(for: error),
                previous: currentData
            )
        }
    }

    private func accept(
        _ sample: WorkerMetricsSample,
        generation: UUID
    ) -> Bool {
        guard activeGeneration == generation else { return false }
        append(sample)
        state = .loaded(WorkerMonitoringData(
            samples: samples,
            updatedAt: sample.timestamp
        ))
        return true
    }

    private var currentData: WorkerMonitoringData? {
        guard let last = samples.last else { return nil }
        return WorkerMonitoringData(samples: samples, updatedAt: last.timestamp)
    }

    private func append(_ sample: WorkerMetricsSample) {
        samples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-retentionWindow)
        samples.removeAll { $0.timestamp < cutoff }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case WorkerMetricsSamplingError.workerNotReady:
            "Worker 尚未就绪，稍后可重新采样。"
        case let WorkerMetricsSamplingError.commandFailed(exitCode):
            "监控命令执行失败（退出码 \(exitCode)）。"
        case WorkerMetricsParseError.missingEnvelope,
             WorkerMetricsParseError.incompleteEnvelope,
             WorkerMetricsParseError.noMetrics:
            "Worker 返回的监控数据不完整。"
        case WorkerMetricsStreamingError.connectionEnded:
            "实时采样连接已结束，请重试。"
        case WorkerMetricsStreamingError.incompleteEnvelope:
            "监控连接中断，最后一份数据不完整。"
        case WorkerMetricsStreamingError.envelopeTooLarge:
            "Worker 返回的监控数据异常。"
        case WorkerMetricsStreamingError.stdoutBufferOverflow:
            "Worker 指标输出过快，监控连接已安全停止。"
        case WorkerMonitoringWatchdogError.stalled:
            "超过 30 秒没有收到新指标，监控连接已停止。"
        default:
            "无法持续读取 Worker 指标，请检查连接状态。"
        }
    }
}

private enum WorkerMonitoringWatchdogError: Error {
    case stalled
}

private actor WorkerMetricsHeartbeat {
    private var lastSample = ContinuousClock.now

    func recordSample() {
        lastSample = ContinuousClock.now
    }

    func hasExpired(after timeout: Duration) -> Bool {
        lastSample.duration(to: ContinuousClock.now) >= timeout
    }
}

struct WorkerMonitoringContainer: View {
    let target: TerminalTarget?
    let expectsGPU: Bool
    let unavailableMessage: String

    @StateObject private var model = WorkerMonitoringModel()
    @State private var retryGeneration = 0

    private var requestID: RequestID {
        RequestID(target: target, retryGeneration: retryGeneration)
    }

    var body: some View {
        WorkerMonitoringPanel(
            state: target == nil
                ? .unavailable(message: unavailableMessage)
                : model.state,
            expectsGPU: expectsGPU,
            onRetry: target == nil ? nil : {
                retryGeneration += 1
            }
        )
        .task(id: requestID) {
            guard let target else { return }
            await model.monitor(target: target)
        }
    }

    private struct RequestID: Hashable {
        let target: TerminalTarget?
        let retryGeneration: Int
    }
}
