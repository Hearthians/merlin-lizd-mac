import Darwin
import Foundation
@testable import MerlinLizdCodexAdapter

actor ScriptedAppServerProcess: AppServerProcessRunning {
    private let failStart: Bool
    private let gateStart: Bool
    private let writeError: AppServerProcessError?
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
    private var activeEventConsumers = 0
    private var maximumActiveEventConsumers = 0
    private var startGates: [CheckedContinuation<Void, Never>] = []
    private var startCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    init(
        failStart: Bool = false,
        gateStart: Bool = false,
        writeError: AppServerProcessError? = nil
    ) {
        self.failStart = failStart
        self.gateStart = gateStart
        self.writeError = writeError
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
        if let writeError { throw writeError }
        writes.append(data)
        resumeWriteWaiters()
    }

    func nextEvent(receiverID: UUID) async -> AppServerProcessEvent? {
        activeEventConsumers += 1
        maximumActiveEventConsumers = max(
            maximumActiveEventConsumers,
            activeEventConsumers
        )
        defer { activeEventConsumers -= 1 }
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
    func activeEventConsumerCount() -> Int { activeEventConsumers }
    func maximumActiveEventConsumerCount() -> Int {
        maximumActiveEventConsumers
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

actor CancellationRecordingAppServerProcess: AppServerProcessRunning {
    private var started = false
    private var terminated = false
    private var writes = 0
    private var cancellations = 0
    private var writeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    func start() { started = true }

    func write(_ data: Data) async throws {
        guard started, !terminated else {
            throw ScriptedAppServerProcessError.notWritable
        }
        writes += 1
        resumeCountWaiters(&writeWaiters, current: writes)
        do {
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
            } onCancel: {
                Task { await self.recordWriteCancellation() }
            }
        } catch {
            throw CancellationError()
        }
    }

    func nextEvent(receiverID: UUID) async -> AppServerProcessEvent? {
        while !terminated {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func terminate() { terminated = true }

    func waitForTermination() async -> AppServerProcessTermination {
        .init(exitCode: 0)
    }

    func waitForWriteCount(_ count: Int) async {
        if writes >= count { return }
        await withCheckedContinuation { writeWaiters.append((count, $0)) }
    }

    func waitForWriteCancellationCount(_ count: Int) async {
        if cancellations >= count { return }
        await withCheckedContinuation {
            cancellationWaiters.append((count, $0))
        }
    }

    func writeCancellationCount() -> Int { cancellations }

    private func recordWriteCancellation() {
        cancellations += 1
        resumeCountWaiters(&cancellationWaiters, current: cancellations)
    }

    private func resumeCountWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        current: Int
    ) {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if current >= waiter.0 { waiter.1.resume() } else { retained.append(waiter) }
        }
        waiters = retained
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
    private let gateStarts: Bool
    private var paths: [String] = []
    private var remainingDurations: [Duration] = []
    private var cancelled = false
    private var starts = 0
    private var completions = 0
    private var cancellationSignals = 0
    private var startGates: [CheckedContinuation<Void, Never>] = []
    private var startCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var completionCountWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []

    init(
        output: String = "codex-cli 0.144.2\n",
        suspendUntilCancelled: Bool = false,
        ignoreCancellationFor: Duration? = nil,
        gateStarts: Bool = false
    ) {
        self.output = output
        self.suspendUntilCancelled = suspendUntilCancelled
        self.ignoreCancellationFor = ignoreCancellationFor
        self.gateStarts = gateStarts
    }

    func versionOutput(
        executable: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        starts += 1
        resumeStartCountWaiters()
        paths.append(executable.path)
        remainingDurations.append(ContinuousClock.now.duration(to: deadline))
        if gateStarts {
            await withTaskCancellationHandler {
                await withCheckedContinuation { startGates.append($0) }
            } onCancel: {
                Task { await self.recordCancellationSignal() }
            }
            completions += 1
            resumeCompletionCountWaiters()
            return output
        }
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
    func startCount() -> Int { starts }
    func cancellationSignalCount() -> Int { cancellationSignals }

    func waitForStartCount(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { startCountWaiters.append((count, $0)) }
    }

    func waitForCompletionCount(_ count: Int) async {
        if completions >= count { return }
        await withCheckedContinuation {
            completionCountWaiters.append((count, $0))
        }
    }

    func releaseNextStart() {
        guard !startGates.isEmpty else { return }
        startGates.removeFirst().resume()
    }

    private func recordCancellationSignal() { cancellationSignals += 1 }

    private func resumeStartCountWaiters() {
        resumeCountWaiters(&startCountWaiters, current: starts)
    }

    private func resumeCompletionCountWaiters() {
        resumeCountWaiters(&completionCountWaiters, current: completions)
    }

    private func resumeCountWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        current: Int
    ) {
        var retained: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if current >= waiter.0 { waiter.1.resume() } else { retained.append(waiter) }
        }
        waiters = retained
    }
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
    return try await withProcessTestDeadline(process) {
        try await process.start()
        try await process.write(Data("hello\n".utf8))
        var output = Data()
        var error = Data()
        let receiverID = UUID()
        while let event = await process.nextEvent(receiverID: receiverID) {
            switch event {
            case let .standardOutput(data): output.append(data)
            case let .standardError(data): error.append(data)
            case .outputOverflow: break
            case .outputDrainLimitExceeded: break
            case .eventConsumerUnavailable: break
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
    return try await withProcessTestDeadline(process) {
        try await process.start()
        let clock = ContinuousClock()
        let started = clock.now
        async let first: Void = process.terminate()
        async let second: Void = process.terminate()
        _ = await (first, second)
        let termination = await process.waitForTermination()
        return (termination.exitCode, started.duration(to: clock.now))
    }
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
    return try await withProcessTestDeadline(process) {
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
        let receiverID = UUID()
        while let event = await process.nextEvent(receiverID: receiverID) {
            if case .outputOverflow = event { sawOverflow = true }
        }
        _ = await waiter.value
        return (completedBeforeConsumption, sawOverflow)
    }
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
    return try await withProcessTestDeadline(process) {
        try await process.start()
        let write = Task {
            try await process.write(Data(
                repeating: 0x61,
                count: 4 * 1_024 * 1_024
            ))
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
}

func exerciseRunningTransportOwnerLoss() async throws -> (
    transportReleased: Bool,
    terminateCalls: Int,
    waitCalls: Int,
    eventConsumerExited: Bool
) {
    let process = ScriptedAppServerProcess()
    var transport: JSONLAppServerTransport? = JSONLAppServerTransport(
        process: process
    )
    try await transport?.start()
    while await process.activeEventConsumerCount() == 0 { await Task.yield() }
    weak let weakTransport = transport
    transport = nil
    let transportReleased = await waitForWeakRelease { weakTransport == nil }
    try await waitForLifecycleCounts(process, terminate: 1, wait: 1)
    let counts = await process.lifecycleCounts()
    return (
        transportReleased,
        counts.terminate,
        counts.wait,
        await process.activeEventConsumerCount() == 0
    )
}

func exerciseCancelledStartOwnerLoss() async throws -> (
    transportReleased: Bool,
    terminateCalls: Int,
    waitCalls: Int
) {
    let process = ScriptedAppServerProcess(gateStart: true)
    var transport: JSONLAppServerTransport? = JSONLAppServerTransport(
        process: process
    )
    let start = Task { [weak transport] in try await transport?.start() }
    await process.waitForStartCount(1)
    start.cancel()
    _ = try? await start.value
    weak let weakTransport = transport
    transport = nil
    let transportReleased = await waitForWeakRelease { weakTransport == nil }
    try await waitForLifecycleCounts(process, terminate: 1, wait: 1)
    await process.releaseStart()
    let counts = await process.lifecycleCounts()
    return (transportReleased, counts.terminate, counts.wait)
}

func exerciseConcreteProcessOwnerLoss() async throws -> (
    processReleased: Bool,
    leaderExited: Bool
) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("leader.pid")
    let cleanup = ExactPIDTestCleanup()
    var process: AppServerProcess? = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "echo $$ > '\(pidFile.path)'; exec /bin/sleep 30",
        ],
        environment: [:]
    )
    try await process?.start()
    let processID = try await readProcessID(from: pidFile)
    guard let identity = await captureFixtureProcessIdentity(
        processID: processID,
        expectedExecutable: .exactPath("/bin/sleep")
    ) else {
        throw ProcessTestDeadlineError.timedOut
    }
    cleanup.register(identity)
    weak let weakProcess = process
    process = nil
    let processReleased = await waitForWeakRelease { weakProcess == nil }
    let leaderExited = await waitForOriginalProcessExit(
        identity,
        identityAccess: .live,
        timeout: .milliseconds(500)
    )
    if leaderExited { cleanup.disarm() }
    return (processReleased, leaderExited)
}

func exerciseBufferedEventConsumerExclusivity() async -> Bool {
    let channel = BoundedProcessEventChannel(capacity: 2)
    let firstID = UUID()
    let secondID = UUID()
    _ = await channel.offer(.standardOutput(Data([0x61])))
    _ = await channel.next(receiverID: firstID)
    _ = await channel.offer(.standardOutput(Data([0x62])))
    guard let second = await channel.next(receiverID: secondID) else {
        return false
    }
    if case .eventConsumerUnavailable = second { return true }
    return false
}

func exerciseWaitingEventConsumerExclusivity() async -> Bool {
    let channel = BoundedProcessEventChannel(capacity: 2)
    let first = Task { await channel.next(receiverID: UUID()) }
    while await channel.pendingReceiverCountForTesting == 0 {
        await Task.yield()
    }
    let second = await channel.next(receiverID: UUID())
    _ = await channel.offer(.standardOutput(Data([0x61])))
    _ = await first.value
    guard let second else { return false }
    if case .eventConsumerUnavailable = second { return true }
    return false
}

private func waitForLifecycleCounts(
    _ process: ScriptedAppServerProcess,
    terminate: Int,
    wait: Int
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while true {
        let counts = await process.lifecycleCounts()
        if counts.terminate >= terminate, counts.wait >= wait { return }
        guard ContinuousClock.now < deadline else {
            throw ProcessTestDeadlineError.timedOut
        }
        await Task.yield()
    }
}

private func waitForWeakRelease(
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private func readProcessID(from file: URL) async throws -> Int32 {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8),
            let processID = Int32(text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ))
        {
            return processID
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    throw ProcessTestDeadlineError.timedOut
}

struct FixtureProcessIdentity: Equatable, Sendable {
    let processID: Int32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
    let executablePath: String
}

enum FixtureExecutableExpectation: Sendable {
    case exactPath(String)
    case fileNamePrefix(String)

    func matches(_ identity: FixtureProcessIdentity) -> Bool {
        switch self {
        case let .exactPath(path):
            return identity.executablePath == path
        case let .fileNamePrefix(prefix):
            return URL(fileURLWithPath: identity.executablePath)
                .lastPathComponent
                .hasPrefix(prefix)
        }
    }
}

struct FixtureProcessIdentityAccess: @unchecked Sendable {
    typealias IdentityReader = @Sendable (Int32) -> FixtureProcessIdentity?
    typealias SignalSender = @Sendable (Int32, Int32) -> Int32

    private let identityReader: IdentityReader
    private let signalSender: SignalSender

    init(
        identityReader: @escaping IdentityReader,
        signalSender: @escaping SignalSender
    ) {
        self.identityReader = identityReader
        self.signalSender = signalSender
    }

    func capture(
        processID: Int32,
        expectedExecutable: FixtureExecutableExpectation
    ) -> FixtureProcessIdentity? {
        guard processID > 1,
            let identity = identityReader(processID),
            identity.processID == processID,
            expectedExecutable.matches(identity)
        else {
            return nil
        }
        return identity
    }

    func originalProcessIsGone(_ identity: FixtureProcessIdentity) -> Bool {
        identityReader(identity.processID) != identity
    }

    @discardableResult
    func sendIfIdentityMatches(
        _ signal: Int32,
        to identity: FixtureProcessIdentity
    ) -> Bool {
        guard identity.processID > 1,
            identityReader(identity.processID) == identity
        else {
            return false
        }
        return signalSender(identity.processID, signal) == 0
    }

    static let live = FixtureProcessIdentityAccess(
        identityReader: { processID in
            guard processID > 1 else { return nil }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                &info,
                infoSize
            ) == infoSize else {
                return nil
            }
            var path = [UInt8](
                repeating: 0,
                count: 4 * Int(MAXPATHLEN)
            )
            let pathLength = path.withUnsafeMutableBytes { buffer in
                proc_pidpath(
                    processID,
                    buffer.baseAddress,
                    UInt32(buffer.count)
                )
            }
            guard pathLength > 0 else { return nil }
            return FixtureProcessIdentity(
                processID: processID,
                startTimeSeconds: info.pbi_start_tvsec,
                startTimeMicroseconds: info.pbi_start_tvusec,
                executablePath: String(
                    decoding: path.prefix(Int(pathLength)),
                    as: UTF8.self
                )
            )
        },
        signalSender: { processID, signal in
            Darwin.kill(processID, signal)
        }
    )
}

private func captureFixtureProcessIdentity(
    processID: Int32,
    expectedExecutable: FixtureExecutableExpectation,
    access: FixtureProcessIdentityAccess = .live,
    timeout: Duration = .milliseconds(300)
) async -> FixtureProcessIdentity? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let identity = access.capture(
            processID: processID,
            expectedExecutable: expectedExecutable
        ) {
            return identity
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return access.capture(
        processID: processID,
        expectedExecutable: expectedExecutable
    )
}

private final class ExactPIDTestCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let identityAccess: FixtureProcessIdentityAccess
    private var identity: FixtureProcessIdentity?

    init(identityAccess: FixtureProcessIdentityAccess = .live) {
        self.identityAccess = identityAccess
    }

    func register(_ identity: FixtureProcessIdentity) {
        lock.withLock { self.identity = identity }
    }

    func disarm() { lock.withLock { identity = nil } }

    deinit {
        guard let identity = lock.withLock({ identity }) else { return }
        identityAccess.sendIfIdentityMatches(SIGKILL, to: identity)
    }
}

func exerciseBoundedStdinQueue() async throws -> (
    overflowWasTyped: Bool,
    maximumRetainedRequests: Int,
    maximumRetainedBytes: Int
) {
    let harness = try makeBlockedWriterHarness()
    let chunk = Data(repeating: 0x61, count: 128 * 1_024)
    let first = Task { try await harness.writer.write(chunk) }
    try await waitForRetainedWriteCount(harness.writer, count: 1)
    let second = Task { try await harness.writer.write(chunk) }
    try await waitForRetainedWriteCount(harness.writer, count: 2)
    let maximumRequests = await harness.writer.retainedRequestCountForTesting
    let maximumBytes = await harness.writer.retainedByteCountForTesting
    let overflowWasTyped: Bool
    do {
        try await harness.writer.write(Data([0x62]))
        overflowWasTyped = false
    } catch AppServerProcessError.writeQueueOverflow(
        maximumRequests: 2,
        maximumBytes: 256 * 1_024
    ) {
        overflowWasTyped = true
    }
    await harness.writer.close()
    _ = try? await first.value
    _ = try? await second.value
    return (overflowWasTyped, maximumRequests, maximumBytes)
}

func exerciseQueuedStdinCancellation() async throws -> (
    cancelledPromptly: Bool,
    replacementWasAccepted: Bool,
    outputPreservedFIFO: Bool
) {
    let harness = try makeBlockedWriterHarness()
    let firstData = Data(repeating: 0x61, count: 128 * 1_024)
    let cancelledData = Data(repeating: 0x62, count: 128 * 1_024)
    let replacementData = Data(repeating: 0x63, count: 128 * 1_024)
    let first = Task { try await harness.writer.write(firstData) }
    try await waitForRetainedWriteCount(harness.writer, count: 1)
    let cancelled = Task { try await harness.writer.write(cancelledData) }
    try await waitForRetainedWriteCount(harness.writer, count: 2)
    cancelled.cancel()
    let cancelledPromptly = await taskThrowsCancellation(cancelled)
    try await waitForRetainedWriteCount(harness.writer, count: 1)
    let replacement = Task { try await harness.writer.write(replacementData) }
    try await waitForRetainedWriteCount(harness.writer, count: 2)
    let replacementWasAccepted = await harness.writer.retainedByteCountForTesting
        == 256 * 1_024
    let output = await harness.reader.readExactly(256 * 1_024)
    try await first.value
    try await replacement.value
    await harness.writer.close()
    return (
        cancelledPromptly,
        replacementWasAccepted,
        output == firstData + replacementData
    )
}

func exerciseActiveStdinCancellation() async throws -> (
    cancelledPromptly: Bool,
    retainedActiveRequest: Bool,
    overflowWhileActive: Bool,
    outputIncludedCancelledActiveWrite: Bool
) {
    let harness = try makeBlockedWriterHarness()
    let firstData = Data(repeating: 0x61, count: 128 * 1_024)
    let secondData = Data(repeating: 0x62, count: 128 * 1_024)
    let first = Task { try await harness.writer.write(firstData) }
    try await waitForRetainedWriteCount(harness.writer, count: 1)
    first.cancel()
    let cancelledPromptly = await taskThrowsCancellation(first)
    let retainedRequestCount = await harness.writer.retainedRequestCountForTesting
    let retainedByteCount = await harness.writer.retainedByteCountForTesting
    let retainedActiveRequest = retainedRequestCount == 1
        && retainedByteCount == 128 * 1_024
    let second = Task { try await harness.writer.write(secondData) }
    try await waitForRetainedWriteCount(harness.writer, count: 2)
    let overflowWhileActive: Bool
    do {
        try await harness.writer.write(Data([0x63]))
        overflowWhileActive = false
    } catch AppServerProcessError.writeQueueOverflow {
        overflowWhileActive = true
    }
    let output = await harness.reader.readExactly(256 * 1_024)
    try await second.value
    await harness.writer.close()
    return (
        cancelledPromptly,
        retainedActiveRequest,
        overflowWhileActive,
        output == firstData + secondData
    )
}

func exerciseStdinTerminationRace() async throws -> (
    activeFailed: Bool,
    queuedFailed: Bool,
    retainedRequestsAfterClose: Int,
    physicalStarts: Int,
    newWriteWasRejected: Bool
) {
    let harness = try makeBlockedWriterHarness()
    let chunk = Data(repeating: 0x61, count: 128 * 1_024)
    let active = Task { try await harness.writer.write(chunk) }
    try await waitForRetainedWriteCount(harness.writer, count: 1)
    let queued = Task { try await harness.writer.write(chunk) }
    try await waitForRetainedWriteCount(harness.writer, count: 2)
    await harness.writer.close()
    let activeFailed = await taskThrowsWriteFailure(active)
    let queuedFailed = await taskThrowsWriteFailure(queued)
    let retained = await harness.writer.retainedRequestCountForTesting
    let starts = await harness.writer.physicalStartCountForTesting
    let newWriteWasRejected: Bool
    do {
        try await harness.writer.write(Data([0x62]))
        newWriteWasRejected = false
    } catch AppServerProcessError.notRunning {
        newWriteWasRejected = true
    }
    return (activeFailed, queuedFailed, retained, starts, newWriteWasRejected)
}

private struct BlockedWriterHarness {
    let writer: NonblockingFIFOFileWriter
    let reader: TestPipeReader
}

private func makeBlockedWriterHarness() throws -> BlockedWriterHarness {
    var descriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&descriptors) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    return BlockedWriterHarness(
        writer: NonblockingFIFOFileWriter(
            fileDescriptor: descriptors[1],
            maximumRetainedRequests: 2,
            maximumRetainedBytes: 256 * 1_024
        ),
        reader: TestPipeReader(fileDescriptor: descriptors[0])
    )
}

private final class TestPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32

    init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }

    func readExactly(_ byteCount: Int) async -> Data {
        await Task.detached { [self] in
            var result = Data()
            while result.count < byteCount {
                let chunk = lock.withLock { () -> Data in
                    guard fileDescriptor >= 0 else { return Data() }
                    let requested = min(
                        16 * 1_024,
                        byteCount - result.count
                    )
                    var data = Data(count: requested)
                    let count = data.withUnsafeMutableBytes { bytes in
                        Darwin.read(fileDescriptor, bytes.baseAddress, requested)
                    }
                    guard count > 0 else { return Data() }
                    data.removeSubrange(count..<data.count)
                    return data
                }
                guard !chunk.isEmpty else { break }
                result.append(chunk)
            }
            return result
        }.value
    }

    deinit {
        lock.withLock {
            if fileDescriptor >= 0 { _ = Darwin.close(fileDescriptor) }
            fileDescriptor = -1
        }
    }
}

