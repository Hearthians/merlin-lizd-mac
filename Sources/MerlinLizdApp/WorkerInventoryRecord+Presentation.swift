import MerlinLizdCore

extension WorkerInventoryRecord {
    var displayName: String {
        gpuType ?? (gpuCount > 0 ? "GPU Worker" : "CPU Worker")
    }
}
