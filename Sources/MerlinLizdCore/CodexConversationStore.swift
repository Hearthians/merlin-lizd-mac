import Darwin
import Foundation

public struct CodexConversationRecord: Codable, Equatable, Sendable {
    public static let currentProtocolGeneration = "app-server-0.144"

    public let key: TerminalConversationKey
    public var threadID: AgentThreadID
    public let protocolGeneration: String
    public var archived: Bool
    public var updatedAt: Date

    public init(
        key: TerminalConversationKey,
        threadID: AgentThreadID,
        protocolGeneration: String = Self.currentProtocolGeneration,
        archived: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.threadID = threadID
        self.protocolGeneration = protocolGeneration
        self.archived = archived
        self.updatedAt = updatedAt
    }
}

public enum CodexDeletionStage: Int, Codable, Comparable, Sendable {
    case intentPersisted
    case remoteThreadDeleted
    case journalDeleted
    case routerForgotten

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum CodexDeletionFailure: String, Codable, Equatable, Sendable {
    case remoteUnavailable
    case journalUnavailable
    case routerBusy
    case persistenceUnavailable
    case unknown
}

public struct CodexDeletionTombstone: Codable, Equatable, Sendable {
    public let key: TerminalConversationKey
    public let threadID: AgentThreadID
    public let protocolGeneration: String
    public var lastCompletedStage: CodexDeletionStage
    public var updatedAt: Date
    public var failure: CodexDeletionFailure?

    public init(
        key: TerminalConversationKey,
        threadID: AgentThreadID,
        protocolGeneration: String,
        lastCompletedStage: CodexDeletionStage,
        updatedAt: Date,
        failure: CodexDeletionFailure? = nil
    ) {
        self.key = key
        self.threadID = threadID
        self.protocolGeneration = protocolGeneration
        self.lastCompletedStage = lastCompletedStage
        self.updatedAt = updatedAt
        self.failure = failure
    }
}

public enum CodexArchiveReconciliationStage: Int, Codable, Comparable, Sendable {
    case intentPersisted
    case remoteApplied

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum CodexArchiveFailure: String, Codable, Equatable, Sendable {
    case remoteUnavailable
    case persistenceUnavailable
    case unknown
}

public struct CodexArchiveReconciliation: Codable, Equatable, Sendable {
    public let key: TerminalConversationKey
    public let threadID: AgentThreadID
    public let desiredArchived: Bool
    public var stage: CodexArchiveReconciliationStage
    public var updatedAt: Date
    public var failure: CodexArchiveFailure?

    public init(
        key: TerminalConversationKey,
        threadID: AgentThreadID,
        desiredArchived: Bool,
        stage: CodexArchiveReconciliationStage,
        updatedAt: Date,
        failure: CodexArchiveFailure? = nil
    ) {
        self.key = key
        self.threadID = threadID
        self.desiredArchived = desiredArchived
        self.stage = stage
        self.updatedAt = updatedAt
        self.failure = failure
    }
}

public enum CodexOrphanFailure: String, Codable, Equatable, Sendable {
    case remoteUnavailable
    case persistenceUnavailable
    case unknown
}

public struct CodexOrphanedThread: Codable, Equatable, Sendable {
    public let threadID: AgentThreadID
    public let attemptedKey: TerminalConversationKey
    public let protocolGeneration: String
    public var failure: CodexOrphanFailure
    public var updatedAt: Date

    public init(
        threadID: AgentThreadID,
        attemptedKey: TerminalConversationKey,
        protocolGeneration: String = CodexConversationRecord
            .currentProtocolGeneration,
        failure: CodexOrphanFailure,
        updatedAt: Date
    ) {
        self.threadID = threadID
        self.attemptedKey = attemptedKey
        self.protocolGeneration = protocolGeneration
        self.failure = failure
        self.updatedAt = updatedAt
    }
}

public struct CodexConversationStoreSnapshot: Codable, Equatable, Sendable {
    public var records: [TerminalConversationKey: CodexConversationRecord]
    public var deletions: [TerminalConversationKey: CodexDeletionTombstone]
    public var archiveReconciliations: [
        TerminalConversationKey: CodexArchiveReconciliation
    ]
    public var orphans: [AgentThreadID: CodexOrphanedThread]

