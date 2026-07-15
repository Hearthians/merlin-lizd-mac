import Darwin
import Foundation
@testable import MerlinLizdCodexAdapter

actor ScriptedAppServerProcess: AppServerProcessRunning {
    private let failStart: Bool
    private let gateStart: Bool
    private var started = false
    private var terminated = false
    private var writes: [Data] = []
    private var events: [AppServerProcessEvent] = []
    private var eventWaiters: [CheckedContinuation<AppServerProcessEvent?, Never>] = []
    private var writeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var termination = AppServerProcessTermination(exitCode: 0)
    private var terminateCalls = 0
    private var waitCalls = 0
    private var startCalls = 0
    private var startGates: [CheckedContinuation<Void, Never>] = []
    private var startCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    init(failStart: Bool = false, gateStart: Bool = false) {
        self.failStart = failStart
        self.gateStart = gateStart
    }

    func start() async throws {
        startCalls += 1
        resumeStartCountWaiters()
        if gateStart {
            await withCheckedContinuation { startGates.append($0) }
        }
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

    func waitForStartCount(_ count: Int) async {
        if startCalls >= count { return }
        await withCheckedContinuation { startCountWaiters.append((count, $0)) }
    }

    func releaseStart() {
        let gates = startGates
        startGates.removeAll()
        for gate in gates { gate.resume() }
    }

    func writtenData() -> [Data] { writes }
    func lifecycleCounts() -> (terminate: Int, wait: Int) {
        (terminateCalls, waitCalls)
    }

    func startCallCount() -> Int { startCalls }

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

    private func resumeStartCountWaiters() {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in startCountWaiters {
            if startCalls >= waiter.0 {
                waiter.1.resume()
            } else {
                retained.append(waiter)
            }
        }
        startCountWaiters = retained
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
    fileAccepted: Bool,
    fifoAccepted: Bool,
    socketAccepted: Bool,
    deviceAccepted: Bool,
    symlinkAccepted: Bool,
    resolvedSymlinkPath: String?,
    filePath: String
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("codex", isDirectory: false)
    let fifo = root.appendingPathComponent("codex-fifo", isDirectory: false)
    let socketURL = root.appendingPathComponent(
        "codex-socket",
        isDirectory: false
    )
    let symlink = root.appendingPathComponent("codex-link", isDirectory: false)
    try Data().write(to: file)
    guard mkfifo(fifo.path, 0o755) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    try FileManager.default.createSymbolicLink(
        at: symlink,
        withDestinationURL: file
    )
    let socketDescriptor = try createUnixSocket(at: socketURL)
    defer { _ = Darwin.close(socketDescriptor) }
    _ = chmod(root.path, 0o755)
    _ = chmod(file.path, 0o755)
    let checker = FoundationCodexExecutableFileChecker()
    return (
        checker.isExecutableFile(at: root),
        checker.isExecutableFile(at: file),
        checker.isExecutableFile(at: fifo),
        checker.isExecutableFile(at: socketURL),
        checker.isExecutableFile(at: URL(fileURLWithPath: "/dev/null")),
        checker.isExecutableFile(at: symlink),
        checker.resolvedExecutable(at: symlink)?.path,
        file.path
    )
}

private func createUnixSocket(at url: URL) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let path = url.path.utf8CString
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        _ = Darwin.close(descriptor)
        throw CocoaError(.fileWriteInvalidFileName)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        path.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else {
        _ = Darwin.close(descriptor)
        throw CocoaError(.fileWriteUnknown)
    }
    _ = chmod(url.path, 0o755)
    return descriptor
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
    private let ignoreCancellationFor: Duration?
    private var paths: [String] = []
    private var remainingDurations: [Duration] = []
    private var cancelled = false

    init(
        output: String = "codex-cli 0.144.2\n",
        suspendUntilCancelled: Bool = false,
        ignoreCancellationFor: Duration? = nil
    ) {
        self.output = output
        self.suspendUntilCancelled = suspendUntilCancelled
        self.ignoreCancellationFor = ignoreCancellationFor
    }

    func versionOutput(
        executable: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        paths.append(executable.path)
        remainingDurations.append(ContinuousClock.now.duration(to: deadline))
        if let ignoreCancellationFor {
            let end = ContinuousClock.now.advanced(by: ignoreCancellationFor)
            while ContinuousClock.now < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return output
        }
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
        case .outputOverflow: break
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

private actor CompletionProbe {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

func exerciseUnconsumedOutputProcess() async throws -> (
    completedBeforeConsumption: Bool,
    sawOverflow: Bool
) {
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "dd if=/dev/zero bs=16384 count=40 2>/dev/null",
        ],
        environment: [:]
    )
    try await process.start()
    let completion = CompletionProbe()
    let waiter = Task {
        let result = await process.waitForTermination()
        await completion.markCompleted()
        return result
    }
    try await Task.sleep(for: .milliseconds(200))
    let completedBeforeConsumption = await completion.isCompleted()

    var sawOverflow = false
    while let event = await process.nextEvent() {
        if case .outputOverflow = event { sawOverflow = true }
    }
    _ = await waiter.value
    return (completedBeforeConsumption, sawOverflow)
}

func exerciseBlockedStdinTermination() async throws -> (
    terminationWasPrompt: Bool,
    writeFailed: Bool
) {
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 1"],
        environment: [:]
    )
    try await process.start()
    let write = Task {
        try await process.write(Data(repeating: 0x61, count: 4 * 1_024 * 1_024))
    }
    try await Task.sleep(for: .milliseconds(30))
    let completion = CompletionProbe()
    let termination = Task {
        await process.terminate()
        await completion.markCompleted()
    }
    try await Task.sleep(for: .milliseconds(200))
    let terminationWasPrompt = await completion.isCompleted()
    await termination.value
    _ = await process.waitForTermination()
    let writeFailed: Bool
    do {
        try await write.value
        writeFailed = false
    } catch {
        writeFailed = true
    }
    return (terminationWasPrompt, writeFailed)
}

func exerciseDescendantPipeLifetimeIsBounded() async throws -> Bool {
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "(sleep 1) & exit 0"],
        environment: [:]
    )
    try await process.start()
    let completion = CompletionProbe()
    let waiter = Task {
        let result = await process.waitForTermination()
        await completion.markCompleted()
        return result
    }
    try await Task.sleep(for: .milliseconds(200))
    let bounded = await completion.isCompleted()
    if !bounded {
        while await process.nextEvent() != nil {}
    }
    _ = await waiter.value
    return bounded
}

