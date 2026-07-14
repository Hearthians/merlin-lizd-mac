import Testing
@testable import MerlinLizdCore

@Suite("SwiftTerm frame fixtures")
struct SwiftTermFrameFixtureTests {
    @Test("shell Vim and menu fixtures preserve rendered terminal semantics")
    func fixturesPreserveRenderedTerminalSemantics() throws {
        let shell = try fixture(named: "shell")
        let vim = try fixture(named: "vim")
        let menu = try fixture(named: "menu")

        #expect(shell.columns == 8)
        #expect(shell.rows == 3)
        #expect(shell.cursor == .init(row: 2, column: 2, isVisible: true))
        #expect(shell.mode == .normal)

        #expect(vim.cursor == .init(row: 0, column: 4, isVisible: true))
        #expect(vim.mode == .init(
            isAlternateScreen: true,
            keyboardMode: .applicationCursor
        ))

        #expect(menu.cursor == .init(row: 1, column: 0, isVisible: false))

        var reducer = TerminalScreenReducer()
        let shellSnapshot = reducer.accept(shell)
        let vimSnapshot = reducer.accept(vim)
        let menuSnapshot = reducer.accept(menu)

        #expect(shellSnapshot.text == "$ ls\nREADME\n$")
        #expect(shellSnapshot.significantRuns.isEmpty)
        #expect(vimSnapshot.significantRuns == [
            .init(
                row: 2,
                startColumn: 0,
                endColumn: 8,
                style: .inverse
            )
        ])
        #expect(menuSnapshot.significantRuns == [
            .init(
                row: 1,
                startColumn: 0,
                endColumn: 8,
                style: [.inverse, .selected]
            )
        ])
    }

    @Test("fixture loop publishes revisions stability key modes and stale rejection")
    func fixtureLoopPreservesInteractiveContracts() async throws {
        let shell = try fixture(named: "shell")
        let vim = try fixture(named: "vim")
        let loop = FixtureTerminalLoop(initial: shell)

        let shellSnapshot = await loop.observe()
        let duplicate = await loop.publish(shell)
        let vimSnapshot = await loop.publish(vim)

        #expect(shellSnapshot.revision == 1)
        #expect(duplicate.revision == 1)
        #expect(duplicate.changedRows.isEmpty)
        #expect(vimSnapshot.revision == 2)
        #expect(vimSnapshot.changedRows == [0, 1, 2])

        let stable = try await loop.wait(
            .init(
                condition: .stable(after: 1, for: .zero),
                timeout: .seconds(1)
            )
        )
        #expect(!stable.timedOut)
        #expect(stable.snapshot.revision == 2)

        let normalUp = try TerminalInputEncoder.encode(
            events: [.key(.up, modifiers: [])],
            keyboardMode: shellSnapshot.mode.keyboardMode
        )
        let applicationUp = try TerminalInputEncoder.encode(
            events: [.key(.up, modifiers: [])],
            keyboardMode: vimSnapshot.mode.keyboardMode
        )
        #expect(normalUp.elementsEqual([0x1B, 0x5B, 0x41]))
        #expect(applicationUp.elementsEqual([0x1B, 0x4F, 0x41]))

        let staleBatch = TerminalInputBatch(
            expectedRevision: shellSnapshot.revision,
            events: [.text("q")],
            purpose: "leave Vim",
            declaredRisk: .routine
        )
        await #expect(
            throws: FixtureTerminalLoopError.staleRevision(
                expected: 1,
                actual: 2
            )
        ) {
            try await loop.encode(staleBatch)
        }

        let currentBatch = TerminalInputBatch(
            expectedRevision: vimSnapshot.revision,
            events: [.key(.escape, modifiers: []), .text(":q")],
            purpose: "leave Vim",
            declaredRisk: .routine
        )
        let encoded = try await loop.encode(currentBatch)
        #expect(encoded == [0x1B, 0x3A, 0x71])
    }
}

private enum FixtureTerminalLoopError: Error, Equatable {
    case staleRevision(expected: UInt64, actual: UInt64)
}

private actor FixtureTerminalLoop {
    private var reducer: TerminalScreenReducer
    private var snapshot: TerminalScreenSnapshot
    private let channel: TerminalScreenChannel<ContinuousClock>

    init(initial frame: TerminalGridFrame) {
        var reducer = TerminalScreenReducer()
        let snapshot = reducer.accept(frame)
        self.reducer = reducer
        self.snapshot = snapshot
        channel = TerminalScreenChannel(
            initial: snapshot,
            clock: ContinuousClock()
        )
    }

    func observe() -> TerminalScreenSnapshot {
        snapshot
    }

    func publish(_ frame: TerminalGridFrame) async -> TerminalScreenSnapshot {
        let next = reducer.accept(frame)
        snapshot = next
        await channel.publish(next)
        return next
    }

    func wait(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult {
        try await channel.wait(request)
    }

    func encode(_ batch: TerminalInputBatch) throws -> [UInt8] {
        guard batch.expectedRevision == snapshot.revision else {
            throw FixtureTerminalLoopError.staleRevision(
                expected: batch.expectedRevision,
                actual: snapshot.revision
            )
        }
        return try Array(
            TerminalInputEncoder.encode(
                events: batch.events,
                keyboardMode: snapshot.mode.keyboardMode
            )
        )
    }
}
