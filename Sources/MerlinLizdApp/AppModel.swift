import AppKit
import Foundation
import MerlinLizdCore
import SwiftUI

enum SidebarSelection: Hashable {
    case overview
    case allWorkers
    case local
    case devbox(String)
    case worker(devboxSID: String, workerID: String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarSelection = .overview
    @Published private(set) var snapshot: InventorySnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStartingDevbox = false
    @Published var pendingStartDevbox: DevboxInventory?
    @Published var message: AppMessage?

    private let inventory: MerlinInventory?
    private let lifecycleRunner = LifecycleCommandRunner()
    private let sshAliases: [String]

    init() {
        sshAliases = SSHConfigCandidates.load()
        do {
            inventory = try MerlinInventory(maxConcurrentProcesses: 4)
        } catch {
            inventory = nil
            message = AppMessage(
                text: Self.inventoryErrorText(error),
                kind: .error
            )
        }
    }

    var devboxes: [DevboxInventory] {
        (snapshot?.devboxes ?? []).sorted { lhs, rhs in
            if lhs.devbox.status == rhs.devbox.status {
                return (lhs.sshAlias ?? lhs.devbox.name) < (rhs.sshAlias ?? rhs.devbox.name)
            }
            return lhs.devbox.status == "running"
        }
    }

    func devbox(sid: String) -> DevboxInventory? {
        snapshot?.devboxes.first { $0.devbox.sid == sid }
    }

    func worker(devboxSID: String, workerID: String) -> (DevboxInventory, WorkerInventoryRecord)? {
        guard
            let devbox = devbox(sid: devboxSID),
            let worker = devbox.workers.first(where: { $0.id == workerID })
        else {
            return nil
        }
        return (devbox, worker)
    }

    func runRefreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            if NSApp.isActive {
                await refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing, let inventory else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await inventory.refresh(sshAliases: sshAliases)
            if message?.kind == .error {
                message = nil
            }
        } catch {
            message = AppMessage(
                text: Self.inventoryErrorText(error),
                kind: .error
            )
        }
    }

    func requestStart(_ machine: DevboxInventory) {
        guard machine.devbox.status == "stopped" else { return }
        pendingStartDevbox = machine
    }

    func startPendingDevbox() async {
        guard let machine = pendingStartDevbox else { return }
        pendingStartDevbox = nil
        isStartingDevbox = true
        defer { isStartingDevbox = false }

        do {
            let merlinCLIPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".merlin-cli/bin/merlin-cli")
                .path
            let command = try MerlinCommands.startDevbox(
                merlinCLIPath: merlinCLIPath,
                sid: machine.devbox.sid
            )
            let exitCode = try await lifecycleRunner.run(command)
            guard exitCode == 0 else {
                message = AppMessage(
                    text: "启动请求失败（退出码 \(exitCode)）。",
                    kind: .error
                )
                return
            }
            message = AppMessage(
                text: "已提交 \(machine.sshAlias ?? machine.devbox.name) 的启动请求。",
                kind: .info
            )
            await refresh()
        } catch {
            message = AppMessage(text: "无法提交启动请求。", kind: .error)
        }
    }

    private static func inventoryErrorText(_ error: Error) -> String {
        switch error {
        case MerlinInventoryError.merlinCLINotFound:
            "未找到 ~/.merlin-cli/bin/merlin-cli，请先安装并登录 Merlin CLI。"
        case MerlinInventoryError.commandFailed(let exitCode):
            "Merlin 状态刷新失败（退出码 \(exitCode)）。"
        default:
            "暂时无法刷新 Merlin 状态，请检查登录与网络连接。"
        }
    }
}

struct AppMessage: Equatable {
    enum Kind: Equatable {
        case info
        case warning
        case error
    }

    let text: String
    let kind: Kind
}

private actor LifecycleCommandRunner {
    func run(_ command: CommandSpec) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum SSHConfigCandidates {
    private static let knownAliases = [
        "hl_gpu_2", "lq_gpu", "hl_gpu", "hl_lq_nas",
    ]

    static func load() -> [String] {
        var aliases = Set(knownAliases)
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        if let contents = try? String(contentsOf: configURL, encoding: .utf8) {
            for rawLine in contents.split(whereSeparator: \Character.isNewline) {
                let line = rawLine.split(separator: "#", maxSplits: 1).first ?? rawLine
                let fields = line.split(whereSeparator: \Character.isWhitespace)
                guard fields.first?.lowercased() == "host" else { continue }
                for candidate in fields.dropFirst() {
                    let value = String(candidate)
                    guard
                        !value.contains(where: { "*?!".contains($0) }),
                        value.range(
                            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
                            options: .regularExpression
                        ) != nil
                    else {
                        continue
                    }
                    aliases.insert(value)
                }
            }
        }
        return aliases.sorted()
    }
}
