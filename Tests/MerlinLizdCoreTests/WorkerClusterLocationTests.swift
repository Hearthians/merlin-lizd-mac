import Testing
@testable import MerlinLizdCore

@Suite("Worker cluster location")
struct WorkerClusterLocationTests {
    @Test("uses the Devbox data center as its compact cluster code")
    func usesDevboxDataCenterAsClusterCode() throws {
        let machine = DevboxInventory(
            devbox: try devbox(clusterName: "candy-yg")
        )

        #expect(machine.clusterShortCode == "yg")
    }

    @Test("infers the compact code from the cluster name when data center is missing")
    func infersDevboxClusterCodeFromName() throws {
        let page = try DevboxPageParser.parse("""
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "dbx_135679",
            "name": "wt_hl",
            "status": "running",
            "cluster": {"name": "candy-hl", "id": 6}
          }],
          "pagination": {"page_size": 100}
        }
        """)
        let machine = DevboxInventory(
            devbox: try #require(page.devboxes.first)
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

        #expect(machine.clusterShortCode == "hl")
        let location = try #require(machine.workerClusterLocation(for: worker))
        #expect(location.dataCenter == nil)
        #expect(location.shortCode == "hl")
    }

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

        let location = try #require(machine.workerClusterLocation(for: worker))

        #expect(location == WorkerClusterLocation(
            name: "candy-yg",
            source: .devbox,
            dataCenter: "yg"
        ))
        #expect(location.shortCode == "yg")
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

        let location = try #require(machine.workerClusterLocation(for: worker))

        #expect(location == WorkerClusterLocation(
            name: "k8s-worker-yg",
            source: .worker
        ))
        #expect(location.shortCode == "yg")
    }

    @Test("keeps the compact parent code when its full cluster name is missing")
    func fallsBackToParentDataCenterWithoutClusterName() throws {
        let page = try DevboxPageParser.parse("""
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "dbx_135679",
            "name": "wt_hl",
            "status": "running",
            "cluster": {"dc": "hl", "id": 6}
          }],
          "pagination": {"page_size": 100}
        }
        """)
        let machine = DevboxInventory(
            devbox: try #require(page.devboxes.first)
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

        let location = try #require(machine.workerClusterLocation(for: worker))

        #expect(location.source == .devbox)
        #expect(location.shortCode == "hl")
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
