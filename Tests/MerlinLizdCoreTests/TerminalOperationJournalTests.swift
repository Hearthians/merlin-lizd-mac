import Testing
@testable import MerlinLizdCore

@Suite("Terminal operation journal", .serialized)
struct TerminalOperationJournalTests {
    @Test("records the complete mutation timeline in append order")
    func preservesEventOrderAndContent() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let batch = terminalTestBatch(
            events: [.text("git push origin main")],
            risk: .high
        )
        let scope = try TerminalApprovalScope(
            batch: batch,
            endpointID: terminalTestEndpoint(),
            screenRevision: 7
        )
        let events: [TerminalJournalEvent] = [
            terminalTestJournalEvent(
                kind: .request(operation: "sendInput", purpose: batch.purpose)
            ),
            terminalTestJournalEvent(
                kind: .screen(
                    revision: 7,
                    changedRows: [2, 3],
                    text: "git push origin main\\nProceed? [y/N]"
                )
            ),
            terminalTestJournalEvent(
                kind: .risk(
                    agentDeclared: .high,
                    deterministic: .high,
                    effective: .high
                )
            ),
            terminalTestJournalEvent(
                kind: .approval(
                    requestID: terminalUUID(
                        "20000000-0000-0000-0000-000000000001"
                    ),
                    scope: scope,
                    outcome: .approvedOnce
                )
            ),
            terminalTestJournalEvent(
                kind: .endpoint(terminalTestEndpoint())
            ),
            terminalTestJournalEvent(kind: .emittedBatch(batch)),
            terminalTestJournalEvent(
                kind: .result(
                    .success(
                        TerminalInputReceipt(acceptedRevision: 7, byteCount: 20)
                    )
                )
            ),
            terminalTestJournalEvent(
                kind: .temporaryPane(
                    .retained(
                        leaseID: terminalUUID(
                            "30000000-0000-0000-0000-000000000001"
                        ),
                        paneID: "%9",
                        reason: "background job remains"
                    )
                )
            ),
        ]

        for event in events {
            try await journal.append(event)
        }

