import MerlinLizdCore

extension WorkerClusterLocation {
    var displayLabel: String {
        switch source {
        case .worker:
            "集群 \(name)"
        case .devbox:
            "开发机集群 \(name)"
        }
    }
}
