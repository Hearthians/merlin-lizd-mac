import Foundation

/// The effective connection settings reported by the system OpenSSH client.
/// Identity paths retain OpenSSH's tokens and tilde notation when present.
public struct SSHHostProperties: Equatable, Sendable {
    public let destination: String
    public let hostname: String
    public let username: String
    public let port: Int
    public let identityFiles: [String]
    public let proxyJump: String?
    public let proxyCommand: String?
}

public enum SSHHostPropertiesError: LocalizedError, Equatable, Sendable {
    case invalidDestination
    case timedOut
    case outputTooLarge
    case invalidOutput
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "SSH 目标格式无效，无法读取主机属性。"
        case .timedOut:
            return "读取 SSH 配置超时，请检查配置中的 Include 和 Match 规则。"
        case .outputTooLarge:
            return "SSH 配置输出过大，无法显示主机属性。"
        case .invalidOutput:
            return "SSH 未返回有效的主机地址、用户名或端口。"
        case let .commandFailed(message):
            return message.isEmpty ? "无法读取 SSH 配置。" : "无法读取 SSH 配置：\n\(message)"
        }
    }
}

/// Evaluates Include, wildcard, user and port rules with `ssh -G`; it does
/// not connect to the destination or request an authentication credential.
public struct SSHHostPropertiesReader: Sendable {
    private static let maximumOutputBytes = 1_048_576
    private let runner: any InventoryProcessRunning
    private let configFile: URL?

    public init(configFile: URL? = nil) {
        self.init(runner: SSHPropertiesProcessRunner(), configFile: configFile)
    }

    init(runner: any InventoryProcessRunning, configFile: URL? = nil) {
        self.runner = TimedInventoryProcessRunner(timeout: .seconds(5), underlying: runner)
        self.configFile = configFile
    }

    public func load(destination: String) async throws -> SSHHostProperties {
        guard IdentifierValidator.isSSHDestination(destination) else {
            throw SSHHostPropertiesError.invalidDestination
        }
        var arguments = ["-G", "-T"]
        if let configFile { arguments += ["-F", configFile.path] }
        arguments += ["--", destination]
        let output: InventoryProcessOutput
        do {
            output = try await runner.run(CommandSpec(
                executable: "/usr/bin/ssh", arguments: arguments,
                environment: ["LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]
            ))
        } catch InventoryProcessTimeoutError.timedOut {
            throw SSHHostPropertiesError.timedOut
        }
        guard output.exitCode == 0 else {
            throw SSHHostPropertiesError.commandFailed(Self.diagnostic(output.stderr))
        }
        return try Self.parse(output.stdout, destination: destination)
    }

    static func parse(_ output: String, destination: String) throws -> SSHHostProperties {
        guard output.utf8.count <= maximumOutputBytes else {
            throw SSHHostPropertiesError.outputTooLarge
        }
        var singleValues: [String: String] = [:]
        var identityFiles: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let keyword = fields[0].lowercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if keyword == "identityfile" {
                if value.lowercased() != "none", !identityFiles.contains(value) {
                    identityFiles.append(value)
                }
            } else if singleValues[keyword] == nil {
                singleValues[keyword] = value
            }
        }
        guard let hostname = singleValues["hostname"],
            let username = singleValues["user"],
            let portValue = singleValues["port"],
            let port = Int(portValue), (1...65_535).contains(port)
        else { throw SSHHostPropertiesError.invalidOutput }
        func optionalValue(_ key: String) -> String? {
            guard let value = singleValues[key], value.lowercased() != "none" else { return nil }
            return value
        }
        return SSHHostProperties(
            destination: destination, hostname: hostname, username: username,
            port: port, identityFiles: identityFiles,
            proxyJump: optionalValue("proxyjump"), proxyCommand: optionalValue("proxycommand")
        )
    }

    fileprivate static func diagnostic(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        })).trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096).description
    }

    /// The existing streaming process runner bounds its buffers. This adapter
    /// also bounds the complete result and cancels/reaps on overflow or timeout.
    private struct SSHPropertiesProcessRunner: InventoryProcessRunning {
        func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
            try Task.checkCancellation()
            let stream = POSIXInventoryProcessStreamer(stderrTailByteLimit: 4_096)
                .streamStandardOutput(command)
            var data = Data()
            do {
                for try await chunk in stream.chunks {
                    guard data.count + chunk.count <= maximumOutputBytes else {
                        throw SSHHostPropertiesError.outputTooLarge
                    }
                    data.append(chunk)
                }
                await stream.waitForTermination()
                try Task.checkCancellation()
                return InventoryProcessOutput(
                    stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0
                )
            } catch {
                await stream.cancelAndWait()
                try Task.checkCancellation()
                if case let InventoryProcessStreamError.commandFailed(exitCode, stderrTail) = error {
                    return InventoryProcessOutput(stdout: "", stderr: stderrTail, exitCode: exitCode)
                }
                if case InventoryProcessStreamError.stdoutBufferOverflow = error {
                    throw SSHHostPropertiesError.outputTooLarge
                }
                throw error
            }
        }
    }
}
