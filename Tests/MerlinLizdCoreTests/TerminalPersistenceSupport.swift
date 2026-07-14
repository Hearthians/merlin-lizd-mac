import Darwin
import Foundation
@testable import MerlinLizdCore

struct TerminalPersistenceFixture: Sendable {
    let applicationSupportDirectory: URL

    init() throws {
        applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "merlin-lizd-terminal-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: applicationSupportDirectory)
    }
}

final class TerminalDirectorySyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int?
    private var recordedPaths: [String] = []

    init(failingCall: Int? = nil) {
        self.failingCall = failingCall
    }

    func sync(_ descriptor: Int32, path: String) throws {
        lock.lock()
        recordedPaths.append(path)
        let call = recordedPaths.count
        lock.unlock()
        if call == failingCall {
            throw ScriptedTerminalJournalError.unavailable
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw TerminalOperationJournalError.posixFailure(
                operation: "fsync",
                path: path,
                code: errno
            )
        }
    }

    func paths() -> [String] {
        lock.withLock { recordedPaths }
    }
}

func terminalTestConversationKey(
    target: TerminalTargetIdentity = .worker(
        devboxSID: "dbx-secret-135679",
        workerID: "worker-secret-3960209"
    ),
    serverSessionID: String = "$3",
    createdAtEpoch: Int64 = 100
) -> TerminalConversationKey {
    TerminalConversationKey(
        target: target,
        tmux: TmuxSessionIdentity(
            serverSessionID: serverSessionID,
            createdAtEpoch: createdAtEpoch
        )
    )
}

func terminalTestEndpoint(_ value: String = "00000000-0000-0000-0000-000000000001")
    -> TerminalEndpointID
{
    TerminalEndpointID(rawValue: UUID(uuidString: value)!)
}

func terminalUUID(_ value: String? = nil) -> UUID {
    value.flatMap(UUID.init(uuidString:)) ?? UUID()
}

func terminalTestBatch(
    revision: UInt64 = 7,
    events: [TerminalInputEvent] = [.text("echo ok")],
    purpose: String = "routine typing",
    risk: TerminalRisk = .routine
) -> TerminalInputBatch {
    TerminalInputBatch(
        expectedRevision: revision,
        events: events,
        purpose: purpose,
        declaredRisk: risk
    )
}

func terminalTestScreen(
    revision: UInt64 = 7,
    text: String = "$ ",
    changedRows: [Int] = [0],
    cursorRow: Int = 0,
    cursorColumn: Int = 2
) -> TerminalScreenSnapshot {
    TerminalScreenSnapshot(
        revision: revision,
        columns: 80,
        rows: 24,
        cursor: TerminalCursor(
            row: cursorRow,
            column: cursorColumn,
            isVisible: true
        ),
        mode: .normal,
        text: text,
        significantRuns: [],
        changedRows: changedRows
    )
}

func terminalTestJournalEvent(
    key: TerminalConversationKey = terminalTestConversationKey(),
    operationID: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
    turnID: String = "turn-1",
    timestamp: Date = Date(timeIntervalSince1970: 1_721_000_000),
    kind: TerminalJournalEventKind
) -> TerminalJournalEvent {
    TerminalJournalEvent(
        key: key,
        operationID: operationID,
        turnID: turnID,
        timestamp: timestamp,
        kind: kind
    )
}

func terminalPOSIXMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.posixPermissions] as? Int ?? -1
}

func terminalRawJournalLines(at url: URL) throws -> [Data] {
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else { return [] }
    let parts: [[UInt8]] = [UInt8](data).split(
        separator: UInt8(0x0A),
        omittingEmptySubsequences: false
    ).map(Array.init)
    return parts[0..<(parts.count - 1)].map { bytes in Data(bytes) }
}

func terminalRawData(at url: URL) throws -> Data {
    try Data(contentsOf: url)
}

func terminalUTF8String(_ data: Data) -> String? {
    String(data: data, encoding: .utf8)
}

func appendTerminalPartialRecord(_ contents: String, at url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(contents.utf8))
    try handle.close()
}

func terminalFileExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func createTerminalDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
}

func moveTerminalItem(at source: URL, to destination: URL) throws {
    try FileManager.default.moveItem(at: source, to: destination)
}

func createTerminalSymbolicLink(at url: URL, destination: URL) throws {
    try FileManager.default.createSymbolicLink(
        at: url,
        withDestinationURL: destination
    )
}

func terminalDirectoryIsEmpty(_ url: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
}

func waitForPendingApproval(
    _ requestID: UUID,
    in broker: TerminalApprovalBroker
) async -> Bool {
    await broker.waitUntilPending(requestID, timeout: .seconds(1))
}

actor ScriptedTerminalJournal: TerminalOperationJournaling {
    private let failingAppendNumbers: Set<Int>
    private var appendNumber = 0
    private var stored: [TerminalJournalEvent] = []

    init(failingAppendNumbers: Set<Int>) {
        self.failingAppendNumbers = failingAppendNumbers
    }

    func append(_ event: TerminalJournalEvent) async throws {
        appendNumber += 1
        if failingAppendNumbers.contains(appendNumber) {
            throw ScriptedTerminalJournalError.unavailable
        }
        stored.append(event)
    }

    func entries(
        for key: TerminalConversationKey
    ) async throws -> [TerminalJournalEvent] {
        stored.filter { $0.key == key }
    }

    func deleteJournal(for key: TerminalConversationKey) async throws {
        stored.removeAll { $0.key == key }
    }

    func appendCount() -> Int {
        appendNumber
    }
}

enum ScriptedTerminalJournalError: Error {
    case unavailable
}

actor GatedFailingTerminalJournal: TerminalOperationJournaling {
    private let gate: AsyncStartGate
    private var count = 0

    init(gate: AsyncStartGate) {
        self.gate = gate
    }

    func append(_ event: TerminalJournalEvent) async throws {
        count += 1
        if count == 1 {
            await gate.wait()
            throw ScriptedTerminalJournalError.unavailable
        }
    }

    func entries(
        for key: TerminalConversationKey
    ) async throws -> [TerminalJournalEvent] {
        []
    }

    func deleteJournal(for key: TerminalConversationKey) async throws {}

    func appendCount() -> Int {
        count
    }
}
