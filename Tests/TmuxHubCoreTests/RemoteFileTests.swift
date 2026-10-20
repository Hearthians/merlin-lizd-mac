import Darwin
import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Remote file browsing and downloads")
struct RemoteFileTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-remote-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func canonicalPath(_ url: URL) throws -> String {
        let path = try #require(realpath(url.path, nil))
        defer { free(path) }
        return String(cString: path)
    }

    /// Run the exact remote command locally, with only the fixture directory as HOME.
    private func listing(path: String, home: URL) async throws -> RemoteFileListing {
        let command = try RemoteFileService.listingCommand(alias: "fixture", path: path)
        let script = try #require(command.arguments.last)
        let output = try await TimedInventoryProcessRunner(
            timeout: .seconds(10), underlying: FoundationInventoryProcessRunner()
        ).run(CommandSpec(
            executable: "/usr/bin/env",
            arguments: ["-i", "HOME=\(home.path)", "PATH=/usr/bin:/bin", "/bin/sh", "-c", script]
        ))
        try #require(output.exitCode == 0, "\(output.stderr)")
        return try JSONDecoder().decode(RemoteFileListing.self, from: Data(output.stdout.utf8))
    }

    @Test("listing expands home and preserves literal shell metacharacters")
    func listingHomeAndLiteralPaths() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "模型 ' \" $(printf injected); [*]? \\"
        let directory = home.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(".mesh ' \" [*]? \\ $(false).ply")
        let payload = Data("mesh fixture".utf8)
        try payload.write(to: file)

        let root = try await listing(path: "~", home: home)
        #expect(root.path == (try canonicalPath(home)))
        // macOS Python can create its own Library directory under HOME.
        let entry = try #require(root.entries.first { $0.name == name })
        #expect(entry.name == name)
        #expect(entry.path == (try canonicalPath(directory)))
        #expect(entry.isDirectory && !entry.isFile)

        for path in ["~/\(name)", directory.path] {
            let result = try await listing(path: path, home: home)
            #expect(result.path == (try canonicalPath(directory)))
            let item = try #require(result.entries.first)
            #expect(result.entries.count == 1)
            #expect(item.name == file.lastPathComponent)
            #expect(item.path == (try canonicalPath(file)))
            #expect(item.isFile && !item.isDirectory)
            #expect(item.size == Int64(payload.count))
        }
    }

    @Test("recursive batch downloads exact wildcard and quote characters through OpenSSH")
    func recursiveSFTPDownload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote space ' \" 中文 [*]?{}\\", isDirectory: true)
        let local = root.appendingPathComponent("local space ' \" 中文 [*]?{}\\", isDirectory: true)
        let nestedName = "nested [*]? ' \" \\"
        let nested = remote.appendingPathComponent(nestedName, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let filename = ".mesh ' \" [*]?{}\\ $(false);.ply"
        let payload = Data("ply\nformat ascii 1.0\nend_header\n".utf8)
        try payload.write(to: nested.appendingPathComponent(filename))
        let batchFile = root.appendingPathComponent("download.batch")
        try Data(RemoteFileService.batch(
            path: remote.path, directory: true, local: local.path
        ).utf8).write(to: batchFile)

        let output = try await TimedInventoryProcessRunner(
            timeout: .seconds(10), underlying: FoundationInventoryProcessRunner()
        ).run(CommandSpec(
            executable: "/usr/bin/sftp",
            arguments: ["-D", "/usr/libexec/sftp-server", "-b", batchFile.path]
        ))
        try #require(output.exitCode == 0, "\(output.stderr)\n\(output.stdout)")
        let downloaded = local.appendingPathComponent(nestedName).appendingPathComponent(filename)
        #expect(try Data(contentsOf: downloaded) == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.path) == [nestedName])
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: downloaded.deletingLastPathComponent().path
        ) == [filename])
    }

    @Test("listing and batch reject option injection and control characters")
    func unsafeInputs() {
        #expect(throws: AttachmentError.self) {
            try RemoteFileService.listingCommand(alias: "-oProxyCommand=false", path: "~")
        }
        #expect(throws: AttachmentError.self) {
            try RemoteFileService.listingCommand(alias: "fixture", path: "/tmp/a\nb")
        }
        for path in ["relative", "/tmp/file\nget /secret /tmp/leaked", "/tmp/file\u{1b}"] {
            #expect(throws: AttachmentError.self) {
                try RemoteFileService.batch(path: path, directory: true, local: "/tmp/download")
            }
        }
        #expect(throws: AttachmentError.self) {
            try RemoteFileService.batch(path: "/remote", directory: false, local: "/tmp/a\nb")
        }
    }
}