private func waitForRetainedWriteCount(
    _ writer: NonblockingFIFOFileWriter,
    count: Int
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await writer.retainedRequestCountForTesting != count {
        guard ContinuousClock.now < deadline else {
            throw ProcessTestDeadlineError.timedOut
        }
        await Task.yield()
    }
}

private func taskThrowsCancellation(_ task: Task<Void, Error>) async -> Bool {
    do { try await task.value; return false } catch is CancellationError { return true } catch { return false }
}

private func taskThrowsWriteFailure(_ task: Task<Void, Error>) async -> Bool {
    do { try await task.value; return false } catch AppServerProcessError.writeFailed { return true } catch { return false }
}

func exerciseDescendantPipeLifetimeIsBounded() async throws -> Bool {
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "(sleep 1) & exit 0"],
        environment: [:]
    )
    return try await withProcessTestDeadline(process) {
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
            let receiverID = UUID()
            while await process.nextEvent(receiverID: receiverID) != nil {}
        }
        _ = await waiter.value
        return bounded
    }
}

func exerciseContinuousDescendantDrainDeadline() async throws -> (
    sawTypedDrainLimit: Bool,
    elapsed: Duration,
    descendantExited: Bool,
    descriptorDelta: Int
) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    let pidFile = root.appendingPathComponent("descendant.pid")
    let descendantCleanup = ContinuousDescendantFixtureCleanup(
        root: root,
        pidFile: pidFile
    )
    let baseline = try openDescriptorCount()
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            slowContinuousDescendantCommand(pidFile: pidFile),
        ],
        environment: [:],
        maximumPostLeaderDrainBytes: 1_024 * 1_024 * 1_024,
        maximumPostLeaderDrainDuration: .milliseconds(50)
    )
    let clock = ContinuousClock()
    let started = clock.now
    do {
        let processResult = try await withProcessTestDeadline(process) {
            try await process.start()
            let processID = try await readProcessID(from: pidFile)
            guard await descendantCleanup.register(processID: processID) else {
                throw ProcessTestDeadlineError.timedOut
            }
            var sawTypedDrainLimit = false
            let receiverID = UUID()
            while let event = await process.nextEvent(receiverID: receiverID) {
                if case .outputDrainLimitExceeded = event {
                    sawTypedDrainLimit = true
                }
            }
            _ = await process.waitForTermination()
            return (
                sawTypedDrainLimit,
                started.duration(to: clock.now)
            )
        }
        let cleanup = await descendantCleanup.cleanup(forceKill: false)
        return (
            processResult.0,
            processResult.1,
            cleanup.descendantExited,
            try openDescriptorCount() - baseline
        )
    } catch {
        _ = await descendantCleanup.cleanup(forceKill: true)
        throw error
    }
}

