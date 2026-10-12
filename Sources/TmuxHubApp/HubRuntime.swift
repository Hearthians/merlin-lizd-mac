import Foundation
import TmuxHubCore

enum PasswordAuthenticationSetupError: LocalizedError {
    case askPassHelperUnavailable

    var errorDescription: String? {
        "密码助手不可用，请重新安装 TmuxHub。"
    }
}

@MainActor
final class HubRuntime {
    let sshMasterPool: SSHMasterPool
    let sshLocalForwardingService: SSHLocalForwardingService
    let tmuxDiscovery: TmuxSessionDiscovery
    let tmuxController: TmuxSessionController
    let attachmentService: AttachmentTransferService
    let herdrService: HerdrService
    let slurmService: SlurmService
    private let passwordStore: SSHPasswordStore
    private let askPassExecutable: String?
    private var isShuttingDown = false

    init(passwordStore: SSHPasswordStore = SSHPasswordStore()) {
        let askPassExecutable = Self.resolveAskPassExecutable()
        self.passwordStore = passwordStore
        self.askPassExecutable = askPassExecutable
        let pool = SSHMasterPool(
            maxConcurrentPreparations: 4,
            passwordProvider: { destination in
                guard let askPassExecutable,
                    let password = try? passwordStore.password(for: destination)
                else { return nil }
                return SSHPasswordAuthentication(
                    password: password,
                    askPassExecutable: askPassExecutable
                )
            }
        )
        sshMasterPool = pool
        sshLocalForwardingService = SSHLocalForwardingService(
            sshMasterPool: pool
        )
        let herdr = HerdrService(sshMasterPool: pool)
        herdrService = herdr
        slurmService = SlurmService(sshMasterPool: pool)
        attachmentService = AttachmentTransferService(sshMasterPool: pool, herdrService: herdr)
        tmuxDiscovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            maxConcurrentBackgroundRefreshes: 8
        )
        tmuxController = TmuxSessionController(
            sshMasterPool: pool,
            maxConcurrentProcesses: 4
        )
    }

    func prepare(
        _ target: TerminalTarget,
        onReady: ((String) -> Void)? = nil
    ) {
        guard !isShuttingDown, let destination = target.sshDestination else {
            return
        }
        Task {
            let state = await sshMasterPool.prepare(
                alias: destination,
                priority: .foreground
            )
            if state == .ready {
                onReady?(destination)
            }
        }
    }

    func hasSavedPassword(for destination: String) async throws -> Bool {
        let store = passwordStore
        return try await Task.detached(priority: .userInitiated) {
            try store.containsPassword(for: destination)
        }.value
    }

    func savePassword(_ password: String, for destination: String) async throws {
        guard askPassExecutable != nil else {
            throw PasswordAuthenticationSetupError.askPassHelperUnavailable
        }
        let store = passwordStore
        try await Task.detached(priority: .userInitiated) {
            try store.setPassword(password, for: destination)
        }.value
        prepare(.ssh(destination: destination))
    }

    func authorizeSavedPassword(for destination: String) async throws {
        guard askPassExecutable != nil else {
            throw PasswordAuthenticationSetupError.askPassHelperUnavailable
        }
        let store = passwordStore
        try await Task.detached(priority: .userInitiated) {
            try store.authorizePassword(for: destination)
        }.value
        prepare(.ssh(destination: destination))
    }

    func removePassword(for destination: String) async throws {
        let store = passwordStore
        try await Task.detached(priority: .userInitiated) {
            try store.removePassword(for: destination)
        }.value
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        await sshLocalForwardingService.shutdown()
        await sshMasterPool.shutdown()
    }

    private static func resolveAskPassExecutable() -> String? {
        var candidates: [URL] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("TmuxHubAskPass"),
        ]
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL.deletingLastPathComponent()
                    .appendingPathComponent("TmuxHubAskPass")
            )
        }
        return candidates.map(\.path).first(
            where: FileManager.default.isExecutableFile(atPath:)
        )
    }
}
