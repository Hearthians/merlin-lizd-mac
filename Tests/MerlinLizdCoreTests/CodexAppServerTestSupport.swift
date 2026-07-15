import Darwin
import Foundation
@testable import MerlinLizdCodexAdapter

actor ScriptedAppServerProcess: AppServerProcessRunning {
    private let failStart: Bool
    private var started = false
    private var terminated = false
    private var writes: [Data] = []
    private var events: [AppServerProcessEvent] = []
    private var eventWaiters: [CheckedContinuation<AppServerProcessEvent?, Never>] = []
    private var writeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var termination = AppServerProcessTermination(exitCode: 0)
    private var terminateCalls = 0
    private var waitCalls = 0

    init(failStart: Bool = false) {
        self.failStart = failStart
    }

    func start() async throws {
        if failStart { throw ScriptedAppServerProcessError.startFailed }
        started = true
    }

    func write(_ data: Data) async throws {
        guard started, !terminated else {
            throw ScriptedAppServerProcessError.notWritable
        }
        writes.append(data)
        resumeWriteWaiters()
    }

    func nextEvent() async -> AppServerProcessEvent? {
        if !events.isEmpty {
            return events.removeFirst()
        }
        if terminated { return nil }
        return await withCheckedContinuation { eventWaiters.append($0) }
    }

    func terminate() async {
        terminateCalls += 1
        guard !terminated else { return }
        terminated = true
        resumeEventWaitersWithEnd()
    }

    func waitForTermination() async -> AppServerProcessTermination {
        waitCalls += 1
        return termination
    }

    func emit(_ event: AppServerProcessEvent) {
        if case let .terminated(exitCode) = event {
            termination = .init(exitCode: exitCode)
            terminated = true
        }
        if !eventWaiters.isEmpty {
            eventWaiters.removeFirst().resume(returning: event)
        } else {
            events.append(event)
        }
        if terminated {
            resumeEventWaitersWithEnd()
        }
    }

    func waitForWriteCount(_ count: Int) async {
        if writes.count >= count { return }
        await withCheckedContinuation { writeWaiters.append((count, $0)) }
    }

    func writtenData() -> [Data] { writes }
    func lifecycleCounts() -> (terminate: Int, wait: Int) {
        (terminateCalls, waitCalls)
    }

    private func resumeWriteWaiters() {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in writeWaiters {
            if writes.count >= waiter.0 {
                waiter.1.resume()
            } else {
                retained.append(waiter)
            }
        }
        writeWaiters = retained
    }

    private func resumeEventWaitersWithEnd() {
        guard events.isEmpty else { return }
        let waiters = eventWaiters
        eventWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }
}

enum ScriptedAppServerProcessError: Error {
    case startFailed
    case notWritable
}

func testURL(_ path: String) -> URL {
    URL(fileURLWithPath: path)
}

func exerciseFoundationExecutableChecker() throws -> (
    directoryAccepted: Bool,
    fileAccepted: Bool
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("codex", isDirectory: false)
    try Data().write(to: file)
    _ = chmod(root.path, 0o755)
    _ = chmod(file.path, 0o755)
    let checker = FoundationCodexExecutableFileChecker()
    return (
        checker.isExecutableFile(at: root),
        checker.isExecutableFile(at: file)
    )
}

struct ScriptedCodexFileChecker: CodexExecutableFileChecking {
    let executablePaths: Set<String>

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
    }

    init(executablePaths: [String]) {
        self.executablePaths = Set(executablePaths)
    }

    func isExecutableFile(at url: URL) -> Bool {
        executablePaths.contains(url.path)
    }
}

actor ScriptedCodexVersionProbe: CodexVersionProbing {
    private let output: String
    private let suspendUntilCancelled: Bool
    private var paths: [String] = []
    private var remainingDurations: [Duration] = []
    private var cancelled = false

    init(
        output: String = "codex-cli 0.144.2\n",
        suspendUntilCancelled: Bool = false
    ) {
        self.output = output
        self.suspendUntilCancelled = suspendUntilCancelled
    }

    func versionOutput(
        executable: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        paths.append(executable.path)
        remainingDurations.append(ContinuousClock.now.duration(to: deadline))
        if suspendUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled = true
                throw error
            }
        }
        return output
    }

    func probedPaths() -> [String] { paths }
    func recordedRemainingDurations() -> [Duration] { remainingDurations }
    func wasCancelled() -> Bool { cancelled }
}

func jsonObject(from data: Data) throws -> [String: Any] {
    let line = data.last == 0x0A ? data.dropLast() : data[...]
    return try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
}

func jsonLine(_ string: String) -> Data {
    Data((string + "\n").utf8)
}

func jsonRequestMethodsByIntegerID(
    _ lines: [Data]
) throws -> [Int: String] {
    Dictionary(uniqueKeysWithValues: try lines.map {
        let object = try jsonObject(from: $0)
        return ((object["id"] as! NSNumber).intValue, object["method"] as! String)
    })
}

func jsonRPCStringID(_ line: Data) throws -> String? {
    try jsonObject(from: line)["id"] as? String
}

func jsonRPCErrorCode(_ line: Data) throws -> Int? {
    let object = try jsonObject(from: line)
    let error = object["error"] as? [String: Any]
    return (error?["code"] as? NSNumber)?.intValue
}

func testData(_ string: String) -> Data { Data(string.utf8) }
func testBytes(_ bytes: [UInt8]) -> Data { Data(bytes) }
func testRepeatedData(_ byte: UInt8, count: Int) -> Data {
    Data(repeating: byte, count: count)
}
func testPatternedData(count: Int, modulus: Int) -> Data {
    Data((0..<count).map { UInt8($0 % modulus) })
}
func testPrefix(_ data: Data, count: Int) -> Data { Data(data.prefix(count)) }
func testDropFirst(_ data: Data, count: Int) -> Data {
    Data(data.dropFirst(count))
}
func testSuffix(_ data: Data, count: Int) -> Data { Data(data.suffix(count)) }

func notificationLines(count: Int) -> Data {
    Data((0..<count).map {
        "{\"jsonrpc\":\"2.0\",\"method\":\"event/\($0)\"}\n"
    }.joined().utf8)
}

func exerciseConcreteAppServerProcess() async throws -> (
    standardOutput: String,
    standardError: String,
    firstExitCode: Int32,
    secondExitCode: Int32
) {
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "printf 'before:'; printf 'diagnostic' >&2; IFS= read -r line; printf '%s\\n' \"$line\"",
        ],
        environment: [:]
    )
    try await process.start()
    try await process.write(Data("hello\n".utf8))
    var output = Data()
    var error = Data()
    while let event = await process.nextEvent() {
        switch event {
        case let .standardOutput(data): output.append(data)
        case let .standardError(data): error.append(data)
        case .terminated: break
        }
    }
    let first = await process.waitForTermination()
    let second = await process.waitForTermination()
    return (
        String(decoding: output, as: UTF8.self),
        String(decoding: error, as: UTF8.self),
        first.exitCode,
        second.exitCode
    )
}

func exerciseTermResistantAppServerProcess() async throws -> (
    exitCode: Int32,
    elapsed: Duration
) {
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do :; done"],
        environment: [:]
    )
    try await process.start()
    let clock = ContinuousClock()
    let started = clock.now
    async let first: Void = process.terminate()
    async let second: Void = process.terminate()
    _ = await (first, second)
    let termination = await process.waitForTermination()
    return (termination.exitCode, started.duration(to: clock.now))
}
