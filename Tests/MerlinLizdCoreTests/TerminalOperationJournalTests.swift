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
            failingAppendNumbers: [5]
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
        #expect(await postFailureJournal.appendCount() == 5)
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
        #expect(await journal.appendCount() == 4)
    }

    private func terminalRoutinePreActionEvents(
        turnID: String
    ) -> [TerminalJournalEvent] {
        [
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
        ]
    }
}