private enum ForcedDescendantFixtureError: Error { case forced }

func exerciseContinuousDescendantForcedFailure() async throws -> (
    descendantExited: Bool,
    directoryRemoved: Bool
) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    let pidFile = root.appendingPathComponent("descendant.pid")
    let descendantCleanup = ContinuousDescendantFixtureCleanup(
        root: root,
        pidFile: pidFile
    )
    let process = AppServerProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            slowContinuousDescendantCommand(pidFile: pidFile),
        ],
        environment: [:]
    )
    do {
        _ = try await withProcessTestDeadline(process) {
            try await process.start()
            let processID = try await readProcessID(from: pidFile)
            guard await descendantCleanup.register(processID: processID) else {
                throw ProcessTestDeadlineError.timedOut
            }
            throw ForcedDescendantFixtureError.forced
        }
    } catch ForcedDescendantFixtureError.forced {
        let cleanup = await descendantCleanup.cleanup(forceKill: true)
        return (
            cleanup.descendantExited,
            !FileManager.default.fileExists(atPath: root.path)
        )
    } catch {
        _ = await descendantCleanup.cleanup(forceKill: true)
        throw error
    }
    _ = await descendantCleanup.cleanup(forceKill: true)
    return (false, !FileManager.default.fileExists(atPath: root.path))
}