    public init(
        records: [TerminalConversationKey: CodexConversationRecord] = [:],
        deletions: [TerminalConversationKey: CodexDeletionTombstone] = [:],
        archiveReconciliations: [
            TerminalConversationKey: CodexArchiveReconciliation
        ] = [:],
        orphans: [AgentThreadID: CodexOrphanedThread] = [:]
    ) {
        self.records = records
        self.deletions = deletions
        self.archiveReconciliations = archiveReconciliations
        self.orphans = orphans
    }

    private enum CodingKeys: String, CodingKey {
        case records, deletions, archiveReconciliations, orphans
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode(
            [TerminalConversationKey: CodexConversationRecord].self,
            forKey: .records
        )
        deletions = try container.decode(
            [TerminalConversationKey: CodexDeletionTombstone].self,
            forKey: .deletions
        )
        archiveReconciliations = try container.decode(
            [TerminalConversationKey: CodexArchiveReconciliation].self,
            forKey: .archiveReconciliations
        )
        orphans = try container.decodeIfPresent(
            [AgentThreadID: CodexOrphanedThread].self,
            forKey: .orphans
        ) ?? [:]
    }
}

public enum CodexConversationStoreMutation: Sendable {
    case upsert(CodexConversationRecord)
    case insertIfAbsent(CodexConversationRecord)
    case beginDeletion(key: TerminalConversationKey, updatedAt: Date)
    case advanceDeletion(
        key: TerminalConversationKey,
        stage: CodexDeletionStage,
        updatedAt: Date
    )
    case recordDeletionFailure(
        key: TerminalConversationKey,
        failure: CodexDeletionFailure,
        updatedAt: Date
    )
    case completeDeletion(key: TerminalConversationKey)
    case beginArchiveChange(
        key: TerminalConversationKey,
        desiredArchived: Bool,
        updatedAt: Date
    )
    case advanceArchiveChange(
        key: TerminalConversationKey,
        stage: CodexArchiveReconciliationStage,
        updatedAt: Date
    )
    case recordArchiveFailure(
        key: TerminalConversationKey,
        failure: CodexArchiveFailure,
        updatedAt: Date
    )
    case completeArchiveChange(key: TerminalConversationKey, updatedAt: Date)
    case recordOrphan(CodexOrphanedThread)
    case removeOrphan(threadID: AgentThreadID)
}

public protocol CodexConversationStoring: Sendable {
    func snapshot() async throws -> CodexConversationStoreSnapshot
    func apply(
        _ mutation: CodexConversationStoreMutation
    ) async throws -> CodexConversationStoreSnapshot
}

public enum CodexConversationStoreError: Error, Equatable, Sendable {
    case insecurePath(path: String)
    case corruptEnvelope
    case recordNotFound
    case deletionInProgress
    case invalidDeletionStage
    case archiveChangeInProgress
    case invalidArchiveStage
    case duplicateThreadMapping
    case orphanLimitReached
    case unsupportedProtocolGeneration
    case posixFailure(operation: String, path: String, code: Int32)
}

public actor FileCodexConversationStore: CodexConversationStoring {
    public nonisolated let rootDirectory: URL
    public nonisolated let storeURL: URL

    private struct Envelope: Codable, Equatable, Sendable {
        let version: Int
        var state: CodexConversationStoreSnapshot
    }

    private static let directoryName = "CodexConversations"
    private static let storeName = "conversations.json"
    private static let lockName = ".conversations.lock"
    private static let orphanLimit = 64

    private let rootDescriptor: Int32
    private let lockDescriptor: Int32
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: CodexConversationStoreSnapshot

    public init(applicationSupportDirectory: URL) throws {
        let applicationRoot = applicationSupportDirectory.appendingPathComponent(
            "MerlinLizd",
            isDirectory: true
        )
        let root = applicationRoot.appendingPathComponent(
            Self.directoryName,
            isDirectory: true
        )
        let rootDescriptor = try Self.openDirectoryTree(
            applicationSupportDirectory: applicationSupportDirectory,
            applicationRoot: applicationRoot,
            root: root
        )
        let lockPath = root.appendingPathComponent(Self.lockName).path
        let lock = openat(
            rootDescriptor,
            Self.lockName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lock >= 0 else {
            close(rootDescriptor)
            throw Self.posixError("openat", lockPath)
        }
        do {
            try Self.validatePrivateFile(lock, path: lockPath)
            try Self.lock(lock, operation: LOCK_SH, path: lockPath)
            defer { flock(lock, LOCK_UN) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let loaded = try Self.readEnvelope(
                rootDescriptor: rootDescriptor,
                root: root,
                decoder: decoder
            )
            rootDirectory = root
            storeURL = root.appendingPathComponent(Self.storeName)
            self.rootDescriptor = rootDescriptor
            lockDescriptor = lock
            encoder = Self.makeEncoder()
            self.decoder = decoder
            state = loaded
        } catch {
            close(lock)
            close(rootDescriptor)
            throw error
        }
    }

    deinit {
        close(lockDescriptor)
        close(rootDescriptor)
    }

    public func snapshot() -> CodexConversationStoreSnapshot {
        state
    }

    public func apply(
        _ mutation: CodexConversationStoreMutation
    ) throws -> CodexConversationStoreSnapshot {
        try Self.lock(
            lockDescriptor,
            operation: LOCK_EX,
            path: rootDirectory.appendingPathComponent(Self.lockName).path
        )
        defer { flock(lockDescriptor, LOCK_UN) }

        var latest = try Self.readEnvelope(
            rootDescriptor: rootDescriptor,
            root: rootDirectory,
            decoder: decoder
        )
        try Self.reduce(mutation, into: &latest)
        try persist(latest)
        state = latest
        return latest
    }

    private static func reduce(
        _ mutation: CodexConversationStoreMutation,
        into state: inout CodexConversationStoreSnapshot
    ) throws {
        switch mutation {
        case let .upsert(record):
            guard state.deletions[record.key] == nil else {
                throw CodexConversationStoreError.deletionInProgress
            }
            guard record.protocolGeneration
                == CodexConversationRecord.currentProtocolGeneration
            else {
                throw CodexConversationStoreError
                    .unsupportedProtocolGeneration
            }
            guard !state.records.values.contains(where: {
                $0.key != record.key && $0.threadID == record.threadID
            }) else {
                throw CodexConversationStoreError.duplicateThreadMapping
            }
            state.records[record.key] = record
        case let .insertIfAbsent(record):
            guard state.deletions[record.key] == nil else {
                throw CodexConversationStoreError.deletionInProgress
            }
            guard record.protocolGeneration
                == CodexConversationRecord.currentProtocolGeneration
            else {
                throw CodexConversationStoreError
                    .unsupportedProtocolGeneration
            }
            guard state.records[record.key] == nil else { return }
            guard !state.records.values.contains(where: {
                $0.threadID == record.threadID
            }) else {
                throw CodexConversationStoreError.duplicateThreadMapping
            }
            state.records[record.key] = record
        case let .beginDeletion(key, updatedAt):
            guard let record = state.records[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            if state.deletions[key] == nil {
                state.deletions[key] = CodexDeletionTombstone(
                    key: key,
                    threadID: record.threadID,
                    protocolGeneration: record.protocolGeneration,
                    lastCompletedStage: .intentPersisted,
                    updatedAt: updatedAt
                )
            }
        case let .advanceDeletion(key, stage, updatedAt):
            guard var tombstone = state.deletions[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            guard stage.rawValue <= tombstone.lastCompletedStage.rawValue + 1,
                stage >= tombstone.lastCompletedStage
            else {
                throw CodexConversationStoreError.invalidDeletionStage
            }
            tombstone.lastCompletedStage = stage
            tombstone.updatedAt = updatedAt
            tombstone.failure = nil
            state.deletions[key] = tombstone
        case let .recordDeletionFailure(key, failure, updatedAt):
            guard var tombstone = state.deletions[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            tombstone.failure = failure
            tombstone.updatedAt = updatedAt
            state.deletions[key] = tombstone
        case let .completeDeletion(key):
            guard let tombstone = state.deletions[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            guard tombstone.lastCompletedStage == .routerForgotten else {
                throw CodexConversationStoreError.invalidDeletionStage
            }
            state.records.removeValue(forKey: key)
            state.deletions.removeValue(forKey: key)
            state.archiveReconciliations.removeValue(forKey: key)
        case let .beginArchiveChange(key, desiredArchived, updatedAt):
            guard let record = state.records[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            guard state.deletions[key] == nil else {
                throw CodexConversationStoreError.deletionInProgress
            }
            if let existing = state.archiveReconciliations[key],
                existing.desiredArchived != desiredArchived
            {
                throw CodexConversationStoreError.archiveChangeInProgress
            }
            state.archiveReconciliations[key] = CodexArchiveReconciliation(
                key: key,
                threadID: record.threadID,
                desiredArchived: desiredArchived,
                stage: .intentPersisted,
                updatedAt: updatedAt
            )
        case let .advanceArchiveChange(key, stage, updatedAt):
            guard var reconciliation = state.archiveReconciliations[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            guard stage.rawValue <= reconciliation.stage.rawValue + 1,
                stage >= reconciliation.stage
            else {
                throw CodexConversationStoreError.invalidArchiveStage
            }
            reconciliation.stage = stage
            reconciliation.updatedAt = updatedAt
            reconciliation.failure = nil
            state.archiveReconciliations[key] = reconciliation
        case let .recordArchiveFailure(key, failure, updatedAt):
            guard var reconciliation = state.archiveReconciliations[key] else {
                throw CodexConversationStoreError.recordNotFound
            }
            reconciliation.failure = failure
            reconciliation.updatedAt = updatedAt
            state.archiveReconciliations[key] = reconciliation
        case let .completeArchiveChange(key, updatedAt):
            guard let reconciliation = state.archiveReconciliations[key],
                reconciliation.stage == .remoteApplied,
                var record = state.records[key]
            else {
                throw CodexConversationStoreError.invalidArchiveStage
            }
            record.archived = reconciliation.desiredArchived
            record.updatedAt = updatedAt
            state.records[key] = record
            state.archiveReconciliations.removeValue(forKey: key)
        case let .recordOrphan(orphan):
            guard orphan.protocolGeneration
                == CodexConversationRecord.currentProtocolGeneration
            else {
                throw CodexConversationStoreError
                    .unsupportedProtocolGeneration
            }
            guard !state.records.values.contains(where: {
                $0.threadID == orphan.threadID
            }) else {
                throw CodexConversationStoreError.duplicateThreadMapping
            }
            guard state.orphans[orphan.threadID] != nil
                || state.orphans.count < orphanLimit
            else {
                throw CodexConversationStoreError.orphanLimitReached
            }
            state.orphans[orphan.threadID] = orphan
        case let .removeOrphan(threadID):
            state.orphans.removeValue(forKey: threadID)
        }
    }

    private func persist(_ state: CodexConversationStoreSnapshot) throws {
        let data: Data
        do {
            data = try encoder.encode(Envelope(version: 1, state: state))
        } catch {
            throw CodexConversationStoreError.corruptEnvelope
        }
        let temporaryName = ".conversations.\(UUID().uuidString).tmp"
        let temporaryPath = rootDirectory.appendingPathComponent(temporaryName).path
        let descriptor = openat(
            rootDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw Self.posixError("openat", temporaryPath)
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove {
                unlinkat(rootDescriptor, temporaryName, 0)
            }
        }
        try Self.validatePrivateFile(descriptor, path: temporaryPath)
        try Self.writeAll(data, descriptor: descriptor, path: temporaryPath)
        guard fsync(descriptor) == 0 else {
            throw Self.posixError("fsync", temporaryPath)
        }
        try Self.rejectInsecureExistingStore(
            rootDescriptor: rootDescriptor,
            root: rootDirectory
        )
        guard renameat(
            rootDescriptor,
            temporaryName,
            rootDescriptor,
            Self.storeName
        ) == 0 else {
            throw Self.posixError("renameat", storeURL.path)
        }
        shouldRemove = false
        guard fsync(rootDescriptor) == 0 else {
            throw Self.posixError("fsync", rootDirectory.path)
        }
    }

    private static func readEnvelope(
        rootDescriptor: Int32,
        root: URL,
        decoder: JSONDecoder
    ) throws -> CodexConversationStoreSnapshot {
        let path = root.appendingPathComponent(storeName).path
        let descriptor = openat(
            rootDescriptor,
            storeName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            return CodexConversationStoreSnapshot()
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw CodexConversationStoreError.insecurePath(path: path)
            }
            throw posixError("openat", path)
        }
        defer { close(descriptor) }
        try validatePrivateFile(descriptor, path: path)
        let data = try readAll(descriptor: descriptor, path: path)
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.version == 1,
            envelope.state.records.allSatisfy({ $0.key == $0.value.key }),
            envelope.state.deletions.allSatisfy({ $0.key == $0.value.key }),
            envelope.state.archiveReconciliations.allSatisfy({
                $0.key == $0.value.key
            }),
            envelope.state.orphans.allSatisfy({
                $0.key == $0.value.threadID
            }),
            isConsistent(envelope.state)
        else {
            throw CodexConversationStoreError.corruptEnvelope
        }
        return envelope.state
    }

    private static func isConsistent(
        _ state: CodexConversationStoreSnapshot
    ) -> Bool {
        let records = Array(state.records.values)
        guard records.allSatisfy({
            $0.protocolGeneration
                == CodexConversationRecord.currentProtocolGeneration
        }), Set(records.map(\.threadID)).count == records.count else {
            return false
        }
        guard state.deletions.values.allSatisfy({ tombstone in
            guard let record = state.records[tombstone.key] else {
                return false
            }
            return tombstone.threadID == record.threadID
                && tombstone.protocolGeneration == record.protocolGeneration
        }) else { return false }
        guard state.archiveReconciliations.values.allSatisfy({
            reconciliation in
            state.records[reconciliation.key]?.threadID
                == reconciliation.threadID
        }) else { return false }
        return state.orphans.count <= orphanLimit
            && state.orphans.values.allSatisfy { orphan in
                orphan.protocolGeneration
                    == CodexConversationRecord.currentProtocolGeneration
                    && !records.contains(where: { record in
                        record.threadID == orphan.threadID
                    })
            }
    }

    private static func openDirectoryTree(
        applicationSupportDirectory: URL,
        applicationRoot: URL,
        root: URL
    ) throws -> Int32 {
        let support = open(
            applicationSupportDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard support >= 0 else {
            throw posixError("open", applicationSupportDirectory.path)
        }
        defer { close(support) }
        try validateDirectory(support, path: applicationSupportDirectory.path)
        let application = try openPrivateDirectory(
            parent: support,
            name: "MerlinLizd",
            path: applicationRoot.path
        )
        defer { close(application) }
        let conversations = try openPrivateDirectory(
            parent: application,
            name: directoryName,
            path: root.path
        )
        guard fsync(application) == 0 else {
            close(conversations)
            throw posixError("fsync", applicationRoot.path)
        }
        return (conversations)
    }

    private static func openPrivateDirectory(
        parent: Int32,
        name: String,
        path: String
    ) throws -> Int32 {
        if mkdirat(parent, name, S_IRWXU) != 0, errno != EEXIST {
            throw posixError("mkdirat", path)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw CodexConversationStoreError.insecurePath(path: path)
            }
            throw posixError("openat", path)
        }
        do {
            try validateDirectory(descriptor, path: path)
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                throw posixError("fchmod", path)
            }
            guard fsync(parent) == 0 else {
                throw posixError("fsync", path)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(_ descriptor: Int32, path: String) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError("fstat", path)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
            information.st_uid == geteuid()
        else {
            throw CodexConversationStoreError.insecurePath(path: path)
        }
    }

    private static func validatePrivateFile(_ descriptor: Int32, path: String) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError("fstat", path)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
            information.st_uid == geteuid(),
            information.st_nlink == 1
        else {
            throw CodexConversationStoreError.insecurePath(path: path)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("fchmod", path)
        }
    }

    private static func rejectInsecureExistingStore(
        rootDescriptor: Int32,
        root: URL
    ) throws {
        var information = stat()
        if fstatat(rootDescriptor, storeName, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw posixError("fstatat", root.appendingPathComponent(storeName).path)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
            information.st_uid == geteuid(),
            information.st_nlink == 1
        else {
            throw CodexConversationStoreError.insecurePath(
                path: root.appendingPathComponent(storeName).path
            )
        }
    }

    private static func lock(
        _ descriptor: Int32,
        operation: Int32,
        path: String
    ) throws {
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw posixError("flock", path)
        }
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            var remaining = rawBuffer.count
            var pointer = rawBuffer.baseAddress!
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError("write", path) }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func readAll(descriptor: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError("read", path) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func posixError(
        _ operation: String,
        _ path: String
    ) -> CodexConversationStoreError {
        .posixFailure(operation: operation, path: path, code: errno)
    }
}
