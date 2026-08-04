import Darwin
import Combine
import Foundation
import MerlinLizdCore
@preconcurrency import SwiftTerm

@MainActor
final class TerminalSession: ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    enum StartupBlock: Equatable, Sendable {
        case sshUnavailable
        case workerNotReady
        case tmuxUnavailable
    }

    enum LaunchMode: Equatable, Sendable {
        case requestedCommand
        case plainSSH
    }

    enum StartupDisposition: Equatable, Sendable {
        case startRequestedCommand
        case blocked(StartupBlock)
    }

    enum State: Equatable {
        case idle
        case preparing
        case blocked(StartupBlock)
        case running(LaunchMode)
        case exited(Int32?)
        case closed
    }

    typealias TitleHandler = @MainActor (String) -> Void
    typealias ProcessExitHandler = @MainActor (Int32?) -> Void
    typealias StartPreparation = @Sendable (Bool) async -> StartupDisposition

    let id: UUID
    let terminalView: LocalProcessTerminalView

    private let requestedCommand: CommandSpec
    private let plainSSHCommand: CommandSpec?
    private let currentDirectory: String?
    private let terminalType: String
    private let startPreparation: StartPreparation?

    @Published private(set) var state: State = .idle
    private(set) var title: String?
    private(set) var hasStarted = false
    private var didReportExit = false
    private var startupTask: Task<Void, Never>?

    var onTitleChange: TitleHandler?
    var onProcessExit: ProcessExitHandler?

    init(
        id: UUID = UUID(),
        command: CommandSpec,
        plainSSHCommand: CommandSpec? = nil,
        currentDirectory: String? = nil,
        terminalType: String = "xterm-256color",
        startPreparation: StartPreparation? = nil,
        onTitleChange: TitleHandler? = nil,
        onProcessExit: ProcessExitHandler? = nil
    ) {
        self.id = id
        requestedCommand = command
        self.plainSSHCommand = plainSSHCommand
        self.currentDirectory = currentDirectory
        self.terminalType = terminalType
        self.startPreparation = startPreparation
        self.onTitleChange = onTitleChange
        self.onProcessExit = onProcessExit

        let terminalView = LocalProcessTerminalView(frame: .zero)
        self.terminalView = terminalView
        terminalView.processDelegate = self
    }

    func startIfNeeded() {
        guard !hasStarted, state != .closed else {
            return
        }

        hasStarted = true
        beginStartup(forceRetry: false)
    }

    func retryRequestedCommand() {
        guard case .blocked = state else { return }
        beginStartup(forceRetry: true)
    }

    func startPlainSSH() {
        guard
            case .blocked(.tmuxUnavailable) = state,
            let plainSSHCommand
        else { return }
        startupTask?.cancel()
        startupTask = nil
        startProcess(command: plainSSHCommand, mode: .plainSSH)
    }

    private func beginStartup(forceRetry: Bool) {
        guard state != .closed else { return }
        guard let startPreparation else {
            startProcess(command: requestedCommand, mode: .requestedCommand)
            return
        }

        state = .preparing
        startupTask = Task { [weak self] in
            let disposition = await startPreparation(forceRetry)
            guard
                !Task.isCancelled,
                let self,
                self.state != .closed
            else { return }

            self.startupTask = nil
            switch disposition {
            case .startRequestedCommand:
                self.startProcess(
                    command: self.requestedCommand,
                    mode: .requestedCommand
                )
            case let .blocked(reason):
                self.state = .blocked(reason)
            }
        }
    }

    private func startProcess(command: CommandSpec, mode: LaunchMode) {
        terminalView.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: TerminalProcessEnvironment.inherited(terminalType: terminalType),
            currentDirectory: currentDirectory
        )
        state = .running(mode)
    }

    /// Ends the local process for a terminal tab that the user explicitly closed.
    /// Merely hiding or removing the SwiftUI host must not call this method.
    func close() {
        guard state != .closed else {
            return
        }

        let isRunning: Bool
        if case .running = state {
            isRunning = true
        } else {
            isRunning = false
        }
        let shouldTerminate = isRunning && terminalView.process.running
        let processID = shouldTerminate ? terminalView.process.shellPid : 0
        state = .closed
        startupTask?.cancel()
        startupTask = nil

        // LocalProcess retains its last PID after exit. Calling terminate() when
        // it is no longer running could therefore signal an unrelated reused PID.
        // Checking our state as well also makes close() safe when an exit callback
        // closes its tab before SwiftTerm has updated LocalProcess.running.
        if shouldTerminate {
            terminalView.terminate()
            TerminalProcessReaper.reap(processID: processID)
        }

        terminalView.processDelegate = nil
        onTitleChange = nil
        onProcessExit = nil
    }

    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.receiveTerminalTitle(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.receiveProcessTermination(exitCode: exitCode)
        }
    }

    private func receiveTerminalTitle(_ title: String) {
        guard state != .closed else {
            return
        }

        self.title = title
        onTitleChange?(title)
    }

    private func receiveProcessTermination(exitCode: Int32?) {
        guard state != .closed, !didReportExit else {
            return
        }

        didReportExit = true
        state = .exited(exitCode)
        onProcessExit?(exitCode)
    }
}

private enum TerminalProcessReaper {
    private static let queue = DispatchQueue(
        label: "com.merlin-lizd.terminal-process-reaper",
        qos: .utility,
        attributes: .concurrent
    )
    private static let gracePeriodNanoseconds: UInt64 = 2_000_000_000

    /// SwiftTerm 1.14 closes its process monitor in terminate() without waiting
    /// for the direct child. Reap that child here and escalate only while it is
    /// still ours; an unreaped child PID cannot be reused by the system. SwiftTerm
    /// exposes only that direct PID, so descendant process-group cleanup remains
    /// an upstream limitation. Merlin remote sessions directly launch ssh.
    static func reap(processID: pid_t) {
        guard processID > 0 else {
            return
        }

        queue.async {
            var status: Int32 = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + gracePeriodNanoseconds

            while true {
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID {
                    return
                }
                if result == -1 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }

                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    _ = kill(processID, SIGKILL)
                    repeat {
                        errno = 0
                    } while waitpid(processID, &status, 0) == -1 && errno == EINTR
                    return
                }

                usleep(50_000)
            }
        }
    }
}

private enum TerminalProcessEnvironment {
    static func inherited(terminalType: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = terminalType
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"

        return environment.map { key, value in
            "\(key)=\(value)"
        }
    }
}
