import Foundation
@testable import MerlinLizdCore

struct InventorySnapshotPersistenceFixture {
    let snapshot: InventorySnapshot
    let decoded: InventorySnapshot
    let encoded: String

    static func make() throws -> InventorySnapshotPersistenceFixture {
        let devbox = try DevboxPageParser.parse("""
            {
              "ResponseBase": {"code": 0, "message": "success"},
              "data": [{
                "sid":"dbx_1",
                "name":"one",
                "status":"running",
                "ssh_proxy_cmd":"1.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
              }],
              "pagination": {"page_size": 100}
            }
            """).devboxes[0]
        let worker = Worker(
            id: "123",
            cpuCores: 8,
            memoryGiB: 32,
            gpuCount: 1,
            gpuType: "GPU",
            sshProxyDestination:
                "123.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org",
            podIP: "secret-network-address",
            port: 9000,
            createdAt: "now",
            webshellURL: URL(string: "https://secret.invalid/signed"),
            readiness: .ready
        )
        let snapshot = InventorySnapshot(
            devboxes: [DevboxInventory(
                devbox: devbox,
                sshAlias: "one",
                workers: [WorkerInventoryRecord(worker: worker)],
                workerStatus: .loaded
            )],
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        return InventorySnapshotPersistenceFixture(
            snapshot: snapshot,
            decoded: try JSONDecoder().decode(InventorySnapshot.self, from: data),
            encoded: String(decoding: data, as: UTF8.self)
        )
    }

    static func decodeLegacyWorkerRecord() throws -> WorkerInventoryRecord {
        let data = Data("""
        {
          "id": "123",
          "cpuCores": 8,
          "memoryGiB": 32,
          "gpuCount": 1,
          "gpuType": "GPU",
          "createdAt": "now",
          "readiness": "listed"
        }
        """.utf8)
        return try JSONDecoder().decode(WorkerInventoryRecord.self, from: data)
    }
}
