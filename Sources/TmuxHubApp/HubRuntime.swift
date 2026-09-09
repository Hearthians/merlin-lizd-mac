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
    let tmuxDiscovery: TmuxSessionDiscovery
    let tmuxController: TmuxSessionController
    let attachmentService: AttachmentTransferService
    let herdrService: HerdrService
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
        let herdr = HerdrService(sshMasterPool: pool)
        herdrService = herdr
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

    func prepare(_ target: TerminalTarget) {
        guard !isShuttingDown, let destination = target.sshDestination else {
            return
        }
        Task {
            _ = await sshMasterPool.prepare(
                alias: destination,
                priority: .foreground
            )
        }
    }

    func hasSavedPassword(for destination: String) throws -> Bool {
        try passwordStore.containsPassword(for: destination)
    }

    func savePassword(_ password: String, for destination: String) throws {
        guard askPassExecutable != nil else {
            throw PasswordAuthenticationSetupError.askPassHelperUnavailable
        }
        try passwordStore.setPassword(password, for: destination)
        prepare(.ssh(destination: destination))
    }

    func removePassword(for destination: String) throws {
        try passwordStore.removePassword(for: destination)
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
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
