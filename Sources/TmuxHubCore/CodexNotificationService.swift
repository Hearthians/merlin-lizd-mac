import Foundation

protocol CodexNotificationRemoteRunning: Sendable {
    func run(_ command: CommandSpec, alias: String, replay: SSHReplayPolicy) async throws -> InventoryProcessOutput
}

extension SSHMasterPool: CodexNotificationRemoteRunning {}

public actor CodexNotificationService {
    private let remote: any CodexNotificationRemoteRunning
    private let local: any InventoryProcessRunning
    private let operations = BoundedAsyncOperationRunner(maxConcurrentOperations: 3, timeout: .seconds(25))

    public init(sshMasterPool: SSHMasterPool) {
        remote = sshMasterPool
        local = FoundationInventoryProcessRunner()
    }

    init(remote: any CodexNotificationRemoteRunning, local: any InventoryProcessRunning) {
        self.remote = remote
        self.local = local
    }

    /// Explicit setup only. The caller displays the returned /hooks review
    /// instructions; installing the helper does not grant hook trust.
    public func install(destination: String?) async throws -> String {
        let command = try CodexNotificationBridge.installCommand(destination: destination)
        let output = try await run(command, destination: destination, replay: .never)
        struct Receipt: Decodable { let sourceID: String; let message: String }
        guard output.utf8.count <= 65_536, let data = output.data(using: .utf8),
            let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
            UUID(uuidString: receipt.sourceID) != nil, receipt.message.utf8.count <= 8_192
        else { throw CodexNotificationError.invalidResponse }
        return receipt.message
    }

    /// Non-destructive, paginated read. Every TmuxHub device owns its own
    /// persisted cursor and must detect sourceID changes before advancing it.
    public func read(destination: String?, after: Int, limit: Int = 100) async throws -> CodexNotificationFeed {
        let command = try CodexNotificationBridge.readCommand(destination: destination, after: after, limit: limit)
        let output = try await run(command, destination: destination, replay: .readOnly)
        return try CodexNotificationFeed.decode(output, after: after, limit: limit)
    }

    /// Explicit shared acknowledgment. The host unions these IDs under the feed
    /// lock; retrying the same batch is safe and never removes another device's
    /// receipts. Expired event IDs are harmlessly ignored.
    public func markRead(destination: String?, sourceID: String, eventIDs: [String]) async throws {
        let command = try CodexNotificationBridge.markReadCommand(destination: destination, sourceID: sourceID, eventIDs: eventIDs)
        // The pool's replayable mode is also safe for this idempotent set union.
        let output = try await run(command, destination: destination, replay: .readOnly)
        struct Receipt: Decodable { let sourceID: String; let acknowledged: Bool }
        guard output.utf8.count <= 65_536, let data = output.data(using: .utf8),
            let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
            receipt.sourceID == sourceID, receipt.acknowledged
        else { throw CodexNotificationError.invalidResponse }
    }

    private func run(_ command: CommandSpec, destination: String?, replay: SSHReplayPolicy) async throws -> String {
        let remote = self.remote
        let local = self.local
        let result: InventoryProcessOutput
        do {
            result = try await operations.run {
                try Task.checkCancellation()
                if let destination {
                    return try await remote.run(command, alias: destination, replay: replay)
                }
                return try await local.run(command)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch InventoryProcessTimeoutError.timedOut {
            throw CodexNotificationError.commandFailed("连接超时，请检查主机连接。")
        } catch let SSHMasterPoolError.connectionFailed(_, message) {
            throw CodexNotificationError.commandFailed(Self.safeDiagnostic(message))
        } catch {
            throw CodexNotificationError.commandFailed(Self.safeDiagnostic(error.localizedDescription))
        }
        if result.exitCode == 20, result.stderr.contains("TMUXHUB_NOT_INSTALLED") {
            throw CodexNotificationError.notInstalled
        }
        guard result.exitCode == 0 else {
            let diagnostic = Self.safeDiagnostic(result.stderr)
            throw CodexNotificationError.commandFailed(diagnostic.isEmpty ? "命令退出码 \(result.exitCode)" : diagnostic)
        }
        return result.stdout
    }

    private static func safeDiagnostic(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        })).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024).description
    }
}
