import Darwin
import Foundation
import MerlinLizdCore
@preconcurrency import SwiftTerm

@MainActor
final class TerminalSession: Identifiable, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
        case closed
    }

    typealias TitleHandler = @MainActor (String) -> Void
    typealias ProcessExitHandler = @MainActor (Int32?) -> Void

    let id: UUID
    let terminalView: LocalProcessTerminalView

    private let command: CommandSpec
    private let currentDirectory: String?

    private(set) var state: State = .idle
    private(set) var title: String?
    private(set) var hasStarted = false
    private var didReportExit = false

    var onTitleChange: TitleHandler?
    var onProcessExit: ProcessExitHandler?

    init(
        id: UUID = UUID(),
        command: CommandSpec,
        currentDirectory: String? = nil,
        onTitleChange: TitleHandler? = nil,
        onProcessExit: ProcessExitHandler? = nil
    ) {
        self.id = id
        self.command = command
        self.currentDirectory = currentDirectory
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
        terminalView.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: TerminalProcessEnvironment.inherited(),
            currentDirectory: currentDirectory
        )
        state = .running
    }

    /// Ends the local process for a terminal tab that the user explicitly closed.
    /// Merely hiding or removing the SwiftUI host must not call this method.
    func close() {
        guard state != .closed else {
            return
        }

        let shouldTerminate = state == .running && terminalView.process.running
        let processID = shouldTerminate ? terminalView.process.shellPid : 0
        state = .closed

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
    static func inherited() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"

        return environment.map { key, value in
            "\(key)=\(value)"
        }
    }
}
