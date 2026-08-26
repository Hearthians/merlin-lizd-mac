import Combine
import Darwin
import Foundation
import TmuxHubCore
@preconcurrency import SwiftTerm

@MainActor
final class TerminalSession: ObservableObject, Identifiable,
    LocalProcessTerminalViewDelegate
{
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
        case closed
    }

    let id: UUID
    let terminalView: LocalProcessTerminalView
    private var command: CommandSpec?
    private let currentDirectory: String?

    @Published private(set) var state: State = .idle
    private(set) var hasStarted = false
    private var didReportExit = false

    init(
        id: UUID = UUID(),
        command: CommandSpec,
        currentDirectory: String? = nil
    ) {
        self.id = id
        self.command = command
        self.currentDirectory = currentDirectory
        terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = self
    }

    func startIfNeeded() {
        guard !hasStarted, state != .closed, let command else { return }
        hasStarted = true
        terminalView.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: TerminalProcessEnvironment.inherited(
                overrides: command.environment
            ),
            currentDirectory: currentDirectory
        )
        self.command = nil
        state = .running
    }

    func close() {
        guard state != .closed else { return }
        command = nil
        let shouldTerminate = state == .running && terminalView.process.running
        let processID = shouldTerminate ? terminalView.process.shellPid : 0
        state = .closed
        if shouldTerminate {
            terminalView.terminate()
            TerminalProcessReaper.reap(processID: processID)
        }
        terminalView.processDelegate = nil
    }

    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    nonisolated func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {}

    nonisolated func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {}

    nonisolated func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.state != .closed, !self.didReportExit else {
                return
            }
            self.didReportExit = true
            self.state = .exited(exitCode)
        }
    }
}

private enum TerminalProcessReaper {
    private static let queue = DispatchQueue(
        label: "com.sshtmuxhub.terminal-process-reaper",
        qos: .utility,
        attributes: .concurrent
    )
    private static let gracePeriodNanoseconds: UInt64 = 2_000_000_000

    static func reap(processID: pid_t) {
        guard processID > 0 else { return }
        queue.async {
            var status: Int32 = 0
            let deadline = DispatchTime.now().uptimeNanoseconds
                + gracePeriodNanoseconds
            while true {
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID { return }
                if result == -1 {
                    if errno == EINTR { continue }
                    return
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    _ = kill(processID, SIGKILL)
                    repeat {
                        errno = 0
                    } while waitpid(processID, &status, 0) == -1
                        && errno == EINTR
                    return
                }
                usleep(50_000)
            }
        }
    }
}

private enum TerminalProcessEnvironment {
    static func inherited(overrides: [String: String]) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment.merge(overrides, uniquingKeysWith: { _, override in override })
        return environment.map { "\($0.key)=\($0.value)" }
    }
}
