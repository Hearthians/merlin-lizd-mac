import Foundation
import MerlinLizdCore
import SwiftUI

@MainActor
final class WorkerMonitoringModel: ObservableObject {
    @Published private(set) var state: WorkerMonitoringPanelState = .loading()

    private let streamer: WorkerMetricsStreamer
    private let platformProvider: MerlinPlatformMetricsProvider?
    private var activeGeneration: UUID?
    private var activeTarget: MerlinPlatformMetricsTarget?
    private var samples: [WorkerMetricsSample] = []
    private var platformAttemptInProgress = false
    private var platformIsEmpty = false
    private var platformMissingMetrics: Set<GrafanaMetricKind> = []
    private var platformRetryAttempt = 0
    private var platformSlowMessage: String?
    private var platformErrorMessage: String?
    private var lastPlatformSampleAt: Date?
    private var lastDirectSampleAt: Date?
    private var directIsActive = false
    private var directErrorMessage: String?
    private let retentionWindow: TimeInterval = 5 * 60

    init() {
        streamer = WorkerMetricsStreamer()
        platformProvider = try? MerlinPlatformMetricsProvider()
    }

    func monitor(
        platformTarget: MerlinPlatformMetricsTarget,
        directTarget: TerminalTarget?
    ) async {
        let generation = UUID()
        activeGeneration = generation

        let isSameTarget = activeTarget == platformTarget
        let previous = isSameTarget ? currentData : nil
        if !isSameTarget {
            samples = []
            platformMissingMetrics = []
            platformRetryAttempt = 0
            lastPlatformSampleAt = nil
            lastDirectSampleAt = nil
        }
        activeTarget = platformTarget
        platformAttemptInProgress = platformProvider != nil
        platformIsEmpty = false
        platformSlowMessage = nil
        platformErrorMessage = nil
        directIsActive = directTarget != nil
        directErrorMessage = nil
        state = .loading(previous: previous)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.consumePlatform(
                    target: platformTarget,
                    generation: generation
                )
            }
            group.addTask { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                await self?.markPlatformSlow(generation: generation)
            }
            if let directTarget {
                group.addTask { [weak self] in
                    await self?.consumeDirect(
                        target: directTarget,
                        generation: generation
                    )
                }
            }
            await group.waitForAll()
        }
    }

    private func consumePlatform(
        target: MerlinPlatformMetricsTarget,
        generation: UUID
    ) async {
        guard let platformProvider else {
            platformAttemptInProgress = false
            platformErrorMessage = "未找到 Merlin CLI，无法读取平台监控。"
            publish(generation: generation)
            return
        }

        while !Task.isCancelled, activeGeneration == generation {
            let requestedMetrics = platformMissingMetrics.isEmpty
                ? nil
                : platformMissingMetrics
            platformAttemptInProgress = true
            platformIsEmpty = false
            platformSlowMessage = nil
            publish(generation: generation)
            do {
                let batch = try await platformProvider.fetch(
                    target,
                    metrics: requestedMetrics
                )
                try Task.checkCancellation()
                guard activeGeneration == generation else { return }
                platformAttemptInProgress = false
                platformIsEmpty = false
                platformSlowMessage = nil
                platformErrorMessage = nil
                platformMissingMetrics = batch.missingMetrics
                if let latest = batch.samples.map(\.timestamp).max() {
                    lastPlatformSampleAt = max(lastPlatformSampleAt ?? latest, latest)
                }
                if platformMissingMetrics.isEmpty {
                    platformRetryAttempt = 0
                }
                mergePlatform(batch.samples)
                publish(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard activeGeneration == generation else { return }
                platformAttemptInProgress = false
                platformSlowMessage = nil
                if case MerlinPlatformMetricsError.noData = error {
                    platformIsEmpty = true
                    platformErrorMessage = nil
                } else {
                    platformIsEmpty = false
                    platformErrorMessage = Self.platformMessage(for: error)
                }
                publish(generation: generation)
            }

            let needsCoverageRetry = !platformMissingMetrics.isEmpty
                || platformIsEmpty
            let retrySeconds: TimeInterval
            if needsCoverageRetry {
                let exponent = min(platformRetryAttempt, 5)
                retrySeconds = min(
                    5 * 60,
                    15 * pow(2, Double(exponent))
                )
                platformRetryAttempt += 1
            } else if platformErrorMessage != nil {
                retrySeconds = 60
            } else {
                platformRetryAttempt = 0
                retrySeconds = 5 * 60
            }
            do {
                try await Task.sleep(for: .seconds(retrySeconds))
            } catch {
                return
            }
        }
    }

    private func consumeDirect(
        target: TerminalTarget,
        generation: UUID
    ) async {
        directIsActive = true

        let heartbeat = WorkerMetricsHeartbeat()
        do {
            let stream = streamer.stream(target: target, intervalSeconds: 3)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for try await sample in stream {
                        try Task.checkCancellation()
                        await heartbeat.recordSample()
                        guard await self?.acceptDirect(
                            sample,
                            generation: generation
                        ) == true else {
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
            directIsActive = false
            directErrorMessage = Self.directMessage(for: error)
            publish(generation: generation)
        }
    }

    private func acceptDirect(
        _ sample: WorkerMetricsSample,
        generation: UUID
    ) -> Bool {
        guard activeGeneration == generation else { return false }
        lastDirectSampleAt = sample.timestamp
        directErrorMessage = nil
        append(sample)
        publish(generation: generation)
        return true
    }

    private var currentData: WorkerMonitoringData? {
        guard let last = samples.last else { return nil }
        return WorkerMonitoringData(
            samples: samples,
            updatedAt: last.timestamp,
            source: monitoringSource,
            notice: monitoringNotice,
            isIncomplete: !platformMissingMetrics.isEmpty
        )
    }

    private func append(_ sample: WorkerMetricsSample) {
        if let index = samples.firstIndex(where: { $0.timestamp == sample.timestamp }) {
            samples[index] = sample
        } else {
            samples.append(sample)
            samples.sort { $0.timestamp < $1.timestamp }
        }
        pruneSamples()
    }

    private func mergePlatform(_ platformSamples: [WorkerMetricsSample]) {
        var merged = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.timestamp, $0) }
        )
        for sample in platformSamples {
            if let existing = merged[sample.timestamp] {
                // Existing values win exact collisions (including direct
                // observations); an incremental platform retry still fills
                // previously absent CPU/GPU fields at that timestamp.
                merged[sample.timestamp] = existing.fillingMissingValues(
                    from: sample
                )
            } else {
                merged[sample.timestamp] = sample
            }
        }
        samples = merged.values.sorted { $0.timestamp < $1.timestamp }
        pruneSamples()
    }

    private func pruneSamples() {
        let cutoff = Date.now.addingTimeInterval(-retentionWindow)
        samples.removeAll { $0.timestamp < cutoff }
    }

    private func publish(generation: UUID) {
        guard activeGeneration == generation else { return }
        pruneSamples()
        if let data = currentData {
            state = .loaded(data)
            return
        }
        if platformIsEmpty, !directIsActive {
            let directSuffix = directErrorMessage.map {
                " Worker 直连补采也未成功：\($0)"
            } ?? ""
            state = .empty(
                message: "Merlin 平台最近 5 分钟暂无指标；App 会自动继续重试。\(directSuffix)"
            )
        } else if
            !platformAttemptInProgress,
            platformErrorMessage != nil,
            !directIsActive
        {
            let messages = [platformErrorMessage, directErrorMessage]
                .compactMap { $0 }
            state = .failed(
                message: messages.joined(separator: " "),
                previous: nil
            )
        } else {
            state = .loading(message: platformSlowMessage)
        }
    }

    private func markPlatformSlow(generation: UUID) {
        guard
            activeGeneration == generation,
            platformAttemptInProgress,
            !hasRecentPlatformData
        else { return }
        platformSlowMessage = "Merlin 平台响应较慢，仍在后台加载"
        publish(generation: generation)
    }

    private var monitoringSource: WorkerMonitoringSource {
        if hasRecentPlatformData {
            return hasRecentDirectData
                ? .merlinPlatformWithDirectTail
                : .merlinPlatform
        }
        return .directWorker
    }

    private var monitoringNotice: String? {
        if hasRecentPlatformData {
            if let platformErrorMessage {
                return directIsActive
                    ? "\(platformErrorMessage) 继续显示最近的平台数据与 Worker 实时点。"
                    : "\(platformErrorMessage) 继续显示最近一次平台数据。"
            }
            if platformIsEmpty {
                return "Merlin 平台本轮暂未返回时序数据；继续显示上一次结果，并会自动重试。"
            }
            if !platformMissingMetrics.isEmpty {
                let names = GrafanaMetricKind.allCases.compactMap { metric in
                    platformMissingMetrics.contains(metric)
                        ? Self.metricName(metric)
                        : nil
                }.joined(separator: "、")
                return "Merlin 平台正在补齐\(names)指标；已显示其余平台数据，并会自动增量重试。"
            }
            if let directErrorMessage {
                return "\(directErrorMessage) 当前继续显示 Merlin 平台数据。"
            }
            if hasRecentDirectData {
                return "历史曲线来自 Merlin 平台，最新点由 Worker 直连补充。"
            }
            return nil
        }
        if let platformErrorMessage {
            return "\(platformErrorMessage) 已自动切换到 Worker 直连采样。"
        }
        if platformIsEmpty, hasRecentDirectData {
            return "Merlin 平台最近 5 分钟暂无指标，当前显示 Worker 直连数据。"
        }
        if platformAttemptInProgress, hasRecentDirectData {
            return platformSlowMessage.map { "\($0)；当前先显示 Worker 直连数据。" }
                ?? "正在同步 Merlin 平台历史，当前先显示 Worker 直连数据。"
        }
        return directErrorMessage
    }

    private var hasRecentPlatformData: Bool {
        isRecent(lastPlatformSampleAt)
    }

    private var hasRecentDirectData: Bool {
        isRecent(lastDirectSampleAt)
    }

    private func isRecent(_ timestamp: Date?) -> Bool {
        guard let timestamp else { return false }
        return timestamp >= Date.now.addingTimeInterval(-retentionWindow)
    }

    private static func metricName(_ metric: GrafanaMetricKind) -> String {
        switch metric {
        case .gpuUtilization:
            "GPU 利用率"
        case .gpuMemory:
            "显存"
        case .cpu:
            "CPU"
        case .memory:
            "内存"
        case .temperature:
            "GPU 温度"
        }
    }

    private static func platformMessage(for error: Error) -> String {
        switch error {
        case MerlinPlatformMetricsError.workerNotFound:
            "Merlin 平台未找到该 Worker。"
        case MerlinPlatformMetricsError.noData:
            "Merlin 平台最近 5 分钟暂无指标。"
        case MerlinPlatformMetricsError.timedOut:
            "Merlin 平台指标读取超时。"
        case let MerlinPlatformMetricsError.commandFailed(exitCode):
            "Merlin 平台指标命令失败（退出码 \(exitCode)）。"
        case MerlinPlatformMetricsError.transport:
            "Merlin 平台指标暂时不可达。"
        case MerlinPlatformMetricsError.malformedResponse:
            "Merlin 平台指标格式暂时无法识别。"
        case MerlinPlatformMetricsError.invalidConcurrencyLimit,
             MerlinPlatformMetricsError.invalidExecutablePath:
            "Merlin 平台监控配置不可用。"
        default:
            "Merlin 平台指标暂时不可用。"
        }
    }

    private static func directMessage(for error: Error) -> String {
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
    let platformTarget: MerlinPlatformMetricsTarget?
    let directTarget: TerminalTarget?
    let expectsGPU: Bool
    let unavailableMessage: String

    @StateObject private var model = WorkerMonitoringModel()
    @State private var retryGeneration = 0

    private var requestID: RequestID {
        RequestID(
            platformTarget: platformTarget,
            directTarget: directTarget,
            retryGeneration: retryGeneration
        )
    }

    var body: some View {
        WorkerMonitoringPanel(
            state: platformTarget == nil
                ? .unavailable(message: unavailableMessage)
                : model.state,
            expectsGPU: expectsGPU,
            onRetry: platformTarget == nil ? nil : {
                retryGeneration += 1
            }
        )
        .task(id: requestID) {
            guard let platformTarget else { return }
            await model.monitor(
                platformTarget: platformTarget,
                directTarget: directTarget
            )
        }
    }

    private struct RequestID: Hashable {
        let platformTarget: MerlinPlatformMetricsTarget?
        let directTarget: TerminalTarget?
        let retryGeneration: Int
    }
}
