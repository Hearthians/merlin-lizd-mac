import Testing
@testable import MerlinLizdCore

@Suite("Worker cluster location")
struct WorkerClusterLocationTests {
    @Test("identifies the parent Devbox cluster when the Worker omits one")
    func fallsBackToParentDevboxCluster() throws {
        let machine = DevboxInventory(
            devbox: try devbox(clusterName: "candy-yg")
        )
        let worker = WorkerInventoryRecord(worker: Worker(
            id: "4099222",
            cpuCores: 22,
            memoryGiB: 115,
            gpuCount: 1,
            gpuType: "NVIDIA-L20",
            podIP: nil,
            port: 0,
            createdAt: "now",
            webshellURL: nil
        ))

        #expect(machine.workerClusterLocation(for: worker) == WorkerClusterLocation(
            name: "candy-yg",
            source: .devbox
        ))
    }

    @Test("prefers a cluster reported by the Worker")
    func prefersWorkerCluster() throws {
        let machine = DevboxInventory(
            devbox: try devbox(clusterName: "candy-yg")
        )
        let worker = WorkerInventoryRecord(worker: Worker(
            id: "4099222",
            cpuCores: 22,
            memoryGiB: 115,
            gpuCount: 1,
            gpuType: "NVIDIA-L20",
            clusterName: "k8s-worker-yg",
            podIP: nil,
            port: 0,
            createdAt: "now",
            webshellURL: nil
        ))

        #expect(machine.workerClusterLocation(for: worker) ==
            WorkerClusterLocation(
                name: "k8s-worker-yg",
                source: .worker
            ))
    }

    private func devbox(clusterName: String) throws -> Devbox {
        let page = try DevboxPageParser.parse("""
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "dbx_135679",
            "name": "wt_hl",
            "status": "running",
            "cluster": {"name": "\(clusterName)", "dc": "yg", "id": 8}
          }],
          "pagination": {"page_size": 100}
        }
        """)
        return try #require(page.devboxes.first)
    }
}
