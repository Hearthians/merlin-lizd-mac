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
    changedRows: [Int] = [0]
) -> TerminalScreenSnapshot {
    TerminalScreenSnapshot(
        revision: revision,
        columns: 80,
        rows: 24,
        cursor: TerminalCursor(row: 0, column: 2, isVisible: true),
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

func waitForPendingApproval(
    _ requestID: UUID,
    in broker: TerminalApprovalBroker
) async -> Bool {
    for _ in 0..<200 {
        if await broker.pendingRequests().contains(where: { $0.id == requestID }) {
            return true
        }
        await Task.yield()
    }
    return false
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
