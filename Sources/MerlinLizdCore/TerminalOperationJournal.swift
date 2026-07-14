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

public struct TerminalJournalPaneProvenance: Codable, Equatable, Sendable {
    public let windowID: String?
    public let paneID: String

    public init(windowID: String?, paneID: String) {
        self.windowID = windowID
        self.paneID = paneID
    }

    public init(_ pane: RetainedTemporaryPane) {
        self.init(windowID: pane.windowID, paneID: pane.paneID)
    }
}

public enum TerminalJournalRetentionReasonCode: String, Codable, Equatable, Sendable {
    case foregroundProcess
    case backgroundJobs
    case unsupportedShell
    case markerAmbiguity
    case probeTimedOut
    case disconnected
    case revisionDrift
    case userSurfaceSwitch
    case terminalWidthUncertain
    case routeUnavailable
    case auditUnavailable
    case interrupted
    case crashed
    case turnEnded
    case pinLost
    case controllerCancelled
    case controllerWorkerNotReady
    case controllerTimedOut
    case controllerTransportUnavailable
    case controllerCommandFailed
    case controllerInvalidSurfaceOutput
    case controllerSessionIdentityMismatch
    case controllerCreatedPaneNotCurrent
    case controllerUnavailable
    case controllerPaneNotOwned
    case controllerLeasePaneMissing
    case legacyUnknown

    public init(_ reason: TemporaryPaneRetentionReason) {
        switch reason {
        case .foregroundProcess: self = .foregroundProcess
        case .backgroundJobs: self = .backgroundJobs
        case .unsupportedShell: self = .unsupportedShell
        case .markerAmbiguity: self = .markerAmbiguity
        case .probeTimedOut: self = .probeTimedOut
        case .disconnected: self = .disconnected
        case .revisionDrift: self = .revisionDrift
        case .userSurfaceSwitch: self = .userSurfaceSwitch
        case .terminalWidthUncertain: self = .terminalWidthUncertain
        case .routeUnavailable: self = .routeUnavailable
        case .auditUnavailable: self = .auditUnavailable
        case .interrupted: self = .interrupted
        case .crashed: self = .crashed
        case .turnEnded: self = .turnEnded
        case .pinLost: self = .pinLost
        case let .controllerRetained(reason):
            switch reason {
            case .cancelled: self = .controllerCancelled
            case .workerNotReady: self = .controllerWorkerNotReady
            case .timedOut: self = .controllerTimedOut
            case .transportUnavailable:
                self = .controllerTransportUnavailable
            case .commandFailed: self = .controllerCommandFailed
            case .invalidSurfaceOutput:
                self = .controllerInvalidSurfaceOutput
            case .sessionIdentityMismatch:
                self = .controllerSessionIdentityMismatch
            case .createdPaneNotCurrent:
                self = .controllerCreatedPaneNotCurrent
            case .unavailable: self = .controllerUnavailable
            }
        case let .closeNotCommitted(reason):
            switch reason {
            case .cancelled: self = .interrupted
            case .paneNotOwned: self = .controllerPaneNotOwned
            case .leasePaneMissing: self = .controllerLeasePaneMissing
            case .workerNotReady: self = .controllerWorkerNotReady
            case .timedOut: self = .controllerTimedOut
            case .transportUnavailable:
                self = .controllerTransportUnavailable
            case .commandFailed: self = .controllerCommandFailed
            case .invalidSurfaceOutput:
                self = .controllerInvalidSurfaceOutput
            case .sessionIdentityMismatch:
                self = .controllerSessionIdentityMismatch
            case .unavailable: self = .controllerUnavailable
            }
        }
    }

