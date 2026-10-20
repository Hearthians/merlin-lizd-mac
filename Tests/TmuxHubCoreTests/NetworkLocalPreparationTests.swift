import Foundation
import Testing
@testable import TmuxHubCore

struct NetworkLocalPreparationTests {
    @Test("Legacy DSA host keys do not hide a supported SSH host key")
    func legacyDSAHostKeys() throws {
        let key = Self.ed25519PublicKey
        let keys = try NetworkOnboardingCommands.validatedHostPublicKeys(
            Self.legacyDSAPublicKey + " legacy-host\n" + key + " current-host\n"
        )
        #expect(keys == [key])
        #expect(throws: NetworkOnboardingError.self) {
            try NetworkOnboardingCommands.validatedPublicKey(Self.legacyDSAPublicKey)
        }
    }

    @Test("Malformed supported host keys remain errors alongside a valid key")
    func malformedSupportedHostKey() {
        let malformed = "ssh-ed25519 AAAA corrupted-host"
        #expect(throws: NetworkOnboardingError.self) {
            try NetworkOnboardingCommands.validatedHostPublicKeys(Self.ed25519PublicKey + "\n" + malformed)
        }
    }

    @Test("Only legacy or empty host keys cannot complete host preparation")
    func noSupportedHostKey() {
        for output in ["", "\n\r\n", Self.legacyDSAPublicKey] {
            #expect(throws: NetworkOnboardingError.self) {
                try NetworkOnboardingCommands.validatedHostPublicKeys(output)
            }
        }
    }

    @Test("Host-key normalization handles repeated keys and CRLF without retaining comments")
    func normalizedHostKeys() throws {
        let key = Self.ed25519PublicKey
        #expect(try NetworkOnboardingCommands.validatedHostPublicKeys(" \(key) first\r\n\(key) second\n") == [key])
    }

    @Test("Saving an alias without a management key leaves default SSH identities available")
    func absentManagementIdentity() async throws {
        let config = try await savedConfiguration(hasManagementIdentity: false)
        #expect(!config.contains("IdentityFile"))
        #expect(!config.contains("tmuxhub_management_ed25519"))
    }

    @Test("An available management key remains the default identity for a newly saved alias")
    func availableManagementIdentity() async throws {
        let config = try await savedConfiguration(hasManagementIdentity: true)
        #expect(config.contains("IdentityFile ") && config.contains("/.ssh/tmuxhub_management_ed25519"))
    }

    @Test("An explicitly selected identity is preserved when the management key is absent")
    func explicitIdentity() async throws {
        let config = try await savedConfiguration(hasManagementIdentity: false, identityFile: "~/.ssh/user-selected")
        #expect(config.contains("IdentityFile ") && config.contains("/.ssh/user-selected"))
        #expect(!config.contains("tmuxhub_management_ed25519"))
    }

    private func savedConfiguration(hasManagementIdentity: Bool, identityFile: String? = nil) async throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-local-preparation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        if hasManagementIdentity {
            try Data("Fixture placeholder; no SSH process reads this file.".utf8)
                .write(to: ssh.appendingPathComponent("tmuxhub_management_ed25519"))
        }
        let service = NetworkOnboardingService(homeDirectory: home)
        let endpoint = try SSHHostConfiguration(alias: "fixture-host", hostname: "192.0.2.1", username: "fixture", identityFile: identityFile)
        let report = await service.saveConfigurations([endpoint])
        #expect(report.failures.isEmpty)
        #expect(report.savedAliases == ["fixture-host"])
        return try String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8)
    }

    private static let ed25519PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"

    // Generated solely as a public legacy-format fixture; no private key is stored.
    private static let legacyDSAPublicKey = "ssh-dss AAAAB3NzaC1kc3MAAACBAMbXZFLRqU4Jr0MN782/Ok2KRuob2sIQhehdDa4gMveYXecDOBlmtYqfvSN4I7HaqMXPvxzymreVQZ2c2O1AX3eEQJTDauhcjHKggjFfJEg51z3zZB37yJonrY9cT55qMmQSyUccGvXBa0MkYnsfSN5emfd9kLDM4Pz7uxZrEDKfAAAAFQCoBMu4HZA7cTsZKVyc6kVXSTMcnQAAAIAoIkme0/iu2fKSmv915nKsyAoOkqfny5KG6bNKjCYFZM27K6i4g3sn1nINhpou8HhDN+DS3BUTm85ktPcs/SQM20ot5pwTeuj2KJ1kjvF+5yavbn4S3NFx2pxs4eS/QJ4g7rxfJfGmjl5Jqta+lYYN4G/C9IDt+ntJT0CEKUaYpQAAAIEAjqXB31Us083jHO0gusUODgl6XLR6yuEzTmJxUdboMPapYDq6Tr2h7viRVRH/Y6CR3goQnITobneHia9NtIiE/HyI3oPNX2oRtVciGHLmN3JGSoKusbaHULU4x90cIsgGOGIpmX0HdjfNVxjoWHDYjFTsWUG63HdfqTx43Wdq/qY="
}
