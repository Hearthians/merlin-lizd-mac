import MerlinLizdCore

struct TaskPageState {
    enum Content {
        case loading
        case unavailable
        case loaded(MerlinTaskSnapshot, refreshFailed: Bool)
    }

    let content: Content
    let metricsByRunID: [String: MerlinTaskMetrics]
    let attemptedMetricRunIDs: Set<String>
    let loadingMetricRunIDs: Set<String>
    let isRefreshingMetrics: Bool

    init(
        snapshot: MerlinTaskSnapshot?,
        metricsByRunID: [String: MerlinTaskMetrics],
        attemptedMetricRunIDs: Set<String>,
        loadingMetricRunIDs: Set<String>,
        isRefreshingMetrics: Bool,
        refreshFailed: Bool
    ) {
        if let snapshot {
            content = .loaded(snapshot, refreshFailed: refreshFailed)
        } else if refreshFailed {
            content = .unavailable
        } else {
            content = .loading
        }
        self.metricsByRunID = metricsByRunID
        self.attemptedMetricRunIDs = attemptedMetricRunIDs
        self.loadingMetricRunIDs = loadingMetricRunIDs
        self.isRefreshingMetrics = isRefreshingMetrics
    }

    func gpuMetricAvailability(for run: MerlinTaskRun) -> TaskMetricAvailability {
        guard run.allocatedGPUCount != 0 else { return .unavailable }
        return metricAvailability(
            for: run,
            hasValue: metricsByRunID[run.id]?.gpu != nil
        )
    }

    func memoryMetricAvailability(
        for run: MerlinTaskRun
    ) -> TaskMetricAvailability {
        metricAvailability(
            for: run,
            hasValue: metricsByRunID[run.id]?.memory != nil
        )
    }

    private func metricAvailability(
        for run: MerlinTaskRun,
        hasValue: Bool
    ) -> TaskMetricAvailability {
        if hasValue {
            return .available
        }
        guard run.lifecycle == .active else { return .unavailable }
        if loadingMetricRunIDs.contains(run.id) {
            return .loading
        }
        if attemptedMetricRunIDs.contains(run.id) {
            return .unavailable
        }
        return .pending
    }
}
