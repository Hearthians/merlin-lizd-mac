# Task 11 Second Repair Report

Status: `DONE`

Base: `13f5fe2`

Commit: the commit containing this report, with subject
`fix: finalize codex drawer safety`; its final object ID is reported in the
agent handoff because a Git commit cannot contain its own final object ID.

## RED evidence

- Live approval: the focused broker tests first failed to compile because
  `awaitApproval` did not accept independently trusted endpoint, screen, and
  surface evidence. Nil-context and forged endpoint/revision/screen/surface
  cases then defined the fail-closed contract.
- Bounded context: permission tests first failed because approval surface
  context still persisted raw `TmuxSurface` values and the decoder test helpers
  did not exist. New tests require UTF-8 bounds on construction and decoding,
  exact untruncated location identity, and an explicit command truncation flag.
- Auditor: the high-risk pre-action test first failed to compile before
  `appendBeforeSideEffect` accepted trusted surface evidence. It now proves
  that legacy nil context and a forged pane/window are rejected before append.
- Route registration: Core tests first failed to compile before a complete
  route descriptor and route-bound generation existed. They cover rename,
  cosmetic title changes, duplicate tabs, and stale generation/route results.
- Takeover: reducer tests first failed to compile before operation identities
  were carried through request, pending ownership, stop command, and
  completion. Behavioral tests cover Enter while pending, draft preservation,
  repeated stop, selection/session/failure interleavings, and stale completion.

## Design and behavior

### Live approval is separate from legacy decoding

- Historical journal JSON with missing approval context remains decodable, but
  the live broker, router, drawer Allow Once reducer, and high-risk mutation
  auditor all reject missing context.
- The broker recreates the canonical scope from independently supplied live
  endpoint, exact batch, screen snapshot, and verified surface, then requires
  full scope equality. This binds payload digest, endpoint, revision, the
  immutable bounded screen projection, and the exact tmux location.
- Approval context now stores `TerminalApprovalSurfaceContext` instead of raw
  `TmuxSurface`. Session/window/pane values are exact, bounded to 64 UTF-8
  bytes, prefix-checked, and restricted to display-safe opaque identifier
  characters. Command text is bounded to 512 UTF-8 bytes with an explicit
  truncation flag. The screen decoder enforces its 8 KiB UTF-8 bound.
- The approval card renders the bounded command projection and exposes its
  truncation status. Screen truncation remains explicit.
- The mutation auditor recomputes policy using the caller's trusted pre-action
  surface and requires the approval scope to equal a newly canonicalized scope.
  High-risk bundles without trusted surface evidence fail before journal
  append; journal-before-action ordering and strict historical reading remain
  unchanged.

### Endpoint generations are bound to complete routes

- `CodexDrawerEndpointRouteDescriptor` contains target, session name, and
  stable tmux identity. Registration success/failure requires the exact current
  generation and descriptor while readiness is still registering.
- `replaceTerminalTabs` compares per-tab descriptors. Route changes immediately
  cancel the old generation, publish detached/non-connected readiness,
  unregister the old endpoint, and register a replacement against the still
  live `TerminalSession`.
- Async identity resolution and endpoint registration re-check token, session
  object, current tab, and exact route before publishing. A stale endpoint that
  finished registering is explicitly unregistered.
- Cosmetic title-only changes do not restart registration. Duplicate tab IDs
  are evaluated independently even when their conversation identity is shared.

### Takeover is one exclusive operation

- Each admitted takeover carries a UUID through pending ownership, the stop
  command, and completion. Only the matching still-pending UUID restores user
  ownership; stale completions are ignored.
- Pending ownership disables `canSend`, and reducer send/steer actions fail
  without clearing the draft or overwriting ownership. Repeated takeover emits
  no second stop.
- Pending state is stored per conversation and survives selection changes and
  active-to-failed session snapshots until the exact coordinator stop completes.
- The App does not admit takeover when no coordinator exists and never fakes a
  completion for a missing coordinator.

## Changed files

- Core: `CodexDrawerState.swift`, `TerminalApprovalBroker.swift`,
  `TerminalOperationJournal.swift`, `TerminalPermissionPolicy.swift`, and
  `TerminalToolRouter.swift`.
- App: `CodexApprovalCardView.swift`, `CodexDrawerModel.swift`, and
  `TerminalTabsModel.swift`.
- Tests/support: `CodexDrawerStateTests.swift`,
  `TerminalApprovalBrokerTests.swift`, `TerminalOperationJournalTests.swift`,
  `TerminalPermissionPolicyTests.swift`, `TerminalToolRouterTests.swift`,
  `TerminalToolTestSupport.swift`, and this report.

## Verification

- Focused drawer/approval/permission/auditor/router/tab command: 141/141 tests
  in 6 suites passed.
- Router compatibility rerun after widening persisted opaque ID validation:
  68/68 tests passed.
- `./scripts/test.sh`: 713/713 tests in 46 suites passed; no transport flake was
  observed.
- `/usr/bin/swift build`: passed before this report and is rerun after it.
- Cumulative `git diff --check 13f5fe2`, protected-path inspection, staged diff
  check, and final worktree status are performed immediately before commit.
- No `Vendor/`, `Packaging/`, `Assets/`, transport flake, or Task 12 files were
  modified.

## Residual risks

- App route invalidation is covered by pure Core route/generation tests and a
  complete application build. The repository intentionally has no live tmux
  App integration harness for async register/rename timing.
- Display-only command text and visible screen text are bounded projections;
  differences beyond their recorded bounds are not persisted. Exact stable
  session/window/pane identity and screen revision remain untruncated and are
  required for live approval.
