import CryptoKit
import Darwin
import Foundation

public enum TerminalJournalApprovalOutcome: Codable, Equatable, Sendable {
    case approvedOnce
    case denied
    case expired
    case cancelled
}

public enum TerminalJournalResult: Codable, Equatable, Sendable {
    case success(TerminalInputReceipt?)
    case failure(reason: String)
    case auditUnavailable
}

public enum TerminalJournalTemporaryPaneEvent: Codable, Equatable, Sendable {
    case created(leaseID: UUID, paneID: String)
    case closed(leaseID: UUID, paneID: String)
    case retained(leaseID: UUID, paneID: String, reason: String)
}

public enum TerminalJournalEventKind: Codable, Equatable, Sendable {
    case request(operation: String, purpose: String)
    case screen(revision: UInt64, changedRows: [Int], text: String)
    case risk(
        agentDeclared: TerminalRisk,
        deterministic: TerminalRisk,
        effective: TerminalRisk
    )
    case approval(
        requestID: UUID,
        scope: TerminalApprovalScope,
        outcome: TerminalJournalApprovalOutcome
    )
    case endpoint(TerminalEndpointID)
    case emittedBatch(TerminalInputBatch)
    case result(TerminalJournalResult)
    case temporaryPane(TerminalJournalTemporaryPaneEvent)
}

public struct TerminalJournalEvent: Codable, Equatable, Sendable {
    public let key: TerminalConversationKey
    public let operationID: UUID
    public let turnID: String
    public let timestamp: Date
    public let kind: TerminalJournalEventKind

    public init(
        key: TerminalConversationKey,
        operationID: UUID,
        turnID: String,
        timestamp: Date = Date(),
        kind: TerminalJournalEventKind
    ) {
        self.key = key
        self.operationID = operationID
        self.turnID = turnID
        self.timestamp = timestamp
        self.kind = kind
    }
}

public protocol TerminalOperationJournaling: Sendable {
    func append(_ event: TerminalJournalEvent) async throws
    func entries(
        for key: TerminalConversationKey
    ) async throws -> [TerminalJournalEvent]
    func deleteJournal(for key: TerminalConversationKey) async throws
}

public enum TerminalOperationJournalError: Error, Equatable, Sendable {
    case insecurePath(path: String)
    case posixFailure(operation: String, path: String, code: Int32)
    case mappingMissing(storageID: String)
    case mappingMismatch(storageID: String)
    case corruptMapping(storageID: String)
    case corruptTrailingRecord(storageID: String)
    case corruptRecord(storageID: String, line: Int)
}