    init(legacyReason: String) {
        let stablePrefixes: [
            (String, TerminalJournalRetentionReasonCode)
        ] = [
            ("foregroundProcess", .foregroundProcess),
            ("backgroundJobs", .backgroundJobs),
            ("unsupportedShell", .unsupportedShell),
            ("markerAmbiguity", .markerAmbiguity),
            ("probeTimedOut", .probeTimedOut),
            ("disconnected", .disconnected),
            ("revisionDrift", .revisionDrift),
            ("userSurfaceSwitch", .userSurfaceSwitch),
            ("terminalWidthUncertain", .terminalWidthUncertain),
            ("routeUnavailable", .routeUnavailable),
            ("auditUnavailable", .auditUnavailable),
            ("interrupted", .interrupted),
            ("crashed", .crashed),
            ("turnEnded", .turnEnded),
            ("pinLost", .pinLost),
        ]
        if let match = stablePrefixes.first(where: {
            legacyReason.hasPrefix($0.0)
        }) {
            self = match.1
            return
        }
        let controllerMappings: [
            (String, TerminalJournalRetentionReasonCode)
        ] = [
            ("cancelled", .controllerCancelled),
            ("workerNotReady", .controllerWorkerNotReady),
            ("timedOut", .controllerTimedOut),
            ("transportUnavailable", .controllerTransportUnavailable),
            ("commandFailed", .controllerCommandFailed),
            ("invalidSurfaceOutput", .controllerInvalidSurfaceOutput),
            ("sessionIdentityMismatch", .controllerSessionIdentityMismatch),
            ("createdPaneNotCurrent", .controllerCreatedPaneNotCurrent),
            ("unavailable", .controllerUnavailable),
        ]
        if legacyReason.hasPrefix("controllerRetained"),
            let match = controllerMappings.first(where: {
                legacyReason.contains($0.0)
            })
        {
            self = match.1
            return
        }
        self = .legacyUnknown
    }
}

public enum TerminalJournalTemporaryPaneEvent: Equatable, Sendable {
    case created(leaseID: UUID, pane: TerminalJournalPaneProvenance)
    case closed(
        leaseID: UUID,
        pane: TerminalJournalPaneProvenance,
        restoration: TmuxOriginRestoreOutcome
    )
    case retained(
        leaseID: UUID,
        pane: TerminalJournalPaneProvenance,
        reason: TerminalJournalRetentionReasonCode
    )
    case indeterminate(
        leaseID: UUID,
        pane: TerminalJournalPaneProvenance,
        reason: TmuxTemporaryPaneCloseIndeterminateReason
    )
}

extension TerminalJournalTemporaryPaneEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case created
        case closed
        case retained
        case indeterminate
    }

    private struct Payload: Codable {
        let leaseID: UUID
        let pane: TerminalJournalPaneProvenance?
        let paneID: String?
        let reasonCode: TerminalJournalRetentionReasonCode?
        let reason: String?
        let restoration: TmuxOriginRestoreOutcome?
        let indeterminateReason: TmuxTemporaryPaneCloseIndeterminateReason?

        init(
            leaseID: UUID,
            pane: TerminalJournalPaneProvenance,
            reasonCode: TerminalJournalRetentionReasonCode? = nil,
            restoration: TmuxOriginRestoreOutcome? = nil,
            indeterminateReason: TmuxTemporaryPaneCloseIndeterminateReason? = nil
        ) {
            self.leaseID = leaseID
            self.pane = pane
            paneID = nil
            self.reasonCode = reasonCode
            reason = nil
            self.restoration = restoration
            self.indeterminateReason = indeterminateReason
        }

        var decodedPane: TerminalJournalPaneProvenance? {
            switch (pane, paneID) {
            case let (pane?, nil):
                pane
            case let (nil, paneID?):
                TerminalJournalPaneProvenance(
                    windowID: nil,
                    paneID: paneID
                )
            default:
                nil
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: container.allKeys.first ?? .retained,
                in: container,
                debugDescription: "Expected exactly one temporary pane event"
            )
        }
        if container.contains(.created) {
            let payload = try container.decode(Payload.self, forKey: .created)
            guard let pane = payload.decodedPane else {
                throw DecodingError.dataCorruptedError(
                    forKey: .created,
                    in: container,
                    debugDescription: "Missing temporary pane provenance"
                )
            }
            self = .created(leaseID: payload.leaseID, pane: pane)
            return
        }
        if container.contains(.closed) {
            let payload = try container.decode(Payload.self, forKey: .closed)
            guard let pane = payload.decodedPane else {
                throw DecodingError.dataCorruptedError(
                    forKey: .closed,
                    in: container,
                    debugDescription: "Missing temporary pane provenance"
                )
            }
            self = .closed(
                leaseID: payload.leaseID,
                pane: pane,
                restoration: payload.restoration ?? .restored
            )
            return
        }
        if container.contains(.indeterminate) {
            let payload = try container.decode(
                Payload.self,
                forKey: .indeterminate
            )
            guard let pane = payload.decodedPane,
                let reason = payload.indeterminateReason
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .indeterminate,
                    in: container,
                    debugDescription: "Missing indeterminate pane provenance or reason"
                )
            }
            self = .indeterminate(
                leaseID: payload.leaseID,
                pane: pane,
                reason: reason
            )
            return
        }
        let payload = try container.decode(Payload.self, forKey: .retained)
        guard let pane = payload.decodedPane else {
            throw DecodingError.dataCorruptedError(
                forKey: .retained,
                in: container,
                debugDescription: "Missing retained pane provenance"
            )
        }
        let reason: TerminalJournalRetentionReasonCode
        switch (payload.reasonCode, payload.reason) {
        case let (reasonCode?, nil): reason = reasonCode
        case let (nil, legacyReason?):
            reason = TerminalJournalRetentionReasonCode(
                legacyReason: legacyReason
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .retained,
                in: container,
                debugDescription: "Expected one retained reason code"
            )
        }
        self = .retained(
            leaseID: payload.leaseID,
            pane: pane,
            reason: reason
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .created(leaseID, pane):
            try container.encode(
                Payload(leaseID: leaseID, pane: pane),
                forKey: .created
            )
        case let .closed(leaseID, pane, restoration):
            try container.encode(
                Payload(
                    leaseID: leaseID,
                    pane: pane,
                    restoration: restoration
                ),
                forKey: .closed
            )
        case let .retained(leaseID, pane, reason):
            try container.encode(
                Payload(leaseID: leaseID, pane: pane, reasonCode: reason),
                forKey: .retained
            )
        case let .indeterminate(leaseID, pane, reason):
            try container.encode(
                Payload(
                    leaseID: leaseID,
                    pane: pane,
                    indeterminateReason: reason
                ),
                forKey: .indeterminate
            )
        }
    }
}

public enum TerminalJournalEventKind: Codable, Equatable, Sendable {
    case request(operation: String, purpose: String)
    case screen(TerminalScreenSnapshot)
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

enum TerminalJournalOperation: Equatable, Sendable {
    case append
    case entries
    case delete
}

enum TerminalConversationLockEvent: Equatable, Sendable {
    case acquired(TerminalJournalOperation)
    case contended(TerminalJournalOperation)
}

struct TerminalOperationJournalHooks: Sendable {
    let beforeMappingPublish: (@Sendable () async throws -> Void)?
    let conversationLockEvent: (
        @Sendable (TerminalConversationLockEvent) async throws -> Void
    )?
    let directorySync: (@Sendable (Int32, String) throws -> Void)?