func exerciseFIFOProcessWrites() async throws -> (
    matches: Bool,
    outputByteCount: Int,
    expectedByteCount: Int
) {
    let first = Data(repeating: 0x61, count: 128 * 1_024)
    let second = Data("second".utf8)
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [
            "-c", "import sys,time; time.sleep(0.1); data=sys.stdin.buffer.read(131078); sys.stdout.buffer.write(data)",
        ],
        environment: [:]
    )
    try await process.start()
    let firstWrite = Task { try await process.write(first) }
    try await Task.sleep(for: .milliseconds(20))
    let secondWrite = Task { try await process.write(second) }

    var output = Data()
    while let event = await process.nextEvent() {
        if case let .standardOutput(data) = event { output.append(data) }
    }
    try await firstWrite.value
    try await secondWrite.value
    _ = await process.waitForTermination()
    let expected = first + second
    return (output == expected, output.count, expected.count)
}

func exerciseProcessDescriptorCleanup() async throws -> (
    afterLaunchFailures: Int,
    afterTermination: Int
) {
    let baseline = try openDescriptorCount()
    var failed: [AppServerProcess] = []
    for index in 0..<8 {
        let process = AppServerProcess(
            executable: URL(fileURLWithPath: "/missing/codex-\(index)"),
            arguments: [],
            environment: [:]
        )
        do {
            try await process.start()
        } catch AppServerProcessError.launchFailed {
            failed.append(process)
        }
    }
    let afterLaunchFailures = try openDescriptorCount() - baseline

    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 1"],
        environment: [:]
    )
    try await process.start()
    await process.terminate()
    _ = await process.waitForTermination()
    let afterTermination = try openDescriptorCount() - baseline
    _ = failed
    return (afterLaunchFailures, afterTermination)
}

private func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}
