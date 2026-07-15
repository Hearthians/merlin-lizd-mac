# Task 11 Implementation Report

## Status and commit

Status: implemented and verified.

Commit: the commit containing this report, with subject
`feat: add tmux codex drawer`. Its final object ID is reported in the agent
handoff because a Git commit cannot contain its own final object ID.

Starting commit: `f9197f9`.

## RED evidence

- The first required focused invocation,
  `/usr/bin/swift run MerlinLizdCoreTests --filter 'Codex drawer state'`,
  exited 1 before production work. It reported the intended missing
  `CodexDrawerState`, `CodexDrawerBadge`, reducer actions, and projections.
  This run also exposed that importing Foundation directly in this repository's
  custom Swift Testing executable masks the Testing macros; the test harness
  import was corrected before GREEN.
- A follow-up RED for background aggregation failed because
  `CodexDrawerBackgroundActivity` and `backgroundActivity(excluding:)` did not
  exist.
- A focused Supervisor RED failed with
  `CodexAppServerSupervisor has no member retryAvailability`, proving the Retry
  button could not be implemented by merely resubscribing to availability.

Swift Testing 1501 filters by suite symbol rather than the display title. The
plan's literal display-title filter now exits 69 after running zero tests. The
effective focused command is
`/usr/bin/swift run MerlinLizdCoreTests --filter CodexDrawerStateTests`; it runs
the intended suite and is included in GREEN below.

## Design and behavior

- `CodexDrawerState` is a pure reducer. It owns per-conversation drafts,
  collapsed/compact/expanded layout, the 20...50 percent clamp, command
  enablement, takeover-pending sequencing, sanitized availability notices,
  per-key badges, and background activity aggregation.
- `.thinking` counts as active even before `activeTurnID` is confirmed. This
  keeps the drawer compact and makes Stop and Take Over available while the
  coordinator is still in its cancellable pending-start path.
- Plain local shells, unresolved tmux identities, and disconnected sessions
  have explicit contexts. Submit/steer/takeover are fail-closed outside a
  connected context. Disconnected approvals disable Allow Once in both reducer
  and View while Deny remains available.
- A single process-wide `CodexDrawerModel` is constructed as a `StateObject` in
  `MerlinLizdApplication`. It subscribes to coordinator snapshots and
  availability once; drafts and histories are selected by
  `TerminalConversationKey`, never tab ID.
- Stop and Take Over calls only `CodexSessionCoordinator.stopAndTakeOver` and
  marks takeover complete only after that async method returns. It emits no key,
  terminal close, or process/tmux termination action.
- Retry calls a new explicit adapter-boundary method. The Supervisor first joins
  terminal-generation cleanup, clears its terminal availability latch, and
  performs a new handshake. The Core reducer remains independent of the
  app-server implementation.
- `TerminalOperationJournalReading` narrows the drawer's runtime capability to
  read-only journal access. Expanded operation rows are summaries whose
  `DisclosureGroup` reveals journal details; approval cards show exact semantic
  input, reason, endpoint/tmux surface, screen revision/context, and digest.
- Every already-open terminal remains hosted in the workspace ZStack when its
  tab is in the background, so PTY rendering continues. Restored tabs that were
  never opened are not eagerly connected. Drawer resizing does not reconstruct
  a `TerminalSessionHost`.
- Tab badges resolve through the stable conversation key, so duplicate tabs for
  one tmux session share state while independent sessions keep independent
  phases. The drawer handle also summarizes other running/approval
  conversations without counting the foreground key.
- Notification code and approval behavior from Task 10 were not changed.

## Files changed

Planned files:

- `Sources/MerlinLizdCore/CodexDrawerState.swift`
- `Tests/MerlinLizdCoreTests/CodexDrawerStateTests.swift`
- `Sources/MerlinLizdApp/CodexDrawerModel.swift`
- `Sources/MerlinLizdApp/CodexDrawerView.swift`
- `Sources/MerlinLizdApp/CodexApprovalCardView.swift`
- `Sources/MerlinLizdApp/CodexOperationView.swift`
- `Sources/MerlinLizdApp/TerminalWorkspaceView.swift`
- `Sources/MerlinLizdApp/MerlinRootView.swift`

Required wiring/boundary additions:

- `Sources/MerlinLizdApp/MerlinLizdApplication.swift`: owns the one shared
  drawer model.
- `Sources/MerlinLizdApp/TerminalTabsModel.swift`: publishes the smallest
  protocol-neutral selected terminal context and preserves hosted background
  sessions without eager reconnects.
- `Sources/MerlinLizdApp/CodexRuntime.swift`: exposes only the read-only journal
  capability.
- `Sources/MerlinLizdCore/TerminalOperationJournal.swift`: splits the existing
  journal protocol into read-only and mutation capabilities.
- `Sources/MerlinLizdCodexAdapter/CodexAppServerSupervisor.swift` and its test:
  implement the explicit, real availability retry at the replaceable adapter
  boundary.

No Vendor, Packaging, Assets, notification, terminal-input, or tmux process
lifecycle code changed.

## GREEN and verification

- Drawer focused suite: 8 tests in 1 suite passed.
- Explicit Supervisor Retry: 1 focused test passed.
- `./scripts/test.sh`: final run passed 697 tests in 46 suites.
- `/usr/bin/swift build`: passed with all package targets under Swift 6.
- `git diff --check`: passed before staging; the staged/cumulative check is run
  immediately before commit.

One intermediate full-suite run saw an existing timing-sensitive
`app-server transport` failure. The isolated suite then passed 62/62 and the
next complete run passed 697/697. Task 11 does not change that transport.

## Residual concerns

- SwiftUI layout, resizing, and terminal focus still need the disposable-tmux
  manual smoke pass deliberately scheduled in Task 12.
- The current approval domain scope contains the exact endpoint, tmux
  conversation identity, screen revision, semantic input, purpose, reason, and
  digest; it does not retain a separate window/pane snapshot in the approval
  value. The full observed screen and pane lifecycle remain available in the
  operation journal.