    init(
        beforeMappingPublish: (@Sendable () async throws -> Void)? = nil,
        conversationLockEvent: (
            @Sendable (TerminalConversationLockEvent) async throws -> Void
        )? = nil,
        directorySync: (@Sendable (Int32, String) throws -> Void)? = nil
    ) {
        self.beforeMappingPublish = beforeMappingPublish
        self.conversationLockEvent = conversationLockEvent
        self.directorySync = directorySync
    }
}

public actor FileTerminalOperationJournal: TerminalOperationJournaling {
    public nonisolated let rootDirectory: URL
    public nonisolated let mappingsDirectory: URL
    public nonisolated let journalsDirectory: URL

    private let mappingsDescriptor: Int32
    private let journalsDescriptor: Int32
    private let hooks: TerminalOperationJournalHooks
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(applicationSupportDirectory: URL) throws {
        try self.init(
            applicationSupportDirectory: applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks()
        )
    }

    init(
        applicationSupportDirectory: URL,
        hooks: TerminalOperationJournalHooks
    ) throws {
        let locations = Self.locations(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let descriptors = try Self.openDirectoryTree(
            locations: locations,
            hooks: hooks
        )
        rootDirectory = locations.root
        mappingsDirectory = locations.mappings
        journalsDirectory = locations.journals
        mappingsDescriptor = descriptors.mappings
        journalsDescriptor = descriptors.journals
        self.hooks = hooks
        encoder = Self.makeEncoder()
        decoder = Self.makeDecoder()
    }

    deinit {
        close(mappingsDescriptor)
        close(journalsDescriptor)
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
        let conversationLock = try await acquireConversationLock(
            storageID: storageID,
            operation: .append
        )
        defer { Self.releaseLock(conversationLock) }
        try await ensureMapping(for: event.key, storageID: storageID)

        var record: Data
        do {
            record = try encoder.encode(event)
        } catch {
            throw TerminalOperationJournalError.corruptRecord(
                storageID: storageID,
                line: 1
            )
        }
        record.append(0x0A)
        let name = "\(storageID).jsonl"
        let path = journalURL(for: event.key).path
        let descriptor = openat(
            journalsDescriptor,
            name,
            O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw Self.posixError("openat", path) }
        defer { close(descriptor) }
        try Self.validatePrivateFile(descriptor, path: path)
        try Self.lock(descriptor, operation: LOCK_EX, path: path)
        defer { flock(descriptor, LOCK_UN) }
        _ = try Self.decodeJournal(
            descriptor: descriptor,
            key: event.key,
            storageID: storageID,
            decoder: decoder,
            path: path
        )
        try Self.writeAll(record, descriptor: descriptor, path: path)
        guard fsync(descriptor) == 0 else {
            throw Self.posixError("fsync", path)
        }
        try Self.syncDirectory(
            descriptor: journalsDescriptor,
            path: journalsDirectory.path
        )
    }

    public func entries(
        for key: TerminalConversationKey
    ) async throws -> [TerminalJournalEvent] {
        let storageID = try Self.storageID(for: key)
        let conversationLock = try await acquireConversationLock(
            storageID: storageID,
            operation: .entries
        )
        defer { Self.releaseLock(conversationLock) }
        let name = "\(storageID).jsonl"
        let path = journalURL(for: key).path
        let descriptor = openat(
            journalsDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            return []
        }
        guard descriptor >= 0 else { throw Self.posixError("openat", path) }
        defer { close(descriptor) }
        try Self.validatePrivateFile(descriptor, path: path)
        try Self.lock(descriptor, operation: LOCK_SH, path: path)
        defer { flock(descriptor, LOCK_UN) }
        try validateMapping(for: key, storageID: storageID)
        return try Self.decodeJournal(
            descriptor: descriptor,
            key: key,
            storageID: storageID,
            decoder: decoder,
            path: path
        )
    }

    public func deleteJournal(for key: TerminalConversationKey) async throws {
        let storageID = try Self.storageID(for: key)
        let conversationLock = try await acquireConversationLock(
            storageID: storageID,
            operation: .delete
        )
        defer { Self.releaseLock(conversationLock) }
        try Self.removeIfPresent(
            name: "\(storageID).jsonl",
            directoryDescriptor: journalsDescriptor,
            path: journalURL(for: key).path
        )
        try Self.syncDirectory(
            descriptor: journalsDescriptor,
            path: journalsDirectory.path
        )
        try Self.removeIfPresent(
            name: "\(storageID).json",
            directoryDescriptor: mappingsDescriptor,
            path: mappingURL(for: key).path
        )
        try Self.syncDirectory(
            descriptor: mappingsDescriptor,
            path: mappingsDirectory.path
        )
    }

    /// Lock files are intentionally retained so every process always coordinates
    /// on the same inode, including while a journal and its mapping are absent.
    private func acquireConversationLock(
        storageID: String,
        operation: TerminalJournalOperation
    ) async throws -> Int32 {
        let name = "\(storageID).lock"
        let path = mappingsDirectory.appendingPathComponent(name).path
        var created = true
        var descriptor = openat(
            mappingsDescriptor,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0, errno == EEXIST {
            created = false
            descriptor = openat(
                mappingsDescriptor,
                name,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw Self.posixError("openat", path) }

        do {
            try Self.validatePrivateFile(descriptor, path: path)
            let contended = try Self.lockNonBlocking(
                descriptor,
                operation: LOCK_EX,
                path: path
            )
            if contended {
                try await hooks.conversationLockEvent?(.contended(operation))
                try Self.lock(descriptor, operation: LOCK_EX, path: path)
            }
            try Self.validateAnchoredFileIdentity(
                descriptor,
                name: name,
                directoryDescriptor: mappingsDescriptor,
                path: path
            )
            if created {
                guard fsync(descriptor) == 0 else {
                    throw Self.posixError("fsync", path)
                }
                try Self.syncDirectory(
                    descriptor: mappingsDescriptor,
                    path: mappingsDirectory.path
                )
            }
            try await hooks.conversationLockEvent?(.acquired(operation))
            return descriptor
        } catch {
            Self.releaseLock(descriptor)
            throw error
        }
    }

    private func ensureMapping(
        for key: TerminalConversationKey,
        storageID: String
    ) async throws {
        let finalName = "\(storageID).json"
        if Self.fileExists(
            name: finalName,
            directoryDescriptor: mappingsDescriptor
        ) {
            try validateMapping(for: key, storageID: storageID)
            try syncMappingsDirectory()
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
        let temporaryName = ".\(storageID).\(UUID().uuidString).tmp"
        let temporaryPath = mappingsDirectory
            .appendingPathComponent(temporaryName).path
        let descriptor = openat(
            mappingsDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw Self.posixError("openat", temporaryPath)
        }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary {
                unlinkat(mappingsDescriptor, temporaryName, 0)
            }
        }
        try Self.validatePrivateFile(descriptor, path: temporaryPath)
        try Self.writeAll(data, descriptor: descriptor, path: temporaryPath)
        guard fsync(descriptor) == 0 else {
            throw Self.posixError("fsync", temporaryPath)
        }
        try await hooks.beforeMappingPublish?()

        if renameatx_np(
            mappingsDescriptor,
            temporaryName,
            mappingsDescriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) != 0 {
            guard errno == EEXIST else {
                throw Self.posixError("renameatx_np", mappingURL(for: key).path)
            }
            try validateMapping(for: key, storageID: storageID)
            try syncMappingsDirectory()
            return
        }
        shouldRemoveTemporary = false
        try syncMappingsDirectory()
    }

    private func syncMappingsDirectory() throws {
        if let directorySync = hooks.directorySync {
            try directorySync(mappingsDescriptor, mappingsDirectory.path)
        } else {
            try Self.syncDirectory(
                descriptor: mappingsDescriptor,
                path: mappingsDirectory.path
            )
        }
    }

    private func validateMapping(
        for key: TerminalConversationKey,
        storageID: String
    ) throws {
        let path = mappingURL(for: key).path
        let descriptor = openat(
            mappingsDescriptor,
            "\(storageID).json",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            throw TerminalOperationJournalError.mappingMissing(storageID: storageID)
        }
        guard descriptor >= 0 else { throw Self.posixError("openat", path) }
        defer { close(descriptor) }
        try Self.validatePrivateFile(descriptor, path: path)
        let data = try Self.readAll(descriptor: descriptor, path: path)
        guard
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

    private struct Locations {
        let application: URL
        let root: URL
        let mappings: URL
        let journals: URL
    }

    private static func locations(
        applicationSupportDirectory: URL
    ) -> Locations {
        let application = applicationSupportDirectory
            .appendingPathComponent("MerlinLizd", isDirectory: true)
        let root = application
            .appendingPathComponent("TerminalOperations", isDirectory: true)
        return Locations(
            application: application,
            root: root,
            mappings: root.appendingPathComponent("Mappings", isDirectory: true),
            journals: root.appendingPathComponent("Journals", isDirectory: true)
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func openDirectoryTree(
        locations: Locations,
        hooks: TerminalOperationJournalHooks
    ) throws -> (mappings: Int32, journals: Int32) {
        let supportPath = locations.application.deletingLastPathComponent().path
        let support = open(
            supportPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard support >= 0 else { throw posixError("open", supportPath) }
        defer { close(support) }
        try validateDirectory(support, path: supportPath, makePrivate: false)

        let application = try openPrivateDirectory(
            parent: support,
            name: locations.application.lastPathComponent,
            path: locations.application.path,
            parentPath: supportPath,
            hooks: hooks
        )
        defer { close(application) }
        let root = try openPrivateDirectory(
            parent: application,
            name: locations.root.lastPathComponent,
            path: locations.root.path,
            parentPath: locations.application.path,
            hooks: hooks
        )
        defer { close(root) }
        let mappings = try openPrivateDirectory(
            parent: root,
            name: locations.mappings.lastPathComponent,
            path: locations.mappings.path,
            parentPath: locations.root.path,
            hooks: hooks
        )
        do {
            let journals = try openPrivateDirectory(
                parent: root,
                name: locations.journals.lastPathComponent,
                path: locations.journals.path,
                parentPath: locations.root.path,
                hooks: hooks
            )
            return (mappings, journals)
        } catch {
            close(mappings)
            throw error
        }
    }

    private static func openPrivateDirectory(
        parent: Int32,
        name: String,
        path: String,
        parentPath: String,
        hooks: TerminalOperationJournalHooks
    ) throws -> Int32 {
        if mkdirat(parent, name, S_IRWXU) != 0, errno != EEXIST {
            throw posixError("mkdirat", path)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError("openat", path) }
        do {
            try validateDirectory(descriptor, path: path, makePrivate: true)
            if let directorySync = hooks.directorySync {
                try directorySync(parent, parentPath)
            } else {
                try syncDirectory(descriptor: parent, path: parentPath)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        path: String,
        makePrivate: Bool
    ) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw posixError("fstat", path)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
            information.st_uid == geteuid()
        else {
            throw TerminalOperationJournalError.insecurePath(path: path)
        }
        if makePrivate, fchmod(descriptor, S_IRWXU) != 0 {
            throw posixError("fchmod", path)
        }
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

    private static func validateAnchoredFileIdentity(
        _ descriptor: Int32,
        name: String,
        directoryDescriptor: Int32,
        path: String
    ) throws {
        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0 else {
            throw posixError("fstat", path)
        }
        var anchoredInformation = stat()
        guard fstatat(
            directoryDescriptor,
            name,
            &anchoredInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posixError("fstatat", path)
        }
        guard anchoredInformation.st_mode & S_IFMT == S_IFREG,
            anchoredInformation.st_uid == geteuid(),
            anchoredInformation.st_nlink == 1,
            openedInformation.st_dev == anchoredInformation.st_dev,
            openedInformation.st_ino == anchoredInformation.st_ino
        else {
            throw TerminalOperationJournalError.insecurePath(path: path)
        }
    }

    private static func decodeJournal(
        descriptor: Int32,
        key: TerminalConversationKey,
        storageID: String,
        decoder: JSONDecoder,
        path: String
    ) throws -> [TerminalJournalEvent] {
        let data = try readAll(descriptor: descriptor, path: path)
        guard data.isEmpty || data.last == 0x0A else {
            throw TerminalOperationJournalError.corruptTrailingRecord(
                storageID: storageID
            )
        }
        let lines = [UInt8](data).split(
            separator: UInt8(0x0A),
            omittingEmptySubsequences: false
        ).dropLast()
        var events: [TerminalJournalEvent] = []
        events.reserveCapacity(lines.count)
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
            events.append(event)
        }
        return events
    }

    private static func readAll(
        descriptor: Int32,
        path: String
    ) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw posixError("lseek", path)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError("read", path) }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
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

    private static func syncDirectory(
        descriptor: Int32,
        path: String
    ) throws {
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync", path)
        }
    }

    private static func removeIfPresent(
        name: String,
        directoryDescriptor: Int32,
        path: String
    ) throws {
        if unlinkat(directoryDescriptor, name, 0) != 0, errno != ENOENT {
            throw posixError("unlinkat", path)
        }
    }

    private static func fileExists(
        name: String,
        directoryDescriptor: Int32
    ) -> Bool {
        var information = stat()
        return fstatat(
            directoryDescriptor,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0
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

    private static func lockNonBlocking(
        _ descriptor: Int32,
        operation: Int32,
        path: String
    ) throws -> Bool {
        while flock(descriptor, operation | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN { return true }
            throw posixError("flock", path)
        }
        return false
    }

    private static func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
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

struct TerminalMutationAuditorHooks: Sendable {
    let didQueueForSerialAccess: (@Sendable () -> Void)?

    init(didQueueForSerialAccess: (@Sendable () -> Void)? = nil) {
        self.didQueueForSerialAccess = didQueueForSerialAccess
    }
}

public actor TerminalMutationAuditor {
    private let journal: any TerminalOperationJournaling
    private let hooks: TerminalMutationAuditorHooks
    private var blockedTurns: Set<String> = []
    private var preparedOperations: [
        String: [UUID: TerminalConversationKey]
    ] = [:]
    private var accessInUse = false
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []

    public init(journal: any TerminalOperationJournaling) {
        self.journal = journal
        hooks = TerminalMutationAuditorHooks()
    }

    init(
        journal: any TerminalOperationJournaling,
        hooks: TerminalMutationAuditorHooks
    ) {
        self.journal = journal
        self.hooks = hooks
    }

    public func appendBeforeSideEffect(
        _ events: [TerminalJournalEvent],
        turnID: String
    ) async throws {
        await acquireSerialAccess()
        defer { releaseSerialAccess() }
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
        await acquireSerialAccess()
        defer { releaseSerialAccess() }
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

    public func endTurn(_ turnID: String) async {
        await acquireSerialAccess()
        defer { releaseSerialAccess() }
        blockedTurns.remove(turnID)
        preparedOperations.removeValue(forKey: turnID)
    }

    private func validPreActionBundle(
        _ events: [TerminalJournalEvent],
        turnID: String
    ) -> Bool {
        guard events.count >= 3,
            let first = events.first,
            events.allSatisfy({ event in
                event.turnID == turnID
                    && event.key == first.key
                    && event.operationID == first.operationID
            })
        else {
            return false
        }

        guard case let .request(_, purpose) = events[0].kind,
            case let .screen(screen) = events[1].kind,
            case let .risk(agentDeclared, deterministic, effective) = events[2].kind,
            effective == max(agentDeclared, deterministic)
        else { return false }

        let endpointIndex: Int
        let emittedIndex: Int
        var approval: (scope: TerminalApprovalScope, outcome: TerminalJournalApprovalOutcome)?
        if effective == .high {
            guard events.count == 6,
                case let .approval(_, scope, outcome) = events[3].kind
            else { return false }
            approval = (scope, outcome)
            endpointIndex = 4
            emittedIndex = 5
        } else {
            guard events.count == 5 else { return false }
            endpointIndex = 3
            emittedIndex = 4
        }

        guard case let .endpoint(endpointID) = events[endpointIndex].kind,
            case let .emittedBatch(batch) = events[emittedIndex].kind,
            purpose == batch.purpose,
            agentDeclared == batch.declaredRisk,
            screen.revision == batch.expectedRevision
        else { return false }

        guard let recomputed = try? TerminalPermissionPolicy().evaluate(
            batch: batch,
            endpointID: endpointID,
            screen: screen
        ), recomputed.deterministicRisk == deterministic,
            recomputed.effectiveRisk == effective
        else { return false }
        if case .deny = recomputed.decision { return false }

        if let approval {
            guard approval.outcome == .approvedOnce,
                approval.scope.endpointID == endpointID,
                approval.scope.screenRevision == screen.revision,
                let expectedScope = try? TerminalApprovalScope(
                    batch: batch,
                    endpointID: endpointID,
                    screenRevision: screen.revision
                ),
                approval.scope == expectedScope
            else { return false }
        }
        return true
    }

    private func acquireSerialAccess() async {
        if !accessInUse {
            accessInUse = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
            hooks.didQueueForSerialAccess?()
        }
    }

    private func releaseSerialAccess() {
        guard !accessWaiters.isEmpty else {
            accessInUse = false
            return
        }
        accessWaiters.removeFirst().resume()
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
