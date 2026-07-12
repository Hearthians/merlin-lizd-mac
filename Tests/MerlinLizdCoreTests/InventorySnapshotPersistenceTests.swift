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
    }

    @Test("decodes Worker caches written before platform status existed")
    func decodesLegacyWorkerRecord() throws {
        let worker = try InventorySnapshotPersistenceFixture
            .decodeLegacyWorkerRecord()

        #expect(worker.id == "123")
        #expect(worker.platformStatus == nil)
        #expect(worker.readiness == .listed)
    }
}
