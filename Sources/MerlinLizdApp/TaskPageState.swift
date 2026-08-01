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
    let isRefreshingMetrics: Bool

    init(
        snapshot: MerlinTaskSnapshot?,
        metricsByRunID: [String: MerlinTaskMetrics],
        attemptedMetricRunIDs: Set<String>,
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
        self.isRefreshingMetrics = isRefreshingMetrics
    }

    func metricAvailability(
        for run: MerlinTaskRun
    ) -> TaskMetricAvailability {
        if metricsByRunID[run.id] != nil {
            return .available
        }
        guard run.lifecycle == .active else { return .unavailable }
        if attemptedMetricRunIDs.contains(run.id) {
            return .unavailable
        }
        return isRefreshingMetrics ? .loading : .pending
    }
}