public actor FileTerminalOperationJournal: TerminalOperationJournaling {
    public nonisolated let rootDirectory: URL
    public nonisolated let mappingsDirectory: URL
    public nonisolated let journalsDirectory: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(applicationSupportDirectory: URL) throws {
        let applicationDirectory = applicationSupportDirectory
            .appendingPathComponent("MerlinLizd", isDirectory: true)
        rootDirectory = applicationDirectory
            .appendingPathComponent("TerminalOperations", isDirectory: true)
        mappingsDirectory = rootDirectory
            .appendingPathComponent("Mappings", isDirectory: true)
        journalsDirectory = rootDirectory
            .appendingPathComponent("Journals", isDirectory: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try Self.ensurePrivateDirectory(applicationDirectory)
        try Self.ensurePrivateDirectory(rootDirectory)
        try Self.ensurePrivateDirectory(mappingsDirectory)
        try Self.ensurePrivateDirectory(journalsDirectory)
    }

    public static func storageID(
        for key: TerminalConversationKey
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(key)
        } catch {
            throw TerminalOperationJournalError.corruptMapping(storageID: "")
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public nonisolated func mappingURL(
        for key: TerminalConversationKey
    ) -> URL {
        let storageID = try! Self.storageID(for: key)
        return mappingsDirectory.appendingPathComponent("\(storageID).json")
    }

    public nonisolated func journalURL(
        for key: TerminalConversationKey
    ) -> URL {
        let storageID = try! Self.storageID(for: key)
        return journalsDirectory.appendingPathComponent("\(storageID).jsonl")
    }

    public func append(_ event: TerminalJournalEvent) async throws {
        let storageID = try Self.storageID(for: event.key)
        try ensureMapping(for: event.key, storageID: storageID)

        let url = journalURL(for: event.key)
        let existing = try Self.readSecureFileIfPresent(
            at: url,
            storageID: storageID
        )
        if let existing, !existing.isEmpty, existing.last != 0x0A {
            throw TerminalOperationJournalError.corruptTrailingRecord(
                storageID: storageID
            )
        }

        var record: Data
        do {
            record = try encoder.encode(event)
        } catch {
            throw TerminalOperationJournalError.corruptRecord(
                storageID: storageID,
                line: (existing?.filter { $0 == 0x0A }.count ?? 0) + 1
            )
        }
        record.append(0x0A)
        let created = existing == nil
        try Self.appendAndSync(record, to: url, storageID: storageID)
        if created {
            try Self.syncDirectory(journalsDirectory)
        }
    }

    public func entries(
        for key: TerminalConversationKey
    ) async throws -> [TerminalJournalEvent] {
        let storageID = try Self.storageID(for: key)
        let journalURL = journalURL(for: key)
        guard let data = try Self.readSecureFileIfPresent(
            at: journalURL,
            storageID: storageID
        ) else {
            return []
        }
        guard Self.pathExists(mappingURL(for: key)) else {
            throw TerminalOperationJournalError.mappingMissing(
                storageID: storageID
            )
        }
        try validateMapping(for: key, storageID: storageID)
        guard data.isEmpty || data.last == 0x0A else {
            throw TerminalOperationJournalError.corruptTrailingRecord(
                storageID: storageID
            )
        }

        let lines = [UInt8](data).split(
            separator: UInt8(0x0A),
            omittingEmptySubsequences: false
        ).dropLast()
        var result: [TerminalJournalEvent] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty,
                let event = try? decoder.decode(
                    TerminalJournalEvent.self,
                    from: Data(line)
                ),
                event.key == key
            else {
                throw TerminalOperationJournalError.corruptRecord(
                    storageID: storageID,
                    line: index + 1
                )
            }
            result.append(event)
        }
        return result
    }

    public func deleteJournal(for key: TerminalConversationKey) async throws {
        let journalURL = journalURL(for: key)
        let mappingURL = mappingURL(for: key)
        try Self.removeIfPresent(journalURL)
        try Self.syncDirectory(journalsDirectory)
        try Self.removeIfPresent(mappingURL)
        try Self.syncDirectory(mappingsDirectory)
    }

    private func ensureMapping(
        for key: TerminalConversationKey,
        storageID: String
    ) throws {
        let url = mappingURL(for: key)
        if Self.pathExists(url) {
            try validateMapping(for: key, storageID: storageID)
            return
        }

        let data: Data
        do {
            data = try encoder.encode(key)
        } catch {
            throw TerminalOperationJournalError.corruptMapping(
                storageID: storageID
            )
        }
        try Self.createAndSync(data, at: url, storageID: storageID)
        try Self.syncDirectory(mappingsDirectory)
    }

    private func validateMapping(
        for key: TerminalConversationKey,
        storageID: String
    ) throws {
        let url = mappingURL(for: key)
        guard let data = try Self.readSecureFileIfPresent(
            at: url,
            storageID: storageID
        ),
            let mapped = try? decoder.decode(
                TerminalConversationKey.self,
                from: data
            )
        else {
            throw TerminalOperationJournalError.corruptMapping(
                storageID: storageID
            )
        }
        guard mapped == key else {
            throw TerminalOperationJournalError.mappingMismatch(
                storageID: storageID
            )
        }
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        let path = url.path
        if mkdir(path, S_IRWXU) != 0, errno != EEXIST {
            throw posixError("mkdir", path)
        }
        var information = stat()
        guard lstat(path, &information) == 0 else {
            throw posixError("lstat", path)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
            information.st_uid == geteuid()
        else {
            throw TerminalOperationJournalError.insecurePath(path: path)
        }
        guard chmod(path, S_IRWXU) == 0 else {
            throw posixError("chmod", path)
        }
    }

    private static func createAndSync(
        _ data: Data,
        at url: URL,
        storageID: String
    ) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixError("open", url.path)
        }
        defer { close(descriptor) }
        try validatePrivateFile(descriptor, path: url.path)
        try writeAll(data, descriptor: descriptor, path: url.path)
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync", url.path)
        }
    }

    private static func appendAndSync(
        _ data: Data,
        to url: URL,
        storageID: String
    ) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixError("open", url.path)
        }
        defer { close(descriptor) }
        try validatePrivateFile(descriptor, path: url.path)
        try writeAll(data, descriptor: descriptor, path: url.path)
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync", url.path)
        }
    }

    private static func readSecureFileIfPresent(
        at url: URL,
        storageID: String
    ) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw posixError("open", url.path)
        }
        defer { close(descriptor) }
        try validatePrivateFile(descriptor, path: url.path)

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw posixError("read", url.path)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func validatePrivateFile(
        _ descriptor: Int32,
        path: String
    ) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError("fstat", path)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
            information.st_uid == geteuid(),
            information.st_nlink == 1
        else {
            throw TerminalOperationJournalError.insecurePath(path: path)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("fchmod", path)
        }
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw posixError("write", path)
                }
                offset += written
            }
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw posixError("open", url.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync", url.path)
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT {
            throw posixError("unlink", url.path)
        }
    }

    private static func pathExists(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }

    private static func posixError(
        _ operation: String,
        _ path: String
    ) -> TerminalOperationJournalError {
        TerminalOperationJournalError.posixFailure(
            operation: operation,
            path: path,
            code: errno
        )
    }
}

