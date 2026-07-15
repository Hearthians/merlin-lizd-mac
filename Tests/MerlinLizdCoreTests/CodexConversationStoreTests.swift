import Testing
@testable import MerlinLizdCore

@Suite("Codex conversation store", .serialized)
struct CodexConversationStoreTests {
    @Test("one conversation key resumes one exact thread across store launches")
    func persistsExactMappingAcrossLaunches() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let record = codexTestRecord()
        let first = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )

        _ = try await first.apply(.upsert(record))

        let relaunched = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let snapshot = try await relaunched.snapshot()
        #expect(snapshot.records[record.key] == record)
        #expect(snapshot.deletions.isEmpty)
        #expect(snapshot.archiveReconciliations.isEmpty)
    }

    @Test("same-name tmux recreation is a distinct conversation identity")
    func recreatedTmuxIdentityGetsDistinctMapping() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let original = codexTestRecord()
        let recreated = codexTestRecord(
            key: codexTestKey(createdAtEpoch: 1_721_000_999),
            threadID: "thread-recreated"
        )

        _ = try await store.apply(.upsert(original))
        let snapshot = try await store.apply(.upsert(recreated))

        #expect(snapshot.records.count == 2)
        #expect(snapshot.records[original.key]?.threadID == original.threadID)
        #expect(snapshot.records[recreated.key]?.threadID == recreated.threadID)
    }

    @Test("different conversation keys cannot persist the same remote thread")
    func rejectsDuplicateRemoteThreadOwnership() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let original = codexTestRecord()
        let conflicting = codexTestRecord(
            key: codexTestKey(createdAtEpoch: 1_721_000_999),
            threadID: original.threadID.rawValue
        )
        _ = try await store.apply(.upsert(original))

        await #expect(throws: CodexConversationStoreError.self) {
            _ = try await store.apply(.upsert(conflicting))
        }
        let snapshot = try await store.snapshot()
        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[original.key] == original)
    }

    @Test("two store instances compare and insert one immutable identity")
    func compareAndInsertKeepsTheFirstThreadAcrossInstances() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let first = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let second = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let firstCandidate = codexTestRecord(threadID: "thread-first")
        let secondCandidate = codexTestRecord(threadID: "thread-second")
        let gate = CodexSessionTestGate()

        let firstInsert = Task {
            await gate.wait()
            return try await first.apply(.insertIfAbsent(firstCandidate))
        }
        let secondInsert = Task {
            await gate.wait()
            return try await second.apply(.insertIfAbsent(secondCandidate))
        }
        await gate.open()

        let snapshots = try await [firstInsert.value, secondInsert.value]
        let winners = Set(snapshots.compactMap {
            $0.records[firstCandidate.key]?.threadID
        })
        #expect(winners.count == 1)
        #expect(
            winners == [firstCandidate.threadID]
                || winners == [secondCandidate.threadID]
        )
        let relaunched = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        #expect(
            try await relaunched.snapshot().records[firstCandidate.key]?.threadID
                == winners.first
        )
    }

    @Test("an already-open store refreshes authoritative deletion state")
    func snapshotRefreshesChangesFromAnotherOpenStore() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let writer = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let reader = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let record = codexTestRecord(threadID: "cross-store-thread")

        _ = try await writer.apply(.upsert(record))
        #expect(try await reader.snapshot().records[record.key] == record)
        _ = try await writer.apply(.beginDeletion(
            key: record.key,
            updatedAt: record.updatedAt
        ))
        #expect(
            try await reader.snapshot().deletions[record.key]?.threadID
                == record.threadID
        )
        for stage in [
            CodexDeletionStage.remoteThreadDeleted,
            .journalDeleted,
            .routerForgotten,
        ] {
            _ = try await writer.apply(.advanceDeletion(
                key: record.key,
                stage: stage,
                updatedAt: record.updatedAt
            ))
        }
        _ = try await writer.apply(.completeDeletion(key: record.key))

        let completed = try await reader.snapshot()
        #expect(completed.records[record.key] == nil)
        #expect(completed.deletions[record.key] == nil)
    }

    @Test("records fail closed on an unsupported protocol generation")
    func rejectsUnsupportedProtocolGeneration() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let invalid = CodexConversationRecord(
            key: codexTestKey(),
            threadID: AgentThreadID(rawValue: "wrong-generation-thread"),
            protocolGeneration: "app-server-future"
        )

        await #expect(throws: CodexConversationStoreError.self) {
            _ = try await store.apply(.upsert(invalid))
        }
        #expect(try await store.snapshot().records.isEmpty)
    }

    @Test("conversation storage uses the shared private Application Support root")
    func createsPrivateStorage() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(codexTestRecord()))

        #expect(
            store.rootDirectory.path
                == fixture.applicationSupportDirectory
                    .appendingPathComponent("MerlinLizd", isDirectory: true)
                    .appendingPathComponent(
                        "CodexConversations",
                        isDirectory: true
                    ).path
        )
        #expect(try codexPOSIXMode(at: store.rootDirectory) == 0o700)
        #expect(try codexPOSIXMode(at: store.storeURL) == 0o600)
    }

    @Test("deletion intent and exact completed stage survive relaunch")
    func persistsRetryableDeletionStagesWithoutDroppingMapping() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let record = codexTestRecord()
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(record))
        _ = try await store.apply(
            .beginDeletion(key: record.key, updatedAt: record.updatedAt)
        )
        _ = try await store.apply(
            .advanceDeletion(
                key: record.key,
                stage: .remoteThreadDeleted,
                updatedAt: record.updatedAt.addingTimeInterval(1)
            )
        )
        _ = try await store.apply(
            .recordDeletionFailure(
                key: record.key,
                failure: .journalUnavailable,
                updatedAt: record.updatedAt.addingTimeInterval(2)
            )
        )

        let relaunched = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let snapshot = try await relaunched.snapshot()
        let tombstone = snapshot.deletions[record.key]
        #expect(snapshot.records[record.key] == record)
        #expect(tombstone?.threadID == record.threadID)
        #expect(tombstone?.protocolGeneration == "app-server-0.144")
        #expect(tombstone?.lastCompletedStage == .remoteThreadDeleted)
        #expect(tombstone?.failure == .journalUnavailable)
    }

    @Test("failed loser compensation preserves a bounded orphan reference")
    func persistsOrphanThreadForRetryAcrossRelaunch() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let orphan = CodexOrphanedThread(
            threadID: AgentThreadID(rawValue: "thread-orphan"),
            attemptedKey: codexTestKey(),
            failure: .remoteUnavailable,
            updatedAt: codexTestRecord().updatedAt.addingTimeInterval(23)
        )

        _ = try await store.apply(.recordOrphan(orphan))

        let relaunched = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        #expect(
            try await relaunched.snapshot().orphans[orphan.threadID] == orphan
        )
        _ = try await relaunched.apply(
            .removeOrphan(threadID: orphan.threadID)
        )
        #expect(try await relaunched.snapshot().orphans.isEmpty)
    }

    @Test("completed deletion atomically removes mapping and tombstone")
    func completesDeletionAfterEveryDurableStage() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let record = codexTestRecord()
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(record))
        _ = try await store.apply(
            .beginDeletion(key: record.key, updatedAt: record.updatedAt)
        )
        for (offset, stage) in [
            CodexDeletionStage.remoteThreadDeleted,
            .journalDeleted,
            .routerForgotten,
        ].enumerated() {
            _ = try await store.apply(
                .advanceDeletion(
                    key: record.key,
                    stage: stage,
                    updatedAt: record.updatedAt.addingTimeInterval(
                        Double(offset + 1)
                    )
                )
            )
        }

        let snapshot = try await store.apply(.completeDeletion(key: record.key))
        #expect(snapshot.records[record.key] == nil)
        #expect(snapshot.deletions[record.key] == nil)
    }

    @Test("archive intent is durable before remote mutation and commits together")
    func persistsArchiveReconciliation() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let record = codexTestRecord()
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(record))
        var snapshot = try await store.apply(
            .beginArchiveChange(
                key: record.key,
                desiredArchived: true,
                updatedAt: record.updatedAt.addingTimeInterval(1)
            )
        )
        #expect(snapshot.records[record.key]?.archived == false)
        #expect(
            snapshot.archiveReconciliations[record.key]?.stage
                == .intentPersisted
        )

        snapshot = try await store.apply(
            .advanceArchiveChange(
                key: record.key,
                stage: .remoteApplied,
                updatedAt: record.updatedAt.addingTimeInterval(2)
            )
        )
        #expect(snapshot.records[record.key]?.archived == false)
        snapshot = try await store.apply(
            .completeArchiveChange(
                key: record.key,
                updatedAt: record.updatedAt.addingTimeInterval(3)
            )
        )
        #expect(snapshot.records[record.key]?.archived == true)
        #expect(snapshot.archiveReconciliations[record.key] == nil)
    }

    @Test("corrupt persisted state fails closed instead of resetting mappings")
    func rejectsCorruptEnvelope() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(codexTestRecord()))
        try codexWrite(#"{"records":["#, to: store.storeURL)

        #expect(throws: CodexConversationStoreError.self) {
            _ = try FileCodexConversationStore(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            )
        }
    }
}
