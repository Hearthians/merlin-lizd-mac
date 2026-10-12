import Darwin
import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Add SSH host configuration")
struct SSHHostConfigurationTests {
    @Test("fields are normalized and IPv6 addresses are accepted")
    func normalization() throws {
        let configuration = try SSHHostConfiguration(
            alias: "  lab-server  ", hostname: " [fe80::1%en0] ",
            username: " alice ", port: 2222, identityFile: "  ~/.ssh/lab key  "
        )
        #expect(configuration.alias == "lab-server")
        #expect(configuration.hostname == "fe80::1%en0")
        #expect(configuration.username == "alice")
        #expect(configuration.identityFile == "~/.ssh/lab key")
        #expect(try SSHHostConfiguration(alias: "lab", hostname: "localhost").port == 22)
        #expect(try SSHHostConfiguration(alias: "lab", hostname: "127.0.0.1", identityFile: " ").identityFile == nil)
    }

    @Test("invalid fields cannot inject configuration directives")
    func validation() throws {
        for alias in ["", "-option", "user@host", "*", "host\nHost other", "host\t", String(repeating: "a", count: 256)] {
            #expect(throws: SSHHostConfigurationError.invalidAlias) {
                try SSHHostConfiguration(alias: alias, hostname: "example.com")
            }
        }
        for hostname in ["", "user@host", "ssh://host", "host:22", "host\nProxyCommand evil", "[example.com]", "999.2.3.4", "host..com", "fe80::1%", "fe80::1%bad%scope"] {
            #expect(throws: SSHHostConfigurationError.invalidHostname) {
                try SSHHostConfiguration(alias: "lab", hostname: hostname)
            }
        }
        for username in ["alice bob", "alice\nHost other", "root\t", "-user", "a#comment"] {
            #expect(throws: SSHHostConfigurationError.invalidUsername) {
                try SSHHostConfiguration(alias: "lab", hostname: "host", username: username)
            }
        }
        for port in [-1, 0, 65536] {
            #expect(throws: SSHHostConfigurationError.invalidPort) {
                try SSHHostConfiguration(alias: "lab", hostname: "host", port: port)
            }
        }
        for identityFile in ["id_ed25519", "~another/key", "/key\nHost other", "/${ENV}/key"] {
            #expect(throws: SSHHostConfigurationError.invalidIdentityFile) {
                try SSHHostConfiguration(alias: "lab", hostname: "host", identityFile: identityFile)
            }
        }
    }

    @Test("first host creates private SSH config and becomes discoverable")
    func initialConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = try fixture.writer.add(SSHHostConfiguration(
            alias: "research", hostname: "research.example.com", username: "alice", port: 2222
        ))
        #expect(host == SSHHost(destination: "research", source: .configuration))
        #expect(fixture.catalog.load() == [host])
        #expect(try fixture.permissions(fixture.sshDirectory) == 0o700)
        #expect(try fixture.permissions(fixture.configURL) == 0o600)
        let evaluated = try fixture.evaluate("research")
        #expect(evaluated["hostname"] == "research.example.com")
        #expect(evaluated["user"] == "alice")
        #expect(evaluated["port"] == "2222")
        #expect(try fixture.backups().isEmpty)
    }

    @Test("old bytes and global settings survive a prepended host")
    func preservesExistingConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("# My existing config\r\nServerAliveInterval 37\r\nHost existing\r\n    HostName old.example.com\r\n    User olduser\r\n    Port 2200\r\nHost *\r\n    Port 2022\r\n    User fallback".utf8)
        try fixture.write(original, permissions: 0o640)
        let before = try fixture.evaluate("existing")
        let unknownBefore = try fixture.evaluate("untouched.example.com")
        _ = try fixture.writer.add(SSHHostConfiguration(
            alias: "new-host", hostname: "new.example.com", username: "newuser", port: 2222
        ))
        let saved = try Data(contentsOf: fixture.configURL)
        #expect(saved.suffix(original.count) == original)
        #expect(try fixture.evaluate("existing") == before)
        #expect(try fixture.evaluate("untouched.example.com") == unknownBefore)
        let added = try fixture.evaluate("new-host")
        #expect(added["user"] == "newuser")
        #expect(added["port"] == "2222")
        #expect(added["serveraliveinterval"] == "37")
        #expect(try fixture.permissions(fixture.configURL) == 0o640)
        let backup = try #require(try fixture.backups().first)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try fixture.permissions(backup) == 0o600)
    }

    @Test("aliases in includes and equals syntax are rejected without writes")
    func duplicateAliases() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("Include = conf.d/*\nHost=DirectAlias\n    HostName direct.example\n".utf8)
        try fixture.write(original)
        let includes = fixture.sshDirectory.appendingPathComponent("conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        try Data("Host = IncludedAlias second-alias\n    HostName included.example\n".utf8)
            .write(to: includes.appendingPathComponent("hosts"))
        for alias in ["directalias", "includedalias", "SECOND-ALIAS"] {
            #expect(throws: SSHHostConfigurationError.duplicateAlias(alias)) {
                try fixture.writer.add(SSHHostConfiguration(alias: alias, hostname: "new.example"))
            }
        }
        #expect(try Data(contentsOf: fixture.configURL) == original)
        #expect(try fixture.backups().isEmpty)
    }

    @Test("a symlinked config remains a symlink with its target safely replaced")
    func preservesSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("Host old\n    HostName old.example\n".utf8)
        let target = fixture.home.appendingPathComponent("managed-config")
        try fixture.write(original)
        try FileManager.default.moveItem(at: fixture.configURL, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.configURL, withDestinationURL: target)
        _ = try fixture.writer.add(SSHHostConfiguration(alias: "new", hostname: "new.example"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configURL.path) == target.path)
        #expect(try Data(contentsOf: target).suffix(original.count) == original)
        #expect(fixture.catalog.load().map(\.destination) == ["new", "old"])
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.tmuxhub-backup-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    @Test("quoted identity paths and IPv6 scopes survive OpenSSH parsing")
    func quotedPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writer.add(SSHHostConfiguration(
            alias: "ipv6", hostname: "[fe80::1%en0]", identityFile: "~/.ssh/lab \"key\" 50%.pem"
        ))
        let evaluated = try fixture.evaluate("ipv6")
        #expect(evaluated["hostname"] == "fe80::1%en0")
        #expect(evaluated["identityfile"] == fixture.home.appendingPathComponent(".ssh/lab \"key\" 50%%.pem").path)
    }

    @Test("non UTF-8, oversized, and nonregular configs are preserved on failure")
    func unreadableConfiguration() throws {
        for original in [Data([0xFF, 0xFE]), Data(repeating: 65, count: 1_048_577)] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(original)
            #expect(throws: SSHHostConfigurationError.unreadableConfiguration) {
                try fixture.writer.add(SSHHostConfiguration(alias: "new", hostname: "new.example"))
            }
            #expect(try Data(contentsOf: fixture.configURL) == original)
            #expect(try fixture.backups().isEmpty)
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.configURL, withIntermediateDirectories: true)
        #expect(throws: SSHHostConfigurationError.unreadableConfiguration) {
            try fixture.writer.add(SSHHostConfiguration(alias: "new", hostname: "new.example"))
        }
    }

    @Test("an unreadable include prevents editing without changing the original")
    func unreadableInclude() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("Include broken-config\n".utf8)
        try fixture.write(original)
        try Data([0xFF, 0xFE]).write(to: fixture.sshDirectory.appendingPathComponent("broken-config"))
        #expect(throws: SSHHostConfigurationError.unreadableConfiguration) {
            try fixture.writer.add(SSHHostConfiguration(alias: "new", hostname: "new.example"))
        }
        #expect(try Data(contentsOf: fixture.configURL) == original)
        #expect(try fixture.backups().isEmpty)
    }

    @Test("prepending cannot push a readable config beyond the catalog size limit")
    func replacementSizeLimit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data(("#" + String(repeating: "a", count: 1_048_550)).utf8)
        try fixture.write(original)
        #expect(throws: SSHHostConfigurationError.unreadableConfiguration) {
            try fixture.writer.add(SSHHostConfiguration(alias: "new", hostname: "new.example"))
        }
        #expect(try Data(contentsOf: fixture.configURL) == original)
        #expect(try fixture.backups().isEmpty)
    }

    @Test("unresolved dynamic includes cannot hide duplicate aliases when editing")
    func dynamicInclude() throws {
        for path in ["${HOME}/.ssh/hosts", "%d/.ssh/hosts", "~another/.ssh/config"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = Data("Include \(path)\n".utf8)
            try fixture.write(original)
            #expect(throws: SSHHostConfigurationError.unsupportedIncludePath) {
                try fixture.writer.add(SSHHostConfiguration(alias: "new", hostname: "new.example"))
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
        var catalog: SSHConfigCatalog { SSHConfigCatalog(homeDirectory: home) }

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tmuxhub-ssh-config-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }

        func write(_ data: Data, permissions: Int = 0o600) throws {
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try data.write(to: configURL)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
        }

        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue
        }

        func backups() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: sshDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("config.tmuxhub-backup-") }
        }

        func evaluate(_ alias: String) throws -> [String: String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G", "-F", configURL.path, alias]
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