private func slowContinuousDescendantCommand(pidFile: URL) -> String {
    """
    trap '' HUP
    /usr/bin/perl -e 'while (1) {
        syswrite(STDOUT, "x\\n");
        select(undef, undef, undef, 0.005);
    }' &
    echo $! > '\(pidFile.path)'
    exit 0
    """
}

private final class ContinuousDescendantFixtureCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let pidFile: URL
    private let expectedExecutable: FixtureExecutableExpectation
    private let identityAccess: FixtureProcessIdentityAccess
    private var identity: FixtureProcessIdentity?
    private var finished = false

    init(
        root: URL,
        pidFile: URL,
        expectedExecutable: FixtureExecutableExpectation = .exactPath(
            "/usr/bin/perl"
        ),
        identityAccess: FixtureProcessIdentityAccess = .live
    ) {
        self.root = root
        self.pidFile = pidFile
        self.expectedExecutable = expectedExecutable
        self.identityAccess = identityAccess
    }

    func register(_ identity: FixtureProcessIdentity) {
        lock.withLock { self.identity = identity }
    }

    @discardableResult
    func register(processID: Int32) async -> Bool {
        guard let identity = await captureFixtureProcessIdentity(
            processID: processID,
            expectedExecutable: expectedExecutable,
            access: identityAccess
        ) else {
            return false
        }
        register(identity)
        return true
    }

    func cleanup(forceKill: Bool) async -> (descendantExited: Bool, pid: Int32?) {
        if lock.withLock({ finished }) {
            let identity = lock.withLock { self.identity }
            return (
                identity.map(identityAccess.originalProcessIsGone) ?? false,
                identity?.processID
            )
        }
        let identity = await discoverIdentity()
        var exited = identity.map(identityAccess.originalProcessIsGone) ?? false
        if !forceKill, !exited, let identity {
            exited = await waitForOriginalProcessExit(
                identity,
                identityAccess: identityAccess,
                timeout: .milliseconds(300)
            )
        }
        if !exited, let identity {
            identityAccess.sendIfIdentityMatches(SIGKILL, to: identity)
            exited = await waitForOriginalProcessExit(
                identity,
                identityAccess: identityAccess,
                timeout: .milliseconds(300)
            )
        }
        try? FileManager.default.removeItem(at: root)
        lock.withLock { finished = true }
        return (exited, identity?.processID)
    }

    private func discoverIdentity() async -> FixtureProcessIdentity? {
        if let identity = lock.withLock({ identity }) { return identity }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let processID = Int32(text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )),
                let identity = identityAccess.capture(
                    processID: processID,
                    expectedExecutable: expectedExecutable
                )
            {
                register(identity)
                return identity
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    deinit {
        guard !lock.withLock({ finished }) else { return }
        if let identity = lock.withLock({ identity }) {
            identityAccess.sendIfIdentityMatches(SIGKILL, to: identity)
            let deadline = ContinuousClock.now.advanced(
                by: .milliseconds(100)
            )
            while ContinuousClock.now < deadline,
                !identityAccess.originalProcessIsGone(identity)
            {
                usleep(5_000)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private func waitForOriginalProcessExit(
    _ identity: FixtureProcessIdentity,
    identityAccess: FixtureProcessIdentityAccess,
    timeout: Duration
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if identityAccess.originalProcessIsGone(identity) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return identityAccess.originalProcessIsGone(identity)
}

private struct FixtureSignalRecord: Sendable {
    let processID: Int32
    let signal: Int32
}

private final class FixtureProcessIdentityTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: FixtureProcessIdentity?
    private var sentSignals: [FixtureSignalRecord] = []

    init(identity: FixtureProcessIdentity?) {
        self.identity = identity
    }

    var access: FixtureProcessIdentityAccess {
        FixtureProcessIdentityAccess(
            identityReader: { [self] processID in
                lock.withLock {
                    guard identity?.processID == processID else { return nil }
                    return identity
                }
            },
            signalSender: { [self] processID, signal in
                lock.withLock {
                    sentSignals.append(FixtureSignalRecord(
                        processID: processID,
                        signal: signal
                    ))
                }
                return 0
            }
        )
    }

    func setIdentity(_ identity: FixtureProcessIdentity?) {
        lock.withLock { self.identity = identity }
    }

    func signals() -> [FixtureSignalRecord] {
        lock.withLock { sentSignals }
    }
}

private let fixtureIdentity = FixtureProcessIdentity(
    processID: 42_424,
    startTimeSeconds: 1_234,
    startTimeMicroseconds: 567,
    executablePath: "/fixtures/python3"
)

func exerciseMatchingFixtureProcessIdentitySignal() -> (
    signalWasSent: Bool,
    signalledProcessID: Int32?,
    expectedProcessID: Int32,
    signal: Int32?
) {
    let state = FixtureProcessIdentityTestState(identity: fixtureIdentity)
    let sent = state.access.sendIfIdentityMatches(SIGKILL, to: fixtureIdentity)
    let signal = state.signals().first
    return (
        sent,
        signal?.processID,
        fixtureIdentity.processID,
        signal?.signal
    )
}

func exerciseChangedFixtureProcessIdentitySignals() -> (
    changedStartTimeWasRejected: Bool,
    changedExecutableWasRejected: Bool,
    signalCount: Int
) {
    let state = FixtureProcessIdentityTestState(identity: fixtureIdentity)
    state.setIdentity(FixtureProcessIdentity(
        processID: fixtureIdentity.processID,
        startTimeSeconds: fixtureIdentity.startTimeSeconds + 1,
        startTimeMicroseconds: fixtureIdentity.startTimeMicroseconds,
        executablePath: fixtureIdentity.executablePath
    ))
    let startRejected = !state.access.sendIfIdentityMatches(
        SIGKILL,
        to: fixtureIdentity
    )
    state.setIdentity(FixtureProcessIdentity(
        processID: fixtureIdentity.processID,
        startTimeSeconds: fixtureIdentity.startTimeSeconds,
        startTimeMicroseconds: fixtureIdentity.startTimeMicroseconds,
        executablePath: "/unrelated/executable"
    ))
    let executableRejected = !state.access.sendIfIdentityMatches(
        SIGKILL,
        to: fixtureIdentity
    )
    return (startRejected, executableRejected, state.signals().count)
}

func exerciseAbsentFixtureProcessIdentitySignal() -> (
    wasTreatedAsGone: Bool,
    signalCount: Int
) {
    let state = FixtureProcessIdentityTestState(identity: nil)
    let gone = state.access.originalProcessIsGone(fixtureIdentity)
    _ = state.access.sendIfIdentityMatches(SIGKILL, to: fixtureIdentity)
    return (gone, state.signals().count)
}

func exerciseFixtureCleanupDeinitIdentityChecks() throws -> (
    exactPIDSignalCount: Int,
    descendantSignalCount: Int,
    descendantDirectoryRemoved: Bool
) {
    let changedIdentity = FixtureProcessIdentity(
        processID: fixtureIdentity.processID,
        startTimeSeconds: fixtureIdentity.startTimeSeconds + 1,
        startTimeMicroseconds: fixtureIdentity.startTimeMicroseconds,
        executablePath: fixtureIdentity.executablePath
    )
    let exactState = FixtureProcessIdentityTestState(identity: fixtureIdentity)
    var exactCleanup: ExactPIDTestCleanup? = ExactPIDTestCleanup(
        identityAccess: exactState.access
    )
    exactCleanup?.register(fixtureIdentity)
    exactState.setIdentity(changedIdentity)
    exactCleanup = nil

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    let descendantState = FixtureProcessIdentityTestState(
        identity: fixtureIdentity
    )
    var descendantCleanup: ContinuousDescendantFixtureCleanup? =
        ContinuousDescendantFixtureCleanup(
            root: root,
            pidFile: root.appendingPathComponent("descendant.pid"),
            expectedExecutable: .exactPath("/fixtures/python3"),
            identityAccess: descendantState.access
        )
    descendantCleanup?.register(fixtureIdentity)
    descendantState.setIdentity(changedIdentity)
    descendantCleanup = nil

    return (
        exactState.signals().count,
        descendantState.signals().count,
        !FileManager.default.fileExists(atPath: root.path)
    )
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
    return try await withProcessTestDeadline(process) {
        try await process.start()
        let firstWrite = Task { try await process.write(first) }
        try await Task.sleep(for: .milliseconds(20))
        let secondWrite = Task { try await process.write(second) }

        var output = Data()
        let receiverID = UUID()
        while let event = await process.nextEvent(receiverID: receiverID) {
            if case let .standardOutput(data) = event { output.append(data) }
        }
        try await firstWrite.value
        try await secondWrite.value
        _ = await process.waitForTermination()
        let expected = first + second
        return (output == expected, output.count, expected.count)
    }
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
    _ = try await withProcessTestDeadline(process) {
        try await process.start()
        await process.terminate()
        return await process.waitForTermination()
    }
    let afterTermination = try openDescriptorCount() - baseline
    _ = failed
    return (afterLaunchFailures, afterTermination)
}

private func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private enum ProcessTestDeadlineError: Error {
    case timedOut
    case cleanupTimedOut
}

private actor ProcessTestRace<Value: Sendable> {
    typealias Outcome = Result<Value, any Error>

    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}

private actor ProcessTestCompletionSignal {
    private var completed = false
    private var waiters: [UUID: ProcessTestRace<Bool>] = [:]

    func register(_ race: ProcessTestRace<Bool>) -> UUID? {
        guard !completed else { return nil }
        let id = UUID()
        waiters[id] = race
        return id
    }

    func complete() async {
        guard !completed else { return }
        completed = true
        let races = waiters.values
        waiters.removeAll()
        for race in races { await race.resolve(.success(true)) }
    }

    func remove(_ id: UUID) { waiters.removeValue(forKey: id) }
}

private func waitForCompletion(
    _ signal: ProcessTestCompletionSignal,
    timeout: Duration
) async -> Bool {
    let race = ProcessTestRace<Bool>()
    guard let id = await signal.register(race) else { return true }
    let deadlineTask = Task {
        do {
            try await Task.sleep(for: timeout)
            await race.resolve(.success(false))
        } catch {
            // Completion cancels and joins this timer.
        }
    }
    let outcome = await race.wait()
    deadlineTask.cancel()
    await deadlineTask.value
    await signal.remove(id)
    return (try? outcome.get()) ?? false
}

private func withProcessTestDeadline<Value: Sendable>(
    _ process: any AppServerProcessRunning,
    timeout: Duration = .seconds(3),
    teardownTimeout: Duration = .milliseconds(250),
    operationJoinTimeout: Duration = .milliseconds(250),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = ProcessTestRace<Value>()
    let operationCompletion = ProcessTestCompletionSignal()
    let operationTask = Task {
        do {
            await race.resolve(.success(try await operation()))
        } catch {
            await race.resolve(.failure(error))
        }
        await operationCompletion.complete()
    }
    let deadlineTask = Task {
        do {
            try await Task.sleep(for: timeout)
            await race.resolve(.failure(ProcessTestDeadlineError.timedOut))
        } catch {
            // Normal completion cancels the deadline task.
        }
    }
    let outcome = await withTaskCancellationHandler {
        await race.wait()
    } onCancel: {
        Task { await race.resolve(.failure(CancellationError())) }
    }
    operationTask.cancel()
    deadlineTask.cancel()
    await deadlineTask.value
    let cleanupCompletion = ProcessTestCompletionSignal()
    let cleanupTask = Task.detached {
        await process.terminate()
        _ = await process.waitForTermination()
        await cleanupCompletion.complete()
    }
    var cleanupFinished = await waitForCompletion(
        cleanupCompletion,
        timeout: teardownTimeout
    )
    if !cleanupFinished {
        process.emergencyTerminate()
        cleanupTask.cancel()
        cleanupFinished = await waitForCompletion(
            cleanupCompletion,
            timeout: operationJoinTimeout
        )
    }
    let operationFinished = await waitForCompletion(
        operationCompletion,
        timeout: operationJoinTimeout
    )
    if !operationFinished { process.emergencyTerminate() }
    if case .success = outcome, !cleanupFinished {
        throw ProcessTestDeadlineError.cleanupTimedOut
    }
    return try outcome.get()
}

private final class HardDeadlineProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var emergencyCalls = 0
    private var cleanupExits = 0
    private var operationExits = 0

    func wait() async {
        if lock.withLock({ released }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func emergencyRelease() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            emergencyCalls += 1
            guard !released else { return [] }
            released = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    func recordCleanupExit() { lock.withLock { cleanupExits += 1 } }
    func recordOperationExit() { lock.withLock { operationExits += 1 } }
    func snapshot() -> (emergency: Int, cleanup: Int, operation: Int) {
        lock.withLock { (emergencyCalls, cleanupExits, operationExits) }
    }
}

private final class HardDeadlineAppServerProcess: AppServerProcessRunning,
    @unchecked Sendable
{
    let state = HardDeadlineProcessState()

    func start() async throws {}
    func write(_ data: Data) async throws {}
    func nextEvent(receiverID: UUID) async -> AppServerProcessEvent? { nil }
    func terminate() async {}
    func waitForTermination() async -> AppServerProcessTermination {
        await state.wait()
        state.recordCleanupExit()
        return .init(exitCode: 0)
    }
    nonisolated func emergencyTerminate() { state.emergencyRelease() }
}

func exerciseHardDeadlineTestCleanup() async throws -> (
    preservedOperationTimeout: Bool,
    elapsed: Duration,
    emergencyCleanupCalls: Int,
    cleanupTaskExited: Bool,
    operationTaskExited: Bool
) {
    let process = HardDeadlineAppServerProcess()
    let clock = ContinuousClock()
    let started = clock.now
    let preservedOperationTimeout: Bool
    do {
        _ = try await withProcessTestDeadline(
            process,
            timeout: .milliseconds(10),
            teardownTimeout: .milliseconds(20),
            operationJoinTimeout: .milliseconds(20)
        ) {
            await process.state.wait()
            process.state.recordOperationExit()
            return ()
        }
        preservedOperationTimeout = false
    } catch ProcessTestDeadlineError.timedOut {
        preservedOperationTimeout = true
    }
    let snapshot = process.state.snapshot()
    return (
        preservedOperationTimeout,
        started.duration(to: clock.now),
        snapshot.emergency,
        snapshot.cleanup == 1,
        snapshot.operation == 1
    )
}
