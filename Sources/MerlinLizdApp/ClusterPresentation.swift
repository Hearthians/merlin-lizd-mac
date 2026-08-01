import MerlinLizdCore

struct ClusterPresentation {
    let shortCode: String
    let helpText: String
}

extension DevboxInventory {
    var clusterPresentation: ClusterPresentation? {
        guard let shortCode = clusterShortCode else { return nil }
        return ClusterPresentation(
            shortCode: shortCode,
            helpText: "开发机集群：\(clusterName ?? shortCode)"
        )
    }
}

extension WorkerClusterLocation {
    var clusterPresentation: ClusterPresentation {
        let helpText = switch source {
        case .worker:
            "Worker 集群：\(name)"
        case .devbox:
            "开发机集群：\(name)\nWorker 未返回独立集群"
        }
        return ClusterPresentation(shortCode: shortCode, helpText: helpText)
    }
}
