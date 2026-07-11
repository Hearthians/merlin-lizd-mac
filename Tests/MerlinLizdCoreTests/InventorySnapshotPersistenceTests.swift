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
}