public enum TerminalMutationAuditError: Error, Equatable, Sendable {
    case denied(reason: String)
    case auditUnavailable
}

public actor TerminalMutationAuditor {
    private let journal: any TerminalOperationJournaling
    private var blockedTurns: Set<String> = []
    private var preparedOperations: [
        String: [UUID: TerminalConversationKey]
    ] = [:]

    public init(journal: any TerminalOperationJournaling) {
        self.journal = journal
    }

    public func appendBeforeSideEffect(
        _ events: [TerminalJournalEvent],
        turnID: String
    ) async throws {
        guard !blockedTurns.contains(turnID) else {
            throw TerminalMutationAuditError.auditUnavailable
        }
        guard validPreActionBundle(events, turnID: turnID) else {
            blockedTurns.insert(turnID)
            throw TerminalMutationAuditError.denied(
                reason: "Required pre-action audit events are missing or out of order"
            )
        }
        do {
            for event in events {
                try await journal.append(event)
            }
            if let first = events.first {
                preparedOperations[turnID, default: [:]][first.operationID]
                    = first.key
            }
        } catch {
            blockedTurns.insert(turnID)
            throw TerminalMutationAuditError.denied(
                reason: "Audit journal unavailable"
            )
        }
    }

    public func appendAfterSideEffect(
        _ event: TerminalJournalEvent,
        turnID: String
    ) async throws {
        guard !blockedTurns.contains(turnID) else {
            throw TerminalMutationAuditError.auditUnavailable
        }
        guard event.turnID == turnID,
            preparedOperations[turnID]?[event.operationID] == event.key,
            event.isPostActionAuditEvent
        else {
            blockedTurns.insert(turnID)
            throw TerminalMutationAuditError.auditUnavailable
        }
        do {
            try await journal.append(event)
        } catch {
            blockedTurns.insert(turnID)
            throw TerminalMutationAuditError.auditUnavailable
        }
    }

    public func endTurn(_ turnID: String) {
        blockedTurns.remove(turnID)
        preparedOperations.removeValue(forKey: turnID)
    }

    private func validPreActionBundle(
        _ events: [TerminalJournalEvent],
        turnID: String
    ) -> Bool {
        guard let first = events.first,
            events.allSatisfy({ event in
                event.turnID == turnID
                    && event.key == first.key
                    && event.operationID == first.operationID
            })
        else {
            return false
        }

        var requestIndexes: [Int] = []
        var riskEvents: [(index: Int, effective: TerminalRisk)] = []
        var approvalEvents: [(
            index: Int,
            scope: TerminalApprovalScope,
            outcome: TerminalJournalApprovalOutcome
        )] = []
        var endpointEvents: [(index: Int, endpointID: TerminalEndpointID)] = []
        var screenRevisions: [UInt64] = []

        for (index, event) in events.enumerated() {
            switch event.kind {
            case .request:
                requestIndexes.append(index)
            case let .screen(revision, _, _):
                screenRevisions.append(revision)
            case let .risk(_, _, effective):
                riskEvents.append((index, effective))
            case let .approval(_, scope, outcome):
                approvalEvents.append((index, scope, outcome))
            case let .endpoint(endpointID):
                endpointEvents.append((index, endpointID))
            case .emittedBatch, .result, .temporaryPane:
                continue
            }
        }

        guard requestIndexes.count == 1,
            riskEvents.count == 1,
            endpointEvents.count == 1,
            requestIndexes[0] < riskEvents[0].index,
            riskEvents[0].index < endpointEvents[0].index
        else {
            return false
        }

        if riskEvents[0].effective == .high {
            guard approvalEvents.count == 1,
                approvalEvents[0].outcome == .approvedOnce,
                riskEvents[0].index < approvalEvents[0].index,
                approvalEvents[0].index < endpointEvents[0].index,
                approvalEvents[0].scope.endpointID
                    == endpointEvents[0].endpointID,
                screenRevisions.last.map({
                    $0 == approvalEvents[0].scope.screenRevision
                }) ?? true
            else {
                return false
            }
        } else if approvalEvents.contains(where: { $0.outcome != .approvedOnce }) {
            return false
        }
        return true
    }
}

private extension TerminalJournalEvent {
    var isPostActionAuditEvent: Bool {
        switch kind {
        case .result, .temporaryPane:
            true
        case .request, .screen, .risk, .approval, .endpoint, .emittedBatch:
            false
        }
    }
}
