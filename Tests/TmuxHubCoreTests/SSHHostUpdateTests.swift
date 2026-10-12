import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Edit SSH host properties")
struct SSHHostUpdateTests {
    @Test("common properties normalize while the destination stays stable")
    func normalization() throws {
        let settings = try SSHConnectionSettings(
            destination: "  research  ", hostname: " [fe80::1%en0] ", username: " alice ", port: 2222
        )
        #expect(settings.destination == "research")
        #expect(settings.updatedDestination == "research")
        #expect(settings.hostname == "fe80::1%en0")
        #expect(settings.username == "alice")
        let explicit = try SSHConnectionSettings(
            destination: "alice@[::1]", hostname: "[::1]", username: "bob", port: 22
        )
        #expect(explicit.updatedDestination == "bob@[::1]")
        #expect(try SSHConnectionSettings(
            destination: "lab+dev", hostname: "localhost", username: "alice", port: 22
        ).destination == "lab+dev")
    }

    @Test("invalid destinations and fields cannot introduce config syntax")
    func validation() {
        for destination in ["", "-option", "lab*", "host\nHost other", "user@", "[abc]", "bad:22", "host\t"] {
            #expect(throws: (any Error).self) {
                try SSHConnectionSettings(destination: destination, hostname: "example.com", username: "alice", port: 22)
            }
        }
        for hostname in ["host\nProxyCommand evil", "host:22", "user@host", "[not-ipv6]"] {
            #expect(throws: SSHHostConfigurationError.invalidHostname) {
                try SSHConnectionSettings(destination: "lab", hostname: hostname, username: "alice", port: 22)
            }
        }
        for username in ["", " ", "alice\nHost other", "*", "-user"] {
            #expect(throws: SSHHostConfigurationError.invalidUsername) {
                try SSHConnectionSettings(destination: "lab", hostname: "host", username: username, port: 22)
            }
        }
        for port in [0, -1, 65536] {
            #expect(throws: SSHHostConfigurationError.invalidPort) {
                try SSHConnectionSettings(destination: "lab", hostname: "host", username: "alice", port: port)
            }
        }
    }

    @Test("editing an alias preserves original bytes, keys, proxy, defaults, and shared aliases")
    func preservesExistingSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data(("# User owned config\r\nServerAliveInterval 41\r\n"
            + "Host lab lab-copy\r\n    HostName old.example.com\r\n    User olduser\r\n    Port 2200\r\n"
            + "    IdentityFile \"~/.ssh/key with space\"\r\n    ProxyJump jump.example.com\r\n"
            + "Host *\r\n    User fallback\r\n    Port 2022").utf8)
        try fixture.write(original, permissions: 0o640)
        let before = try fixture.evaluate("lab")
        let sharedBefore = try fixture.evaluate("lab-copy")
        let unrelatedBefore = try fixture.evaluate("elsewhere")
        let host = try fixture.update("lab", hostname: "new.example.com", username: "newuser", port: 2222)
        #expect(host == SSHHost(destination: "lab", source: .configuration))
        let after = try fixture.evaluate("lab")
        #expect(after["hostname"] == "new.example.com")
        #expect(after["user"] == "newuser")
        #expect(after["port"] == "2222")
        for key in ["identityfile", "proxyjump", "serveraliveinterval"] {
            #expect(after[key] == before[key])
        }
        #expect(try fixture.evaluate("lab-copy") == sharedBefore)
        #expect(try fixture.evaluate("elsewhere") == unrelatedBefore)
        #expect(try fixture.evaluate("explicit@lab")["user"] == "explicit")
        #expect(try Data(contentsOf: fixture.configURL).suffix(original.count) == original)
        #expect(try fixture.permissions(fixture.configURL) == 0o640)
        let backup = try #require(fixture.backups().first)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try fixture.permissions(backup) == 0o600)
    }

    @Test("included host settings remain inherited without rewriting the include")
    func includedConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let includedURL = fixture.home.appendingPathComponent("included-config")
        let included = Data("Host research research-copy\n    HostName old.example\n    User old\n    Port 2211\n    IdentityFile ~/.ssh/research-key\n    ProxyJump bastion\n".utf8)
        try included.write(to: includedURL)
        let original = Data("Include \"\(includedURL.path)\"\nHost *\n    ServerAliveInterval 47\n".utf8)
        try fixture.write(original)
        let before = try fixture.evaluate("research")
        let copyBefore = try fixture.evaluate("research-copy")
        _ = try fixture.update("research", hostname: "new.example", username: "new", port: 2222)
        let after = try fixture.evaluate("research")
        #expect(after["hostname"] == "new.example")
        #expect(after["user"] == "new")
        #expect(after["port"] == "2222")
        #expect(after["identityfile"] == before["identityfile"])
        #expect(after["proxyjump"] == before["proxyjump"])
        #expect(try fixture.evaluate("research-copy") == copyBefore)
        #expect(try Data(contentsOf: includedURL) == included)
        #expect(try Data(contentsOf: fixture.configURL).suffix(original.count) == original)
    }

    @Test("repeated saves replace one managed block and unchanged saves are no-ops")
    func repeatedEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("Host lab\n    HostName old.example\n".utf8)
        try fixture.write(original)
        _ = try fixture.update("lab", hostname: "first.example", username: "alice", port: 2222)
        _ = try fixture.update("lab", hostname: "second.example", username: "bob", port: 2223)
        let saved = try Data(contentsOf: fixture.configURL)
        let backupCount = try fixture.backups().count
        _ = try fixture.update("lab", hostname: "second.example", username: "bob", port: 2223)
        #expect(try Data(contentsOf: fixture.configURL) == saved)
        #expect(try fixture.backups().count == backupCount)
        let content = String(decoding: saved, as: UTF8.self)
        #expect(content.components(separatedBy: "# BEGIN TmuxHub SSH properties ").count == 2)
        #expect(!content.contains("first.example"))
        #expect(saved.suffix(original.count) == original)
        let evaluated = try fixture.evaluate("lab")
        #expect(evaluated["hostname"] == "second.example")
        #expect(evaluated["user"] == "bob")
        #expect(evaluated["port"] == "2223")
    }

    @Test("raw IP and IPv6 destinations apply properties to the exact host")
    func addressDestinations() throws {
        for destination in ["192.0.2.1", "[2001:db8::1]", "2001:db8::1", "[fe80::1%en0]"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = try fixture.update(destination, hostname: "[2001:db8::2]", username: "alice", port: 2222)
            let after = try fixture.evaluate(destination)
            #expect(after["hostname"] == "2001:db8::2")
            #expect(after["user"] == "alice")
            #expect(after["port"] == "2222")
            #expect(try fixture.evaluate("192.0.2.10")["port"] == "22")
            #expect(try fixture.permissions(fixture.configURL) == 0o600)
            #expect(try fixture.permissions(fixture.sshDirectory) == 0o700)
        }
    }

    @Test("explicit user edits return the new target and do not change other users")
    func explicitUserDestinations() throws {
        for destination in ["alice@lab", "alice@192.0.2.1", "alice@[::1]"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(Data("Host *\n    User fallback\n    Port 2022\n".utf8))
            let originalBefore = try fixture.evaluate(destination)
            let host = try fixture.update(destination, hostname: "new.example", username: "bob", port: 2222)
            let expected = destination.replacingOccurrences(of: "alice@", with: "bob@")
            #expect(host == SSHHost(destination: expected, source: .custom))
            let after = try fixture.evaluate(expected)
            #expect(after["hostname"] == "new.example")
            #expect(after["user"] == "bob")
            #expect(after["port"] == "2222")
            #expect(try fixture.evaluate(destination) == originalBefore)
            _ = try fixture.update(expected, hostname: "last.example", username: "carol", port: 2223)
            let final = try fixture.evaluate(expected.replacingOccurrences(of: "bob@", with: "carol@"))
            #expect(final["hostname"] == "last.example")
            #expect(final["port"] == "2223")
            let contents = try String(contentsOf: fixture.configURL, encoding: .utf8)
            #expect(contents.components(separatedBy: "# BEGIN TmuxHub SSH properties ").count == 2)
            #expect(!contents.contains("user bob"))
        }
    }

    @Test("editing a plain alias retains priority of user-qualified property blocks")
    func userSpecificPriority() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.update("alice@lab", hostname: "alice.example", username: "alice", port: 2222)
        _ = try fixture.update("lab", hostname: "general.example", username: "general", port: 2022)
        _ = try fixture.update("lab", hostname: "second.example", username: "second", port: 2023)
        #expect(try fixture.evaluate("alice@lab")["hostname"] == "alice.example")
        #expect(try fixture.evaluate("alice@lab")["port"] == "2222")
        #expect(try fixture.evaluate("lab")["hostname"] == "second.example")
        #expect(try fixture.evaluate("lab")["user"] == "second")
        #expect(try fixture.evaluate("lab-other")["port"] == "22")
    }

    @Test("adding a plain alias retains prior user-qualified properties")
    func addAfterUserSpecificProperties() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.update("alice@lab", hostname: "alice.example", username: "alice", port: 2222)
        _ = try fixture.writer.add(SSHHostConfiguration(
            alias: "lab", hostname: "general.example", username: "general", port: 2022
        ))
        #expect(try fixture.evaluate("alice@lab")["hostname"] == "alice.example")
        #expect(try fixture.evaluate("alice@lab")["port"] == "2222")
        #expect(try fixture.evaluate("lab")["hostname"] == "general.example")
        #expect(try fixture.evaluate("lab")["user"] == "general")
    }

    @Test("renaming an explicit user cannot overwrite another managed target")
    func explicitTargetCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.update("alice@lab", hostname: "alice.example", username: "alice", port: 2222)
        _ = try fixture.update("bob@lab", hostname: "bob.example", username: "bob", port: 2223)
        let original = try Data(contentsOf: fixture.configURL)
        #expect(throws: SSHHostConfigurationError.duplicateAlias("bob@lab")) {
            try fixture.update("alice@lab", hostname: "new.example", username: "bob", port: 2224)
        }
        #expect(try Data(contentsOf: fixture.configURL) == original)
    }

    @Test("updating a symlinked config keeps the link and backs up its target")
    func symlinkedConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("Host lab\n    HostName old.example\n".utf8)
        try fixture.write(original, permissions: 0o640)
        let target = fixture.home.appendingPathComponent("managed-config")
        try FileManager.default.moveItem(at: fixture.configURL, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.configURL, withDestinationURL: target)
        _ = try fixture.update("lab", hostname: "new.example", username: "alice", port: 2222)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configURL.path) == target.path)
        #expect(try Data(contentsOf: target).suffix(original.count) == original)
        #expect(try fixture.permissions(target) == 0o640)
        #expect(try fixture.evaluate("lab")["hostname"] == "new.example")
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.tmuxhub-backup-") }
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    @Test("malformed owned blocks and unreadable or oversized files are never overwritten")
    func invalidConfigurations() throws {
        let identifier = Data("lab".utf8).base64EncodedString()
        let malformed = [
            "# BEGIN TmuxHub SSH properties \(identifier)\nHost lab\n",
            "# END TmuxHub SSH properties \(identifier)\n",
            String(repeating: "# BEGIN TmuxHub SSH properties \(identifier)\nHost *\n# END TmuxHub SSH properties \(identifier)\n", count: 2),
        ]
        for content in malformed {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = Data(content.utf8)
            try fixture.write(original)
            #expect(throws: SSHHostConfigurationError.invalidManagedConfiguration) {
                try fixture.update("lab", hostname: "new.example", username: "alice", port: 2222)
            }
            #expect(try Data(contentsOf: fixture.configURL) == original)
            #expect(try fixture.backups().isEmpty)
        }
        for original in [Data([0xFF, 0xFE]), Data(("#" + String(repeating: "a", count: 1_048_500)).utf8)] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(original)
            #expect(throws: SSHHostConfigurationError.unreadableConfiguration) {
                try fixture.update("lab", hostname: "new.example", username: "alice", port: 2222)
            }
            #expect(try Data(contentsOf: fixture.configURL) == original)
            #expect(try fixture.backups().isEmpty)
        }
    }

    private struct Fixture {
        let home: URL
        var sshDirectory: URL { home.appendingPathComponent(".ssh", isDirectory: true) }
        var configURL: URL { sshDirectory.appendingPathComponent("config") }
        var writer: SSHConfigWriter { SSHConfigWriter(homeDirectory: home) }

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tmuxhub-ssh-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func update(_ destination: String, hostname: String, username: String, port: Int) throws -> SSHHost {
            try writer.update(SSHConnectionSettings(
                destination: destination, hostname: hostname, username: username, port: port
            ))
        }

        func write(_ data: Data, permissions: Int = 0o600) throws {
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try data.write(to: configURL)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
        }

        func permissions(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }

        func backups() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: sshDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("config.tmuxhub-backup-") }
        }

        func evaluate(_ destination: String) throws -> [String: String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G", "-F", configURL.path, destination]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(String(decoding: diagnostics, as: UTF8.self))")
            var values: [String: String] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 1)
                if fields.count == 2 { values[String(fields[0])] = String(fields[1]) }
            }
            return values
        }
    }
}