        #expect(
            try await journal.entries(for: terminalTestConversationKey())
                == events
        )
    }

    @Test("uses user-only directories and files with SHA-256 storage IDs")
    func securesStoragePaths() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let key = terminalTestConversationKey()
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        try await journal.append(
            terminalTestJournalEvent(kind: .request(operation: "observe", purpose: "test"))
        )

        let storageID = try FileTerminalOperationJournal.storageID(for: key)
        let journalURL = journal.journalURL(for: key)
        let mappingURL = journal.mappingURL(for: key)
        #expect(storageID.count == 64)
        #expect(
            storageID
                == "dbe20858b7ee441f77437c80b6dba433f23f926db9553d62cf139a5269776c39"
        )
        #expect(storageID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(journalURL.lastPathComponent == "\(storageID).jsonl")
        #expect(mappingURL.lastPathComponent == "\(storageID).json")
        #expect(!journalURL.path.contains("dbx-secret"))
        #expect(!journalURL.path.contains("worker-secret"))
        #expect(!journalURL.path.contains("$3"))
        #expect(try terminalPOSIXMode(at: journal.rootDirectory) == 0o700)
        #expect(try terminalPOSIXMode(at: journal.mappingsDirectory) == 0o700)
        #expect(try terminalPOSIXMode(at: journal.journalsDirectory) == 0o700)
        #expect(try terminalPOSIXMode(at: mappingURL) == 0o600)
        #expect(try terminalPOSIXMode(at: journalURL) == 0o600)
    }

    @Test("first directory creation durably syncs each parent in dependency order")
    func syncsParentsForNewDirectoryEntries() throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let recorder = TerminalDirectorySyncRecorder()

        _ = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                directorySync: recorder.sync
            )
        )

        let application = fixture.applicationSupportDirectory
            .appendingPathComponent("MerlinLizd", isDirectory: true)
        let root = application
            .appendingPathComponent("TerminalOperations", isDirectory: true)
        #expect(
            recorder.paths() == [
                fixture.applicationSupportDirectory.path,
                application.path,
                root.path,
                root.path,
            ]
        )
    }

    @Test("a parent directory sync failure aborts initialization unchanged")
    func propagatesDirectorySyncFailure() throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let recorder = TerminalDirectorySyncRecorder(failingCall: 2)
        let application = fixture.applicationSupportDirectory
            .appendingPathComponent("MerlinLizd", isDirectory: true)

        #expect(throws: ScriptedTerminalJournalError.unavailable) {
            _ = try FileTerminalOperationJournal(
                applicationSupportDirectory: fixture.applicationSupportDirectory,
                hooks: TerminalOperationJournalHooks(
                    directorySync: recorder.sync
                )
            )
        }
        #expect(
            recorder.paths() == [
                fixture.applicationSupportDirectory.path,
                application.path,
            ]
        )
    }

    @Test("each returned durability boundary contains only complete JSONL records")
    func writesCompleteRecordsPerSyncBoundary() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let key = terminalTestConversationKey()
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let first = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "first")
        )
        let second = terminalTestJournalEvent(
            kind: .result(.failure(reason: "PTY disconnected"))
        )

        try await journal.append(first)
        let firstData = try terminalRawData(at: journal.journalURL(for: key))
        #expect(firstData.last == 0x0A)
        #expect(try terminalRawJournalLines(at: journal.journalURL(for: key)).count == 1)
        #expect(try await journal.entries(for: key) == [first])

        try await journal.append(second)
        let secondData = try terminalRawData(at: journal.journalURL(for: key))
        #expect(secondData.last == 0x0A)
        #expect(try terminalRawJournalLines(at: journal.journalURL(for: key)).count == 2)
        #expect(try await journal.entries(for: key) == [first, second])
    }

    @Test("records survive a journal actor re-open")
    func survivesReopen() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let key = terminalTestConversationKey()
        let event = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "reopen")
        )
        let original = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        try await original.append(event)

        let reopened = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        #expect(try await reopened.entries(for: key) == [event])
    }

    @Test("partial trailing JSONL is corruption and is never silently skipped")
    func rejectsPartialTrailingRecord() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let key = terminalTestConversationKey()
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        try await journal.append(
            terminalTestJournalEvent(
                kind: .request(operation: "sendInput", purpose: "partial")
            )
        )
        let url = journal.journalURL(for: key)
        try appendTerminalPartialRecord(#"{"partial":true"#, at: url)

        let reopened = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let storageID = try FileTerminalOperationJournal.storageID(for: key)
        await #expect(
            throws: TerminalOperationJournalError.corruptTrailingRecord(
                storageID: storageID
            )
        ) {
            try await reopened.entries(for: key)
        }
        await #expect(
            throws: TerminalOperationJournalError.corruptTrailingRecord(
                storageID: storageID
            )
        ) {
            try await reopened.append(
                terminalTestJournalEvent(
                    kind: .result(.failure(reason: "must not append"))
                )
            )
        }
    }

    @Test("a newline-terminated malformed record prevents every later append")
    func rejectsMalformedCompleteHistoryBeforeAppend() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let key = terminalTestConversationKey()
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        try await journal.append(
            terminalTestJournalEvent(
                kind: .request(operation: "sendInput", purpose: "valid")
            )
        )
        try appendTerminalPartialRecord("{}\n", at: journal.journalURL(for: key))
        let storageID = try FileTerminalOperationJournal.storageID(for: key)

        await #expect(
            throws: TerminalOperationJournalError.corruptRecord(
                storageID: storageID,
                line: 2
            )
        ) {
            try await journal.append(
                terminalTestJournalEvent(kind: .result(.success(nil)))
            )
        }
        #expect(try terminalRawJournalLines(at: journal.journalURL(for: key)).count == 2)
    }

    @Test("concurrent journal instances publish one mapping and preserve both records")
    func coordinatesConcurrentJournalInstances() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let firstJournal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let secondJournal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let first = terminalTestJournalEvent(
            operationID: terminalUUID("10000000-0000-0000-0000-000000000010"),
            kind: .request(operation: "sendInput", purpose: "first")
        )
        let second = terminalTestJournalEvent(
            operationID: terminalUUID("10000000-0000-0000-0000-000000000011"),
            kind: .request(operation: "sendInput", purpose: "second")
        )

        async let appendFirst: Void = firstJournal.append(first)
        async let appendSecond: Void = secondJournal.append(second)
        _ = try await (appendFirst, appendSecond)

        let entries = try await firstJournal.entries(for: first.key)
        #expect(entries.count == 2)
        #expect(entries.contains(first))
        #expect(entries.contains(second))
    }

    @Test("append holding the conversation lock completes before a racing delete")
    func appendThenDeleteHasReachableLinearization() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let initial = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let first = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "initial")
        )
        try await initial.append(first)

        let appendAcquired = AsyncStartGate()
        let deleteContended = AsyncStartGate()
        let deleteAcquired = AsyncStartGate()
        let appender = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                conversationLockEvent: { event in
                    if event == .acquired(.append) {
                        await appendAcquired.wait()
                    }
                }
            )
        )
        let deleter = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                conversationLockEvent: { event in
                    if event == .contended(.delete) {
                        await deleteContended.wait()
                    } else if event == .acquired(.delete) {
                        await deleteAcquired.wait()
                    }
                }
            )
        )
        let second = terminalTestJournalEvent(
            operationID: terminalUUID("10000000-0000-0000-0000-000000000013"),
            kind: .result(.success(nil))
        )

        let append = Task { try await appender.append(second) }
        await appendAcquired.waitUntilEntered()
        let delete = Task { try await deleter.deleteJournal(for: first.key) }
        await deleteContended.waitUntilEntered()
        await deleteContended.open()
        await appendAcquired.open()
        try await append.value
        await deleteAcquired.waitUntilEntered()
        #expect(terminalFileExists(at: initial.journalURL(for: first.key)))
        await deleteAcquired.open()
        try await delete.value

        #expect(try await initial.entries(for: first.key).isEmpty)
    }

    @Test("delete holding the conversation lock completes before a racing append")
    func deleteThenAppendRecreatesReachableJournal() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let initial = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let first = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "initial")
        )
        try await initial.append(first)

        let deleteAcquired = AsyncStartGate()
        let appendContended = AsyncStartGate()
        let appendAcquired = AsyncStartGate()
        let deleter = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                conversationLockEvent: { event in
                    if event == .acquired(.delete) {
                        await deleteAcquired.wait()
                    }
                }
            )
        )
        let appender = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                conversationLockEvent: { event in
                    if event == .contended(.append) {
                        await appendContended.wait()
                    } else if event == .acquired(.append) {
                        await appendAcquired.wait()
                    }
                }
            )
        )
        let second = terminalTestJournalEvent(
            operationID: terminalUUID("10000000-0000-0000-0000-000000000014"),
            kind: .result(.success(nil))
        )

        let delete = Task { try await deleter.deleteJournal(for: first.key) }
        await deleteAcquired.waitUntilEntered()
        let append = Task { try await appender.append(second) }
        await appendContended.waitUntilEntered()
        await appendContended.open()
        await deleteAcquired.open()
        try await delete.value
        await appendAcquired.waitUntilEntered()
        #expect(!terminalFileExists(at: initial.journalURL(for: first.key)))
        await appendAcquired.open()
        try await append.value

        #expect(try await initial.entries(for: first.key) == [second])
    }

    @Test("mapping name is unpublished until its durable temporary file is ready")
    func publishesMappingOnlyAfterDurablePreparation() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let gate = AsyncStartGate()
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                beforeMappingPublish: {
                    await gate.wait()
                }
            )
        )
        let event = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "gated")
        )
        let append = Task { try await journal.append(event) }
        await gate.waitUntilEntered()

        #expect(!terminalFileExists(at: journal.mappingURL(for: event.key)))
        await gate.open()
        try await append.value
        #expect(terminalFileExists(at: journal.mappingURL(for: event.key)))
    }

    @Test("an interrupted mapping preparation never exposes a partial final mapping")
    func mappingPreparationFailureLeavesNoFinalName() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let event = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "crash")
        )
        let crashing = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            hooks: TerminalOperationJournalHooks(
                beforeMappingPublish: {
                    throw ScriptedTerminalJournalError.unavailable
                }
            )
        )

        await #expect(throws: ScriptedTerminalJournalError.unavailable) {
            try await crashing.append(event)
        }
        #expect(!terminalFileExists(at: crashing.mappingURL(for: event.key)))

        let reopened = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        try await reopened.append(event)
        #expect(try await reopened.entries(for: event.key) == [event])
    }

    @Test("directory descriptor anchoring contains mappings and journals across symlink swaps")
    func containsAncestorSymlinkSwaps() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let outside = fixture.applicationSupportDirectory
            .appendingPathComponent("Outside", isDirectory: true)
        try createTerminalDirectory(at: outside)
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let mappingsOriginal = journal.rootDirectory
            .appendingPathComponent("Mappings.original", isDirectory: true)
        try moveTerminalItem(
            at: journal.mappingsDirectory,
            to: mappingsOriginal
        )
        try createTerminalSymbolicLink(
            at: journal.mappingsDirectory,
            destination: outside
        )
        let first = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "mapping swap")
        )
        try await journal.append(first)
        #expect(try terminalDirectoryIsEmpty(outside))

        let journalsOriginal = journal.rootDirectory
            .appendingPathComponent("Journals.original", isDirectory: true)
        try moveTerminalItem(
            at: journal.journalsDirectory,
            to: journalsOriginal
        )
        try createTerminalSymbolicLink(
            at: journal.journalsDirectory,
            destination: outside
        )
        let second = terminalTestJournalEvent(
            operationID: terminalUUID("10000000-0000-0000-0000-000000000012"),
            kind: .result(.success(nil))
        )
        try await journal.append(second)

        #expect(try terminalDirectoryIsEmpty(outside))
        #expect(try await journal.entries(for: first.key) == [first, second])
    }

    @Test("deleting one conversation removes only its mapping and journal")
    func deletesOnlySelectedConversation() async throws {
        let fixture = try TerminalPersistenceFixture()
        defer { fixture.remove() }
        let firstKey = terminalTestConversationKey()
        let secondKey = terminalTestConversationKey(
            serverSessionID: "$9",
            createdAtEpoch: 200
        )
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let first = terminalTestJournalEvent(
            key: firstKey,
            kind: .request(operation: "observe", purpose: "first")
        )
        let second = terminalTestJournalEvent(
            key: secondKey,
            kind: .request(operation: "observe", purpose: "second")
        )
        try await journal.append(first)
        try await journal.append(second)

        try await journal.deleteJournal(for: firstKey)

        #expect(try await journal.entries(for: firstKey).isEmpty)
        #expect(try await journal.entries(for: secondKey) == [second])
        #expect(!terminalFileExists(at: journal.mappingURL(for: firstKey)))
        #expect(!terminalFileExists(at: journal.journalURL(for: firstKey)))
        #expect(terminalFileExists(at: journal.mappingURL(for: secondKey)))
        #expect(terminalFileExists(at: journal.journalURL(for: secondKey)))
    }

    @Test("audit failures deny before action and block the turn after action")
    func auditFailureIsFailClosed() async throws {
        let preActionEvents = terminalRoutinePreActionEvents(
            turnID: "pre-failure"
        )
        let preFailureJournal = ScriptedTerminalJournal(
            failingAppendNumbers: [1]
        )
        let preAuditor = TerminalMutationAuditor(journal: preFailureJournal)

        await #expect(
            throws: TerminalMutationAuditError.denied(
                reason: "Audit journal unavailable"
            )
        ) {
            try await preAuditor.appendBeforeSideEffect(
                preActionEvents,
                turnID: "pre-failure"
            )
        }
        await #expect(throws: TerminalMutationAuditError.auditUnavailable) {
            try await preAuditor.appendBeforeSideEffect(
                preActionEvents,
                turnID: "pre-failure"
            )
        }
        #expect(await preFailureJournal.appendCount() == 1)

        let postFailureJournal = ScriptedTerminalJournal(
            failingAppendNumbers: [6]
        )
        let postAuditor = TerminalMutationAuditor(journal: postFailureJournal)
        try await postAuditor.appendBeforeSideEffect(
            terminalRoutinePreActionEvents(turnID: "post-failure"),
            turnID: "post-failure"
        )
        await #expect(throws: TerminalMutationAuditError.auditUnavailable) {
            try await postAuditor.appendAfterSideEffect(
                terminalTestJournalEvent(
                    turnID: "post-failure",
                    kind: .result(.success(nil))
                ),
                turnID: "post-failure"
            )
        }
        await #expect(throws: TerminalMutationAuditError.auditUnavailable) {
            try await postAuditor.appendBeforeSideEffect(
                terminalRoutinePreActionEvents(turnID: "post-failure"),
                turnID: "post-failure"
            )
        }
        #expect(await postFailureJournal.appendCount() == 6)
    }

    @Test("pre-action audit requires ordered request risk endpoint and high-risk approval")
    func validatesPreActionAuditBundle() async throws {
        let journal = ScriptedTerminalJournal(failingAppendNumbers: [])
        let auditor = TerminalMutationAuditor(journal: journal)
        let request = terminalTestJournalEvent(
            kind: .request(operation: "sendInput", purpose: "audit")
        )
        let risk = terminalTestJournalEvent(
            kind: .risk(
                agentDeclared: .high,
                deterministic: .high,
                effective: .high
            )
        )
        let endpoint = terminalTestJournalEvent(
            kind: .endpoint(terminalTestEndpoint())
        )

        await #expect(
            throws: TerminalMutationAuditError.denied(
                reason: "Required pre-action audit events are missing or out of order"
            )
        ) {
            try await auditor.appendBeforeSideEffect(
                [request, risk, endpoint],
                turnID: "missing-approval"
            )
        }
        #expect(await journal.appendCount() == 0)
    }

    @Test("post-action audit must match a prepared operation in the same turn")
    func validatesPostActionAuditIdentity() async throws {
        let journal = ScriptedTerminalJournal(failingAppendNumbers: [])
        let auditor = TerminalMutationAuditor(journal: journal)
        try await auditor.appendBeforeSideEffect(
            terminalRoutinePreActionEvents(turnID: "prepared-turn"),
            turnID: "prepared-turn"
        )

        await #expect(throws: TerminalMutationAuditError.auditUnavailable) {
            try await auditor.appendAfterSideEffect(
                terminalTestJournalEvent(
                    turnID: "different-turn",
                    kind: .result(.success(nil))
                ),
                turnID: "prepared-turn"
            )
        }
        #expect(await journal.appendCount() == 5)
    }

    @Test("pre-action audit enforces the exact mutation grammar and linked scope")
    func rejectsMalformedPreActionGrammar() async throws {
        let turnID = "exact-grammar"
        let valid = terminalRoutinePreActionEvents(turnID: turnID)
        let mismatchedBatch = terminalTestBatch(
            events: [.text("echo changed")],
            purpose: "audit"
        )
        let forgedGitPush = terminalTestBatch(
            events: [.text("git push origin main")],
            purpose: "audit"
        )
        let forgedPromptAcceptance = terminalTestBatch(
            events: [.key(.enter, modifiers: [])],
            purpose: "audit"
        )
        let malformed: [[TerminalJournalEvent]] = [
            [],
            [valid[0]],
            [valid[0], valid[1]],
            Array(valid.dropLast()),
            [valid[0], valid[2], valid[1], valid[3], valid[4]],
            [
                valid[0], valid[1],
                terminalTestJournalEvent(
                    turnID: turnID,
                    kind: .risk(
                        agentDeclared: .high,
                        deterministic: .routine,
                        effective: .routine
                    )
                ),
                valid[3], valid[4],
            ],
            valid + [
                terminalTestJournalEvent(
                    turnID: turnID,
                    kind: .result(.success(nil))
                ),
            ],
            [
                valid[0], valid[1], valid[2], valid[3],
                terminalTestJournalEvent(
                    turnID: turnID,
                    kind: .emittedBatch(forgedGitPush)
                ),
            ],
            [
                valid[0],
                terminalTestJournalEvent(
                    turnID: turnID,
                    kind: .screen(
                        revision: 7,
                        changedRows: [0],
                        text: "Delete all data permanently? [y/N]"
                    )
                ),
                valid[2], valid[3],
                terminalTestJournalEvent(
                    turnID: turnID,
                    kind: .emittedBatch(forgedPromptAcceptance)
                ),
            ],
        ]

        for events in malformed {
            let journal = ScriptedTerminalJournal(failingAppendNumbers: [])
            let auditor = TerminalMutationAuditor(journal: journal)
            do {
                try await auditor.appendBeforeSideEffect(events, turnID: turnID)
                Issue.record("malformed pre-action bundle was accepted")
            } catch let error as TerminalMutationAuditError {
                #expect(
                    error == .denied(
                        reason: "Required pre-action audit events are missing or out of order"
                    )
                )
            }
            #expect(await journal.appendCount() == 0)
        }

        let highBatch = terminalTestBatch(
            events: [.text("git push origin main")],
            risk: .high
        )
        let scope = try TerminalApprovalScope(
            batch: highBatch,
            endpointID: terminalTestEndpoint(),
            screenRevision: highBatch.expectedRevision
        )
        let operationID = terminalUUID("10000000-0000-0000-0000-000000000009")
        let highEvents: [TerminalJournalEvent] = [
            terminalTestJournalEvent(
                operationID: operationID,
                turnID: turnID,
                kind: .request(operation: "sendInput", purpose: highBatch.purpose)
            ),
            terminalTestJournalEvent(
                operationID: operationID,
                turnID: turnID,
                kind: .screen(revision: 7, changedRows: [0], text: "$ ")
            ),
            terminalTestJournalEvent(
                operationID: operationID,
                turnID: turnID,
                kind: .risk(
                    agentDeclared: .high,
                    deterministic: .high,
                    effective: .high
                )
            ),
            terminalTestJournalEvent(
                operationID: operationID,
                turnID: turnID,
                kind: .approval(
                    requestID: terminalUUID(),
                    scope: scope,
                    outcome: .approvedOnce
                )
            ),
            terminalTestJournalEvent(
                operationID: operationID,
                turnID: turnID,
                kind: .endpoint(terminalTestEndpoint())
            ),
            terminalTestJournalEvent(
                operationID: operationID,
                turnID: turnID,
                kind: .emittedBatch(highBatch)
            ),
        ]
        let validJournal = ScriptedTerminalJournal(failingAppendNumbers: [])
        let validAuditor = TerminalMutationAuditor(journal: validJournal)
        try await validAuditor.appendBeforeSideEffect(highEvents, turnID: turnID)
        #expect(await validJournal.appendCount() == highEvents.count)

        var forgedHigh = highEvents
        forgedHigh[5] = terminalTestJournalEvent(
            operationID: operationID,
            turnID: turnID,
            kind: .emittedBatch(mismatchedBatch)
        )
        let forgedJournal = ScriptedTerminalJournal(failingAppendNumbers: [])
        let forgedAuditor = TerminalMutationAuditor(journal: forgedJournal)
        await #expect(throws: TerminalMutationAuditError.denied(
            reason: "Required pre-action audit events are missing or out of order"
        )) {
            try await forgedAuditor.appendBeforeSideEffect(
                forgedHigh,
                turnID: turnID
            )
        }
        #expect(await forgedJournal.appendCount() == 0)
    }

    @Test("a failing pre-action write serializes concurrent audit attempts")
    func serializesAuditFailureAcrossActorReentrancy() async throws {
        let gate = AsyncStartGate()
        let journal = GatedFailingTerminalJournal(gate: gate)
        let auditor = TerminalMutationAuditor(journal: journal)
        let events = terminalRoutinePreActionEvents(turnID: "reentrant")

        let first = Task {
            try await auditor.appendBeforeSideEffect(events, turnID: "reentrant")
        }
        await gate.waitUntilEntered()
        let second = Task {
            try await auditor.appendBeforeSideEffect(events, turnID: "reentrant")
        }
        await Task.yield()
        await gate.open()

        await #expect(throws: TerminalMutationAuditError.denied(
            reason: "Audit journal unavailable"
        )) {
            try await first.value
        }
        await #expect(throws: TerminalMutationAuditError.auditUnavailable) {
            try await second.value
        }
        #expect(await journal.appendCount() == 1)
    }

    private func terminalRoutinePreActionEvents(
        turnID: String
    ) -> [TerminalJournalEvent] {
        let batch = terminalTestBatch(purpose: "audit")
        return [
            terminalTestJournalEvent(
                turnID: turnID,
                kind: .request(operation: "sendInput", purpose: "audit")
            ),
            terminalTestJournalEvent(
                turnID: turnID,
                kind: .screen(revision: 7, changedRows: [0], text: "$ ")
            ),
            terminalTestJournalEvent(
                turnID: turnID,
                kind: .risk(
                    agentDeclared: .routine,
                    deterministic: .routine,
                    effective: .routine
                )
            ),
            terminalTestJournalEvent(
                turnID: turnID,
                kind: .endpoint(terminalTestEndpoint())
            ),
            terminalTestJournalEvent(
                turnID: turnID,
                kind: .emittedBatch(batch)
            ),
        ]
    }
}
