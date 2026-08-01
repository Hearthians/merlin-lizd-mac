import Testing
@testable import MerlinLizdCore

@Suite("Merlin CLI Worker page parser")
struct MerlinWorkerPageParserTests {
    @Test("projects a validated direct SSH destination without other network fields")
    func parsesSafeWorkerProjection() throws {
        let page = try MerlinWorkerPageParser.parse("""
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "wkr_3966773",
            "status": "running",
            "gpu_count": 1,
            "gpu_type": "NVIDIA-L20",
            "cpu_cores": 22,
            "memory_bytes": 123480309760,
            "created_at": "2026-07-09T04:50:08Z",
            "pod_ip": "2605:secret::1",
            "host_ip": "2605:secret::2",
            "ssh_proxy_cmd": "3966773.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org",
            "webshell_url": "https://secret.invalid/signed",
            "grafana_url": "https://secret.invalid/grafana"
          }],
          "pagination": {
            "page_size": 1,
            "next_page_token": " opaque-cursor "
          }
        }
        """)

        let worker = try #require(page.workers.first)
        #expect(worker.id == "3966773")
        #expect(worker.platformStatus == "running")
        #expect(worker.cpuCores == 22)
        #expect(worker.memoryGiB == 115)
        #expect(worker.gpuCount == 1)
        #expect(worker.gpuType == "NVIDIA-L20")
        #expect(worker.createdAt == "2026-07-09T04:50:08Z")
        #expect(worker.readiness == .listed)
        #expect(worker.sshProxyDestination ==
            "3966773.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org")
        #expect(worker.podIP == nil)
        #expect(worker.webshellURL == nil)
        #expect(page.nextPageToken == "opaque-cursor")

        let safeRecord = WorkerInventoryRecord(worker: worker)
        let enrichedRecord = safeRecord.withGPUType("NVIDIA-L20")
        #expect(safeRecord.sshConnectionTarget(fallback: "hl_gpu_2") ==
            "3966773.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org")
        #expect(enrichedRecord.gpuType == "NVIDIA-L20")
        #expect(enrichedRecord.platformStatus == "running")
        #expect(enrichedRecord.readiness == .listed)
        let description = String(reflecting: safeRecord)
        #expect(!description.contains("2605:secret"))
        #expect(!description.contains("secret.invalid"))
    }

    @Test("keeps platform status separate from SSH readiness")
    func doesNotInferReadinessFromPlatformStatus() throws {
        let page = try MerlinWorkerPageParser.parse(workerPage(
            sid: "wkr_3960209",
            status: "pending",
            memoryBytes: 257698037760
        ))

        let worker = try #require(page.workers.first)
        #expect(worker.platformStatus == "pending")
        #expect(worker.readiness == .listed)
        #expect(worker.memoryGiB == 240)
    }

    @Test("preserves probed readiness when platform Worker data refreshes")
    func preservesProbedReadinessAcrossWorkerRefresh() {
        let previous = [
            WorkerInventoryRecord(worker: Worker(
                id: "3960209",
                cpuCores: 100,
                memoryGiB: 240,
                gpuCount: 0,
                gpuType: nil,
                platformStatus: "running",
                podIP: nil,
                port: 0,
                createdAt: "before",
                webshellURL: nil,
                readiness: .ready
            )),
        ]
        let refreshed = [
            WorkerInventoryRecord(worker: Worker(
                id: "3960209",
                cpuCores: 64,
                memoryGiB: 190,
                gpuCount: 0,
                gpuType: nil,
                platformStatus: "running",
                podIP: nil,
                port: 0,
                createdAt: "after",
                webshellURL: nil
            )),
            WorkerInventoryRecord(worker: Worker(
                id: "3960210",
                cpuCores: 20,
                memoryGiB: 115,
                gpuCount: 1,
                gpuType: "NVIDIA-L20",
                platformStatus: "running",
                podIP: nil,
                port: 0,
                createdAt: "new",
                webshellURL: nil
            )),
        ]

        let reconciled = WorkerInventoryRecord.preservingReadiness(
            of: refreshed,
            from: previous
        )

        #expect(reconciled.map(\.readiness) == [.ready, .listed])
        #expect(reconciled[0].cpuCores == 64)
        #expect(reconciled[0].createdAt == "after")
    }

    @Test("rejects malformed platform Worker identifiers")
    func rejectsMalformedWorkerSID() {
        #expect(throws: MerlinWorkerPageParserError.invalidWorkerSID("3960209")) {
            try MerlinWorkerPageParser.parse(workerPage(
                sid: "3960209",
                status: "running",
                memoryBytes: 257698037760
            ))
        }
    }

    @Test("surfaces server failures")
    func surfacesServerFailure() {
        #expect(throws: MerlinWorkerPageParserError.server(
            code: 7,
            message: "denied"
        )) {
            try MerlinWorkerPageParser.parse("""
            {
              "ResponseBase": {"code": 7, "message": "denied"},
              "data": [],
              "pagination": {"page_size": 100}
            }
            """)
        }
    }

    private func workerPage(
        sid: String,
        status: String,
        memoryBytes: UInt64
    ) -> String {
        """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "\(sid)",
            "status": "\(status)",
            "gpu_count": 0,
            "cpu_cores": 100,
            "memory_bytes": \(memoryBytes),
            "created_at": "2026-07-08T05:20:59Z"
          }],
          "pagination": {"page_size": 100}
        }
        """
    }
}
