import Testing
@testable import MerlinLizdCore

@Suite("Safe inventory persistence")
struct InventorySnapshotPersistenceTests {
    @Test("round-trips only the safe Worker projection")
    func roundTripsWithoutNetworkSecrets() throws {
        let fixture = try InventorySnapshotPersistenceFixture.make()

        #expect(fixture.decoded == fixture.snapshot)
        #expect(!fixture.encoded.contains("secret-network-address"))
        #expect(!fixture.encoded.contains("secret.invalid"))
        #expect(!fixture.encoded.contains("9000"))
        #expect(fixture.decoded.devboxes.first?.workers.first?
            .sshProxyDestination ==
            "123.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org")
        #expect(fixture.decoded.devboxes.first?.sshConnectionTarget ==
            "1.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org")
        #expect(fixture.decoded.devboxes.first?.devbox.cluster?.name ==
            "candy-yg")
        #expect(fixture.decoded.devboxes.first?.workers.first?.clusterName ==
            "k8s-worker-yg")
    }

    @Test("decodes Worker caches written before platform status existed")
    func decodesLegacyWorkerRecord() throws {
        let worker = try InventorySnapshotPersistenceFixture
            .decodeLegacyWorkerRecord()

        #expect(worker.id == "123")
        #expect(worker.clusterName == nil)
        #expect(worker.platformStatus == nil)
        #expect(worker.sshProxyDestination == nil)
        #expect(worker.readiness == .listed)
    }

    @Test("decodes Devbox caches written before cluster metadata existed")
    func decodesLegacyDevbox() throws {
        let devbox = try InventorySnapshotPersistenceFixture
            .decodeLegacyDevbox()

        #expect(devbox.sid == "dbx_1")
        #expect(devbox.cluster == nil)
    }
}
