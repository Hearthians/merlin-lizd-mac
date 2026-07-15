# Task 11 Repair Report

Status: `DONE`

Base: `e101d71`

Commit: the commit containing this report, with subject
`fix: close codex drawer review gaps`; its final object ID is reported in the
agent handoff because a Git commit cannot contain its own final object ID.

## RED evidence

- Approval context: the first focused compile failed because
  `TerminalApprovalScope` had no immutable context, policy/router calls had no
  verified surface input, and the drawer could not render exact approval-time
  terminal evidence. The router test was then made behavioral: an input
  approval had to carry the exact endpoint, session/window/pane/current
  command, revision, dimensions, mode/cursor, and bounded screen text, and a
  surface change had to expire without sending input.
- Endpoint readiness: the initial drawer test failed to compile because there
  was no pure readiness projection and the App still treated a known tmux key
  with a missing or unregistered terminal as connected. A later race test also
  failed to compile before the generation-aware endpoint registration reducer
  existed.
- Takeover: the disconnected-active reducer test initially produced no
  `.stopAndTakeOver` command. The async ordering test then failed to compile
  before a command sequencing seam existed.
- Recent journal reading: the first focused compile failed because the journal
  protocol had no storage-bounded page API or traversal cancellation hook.
  After the first implementation, the oversized-record test was behaviorally
  RED because pagination returned no older valid record; the cursor was fixed
  to traverse the oversized record deterministically.

## Design and behavior

### Exact approval-time evidence

- `TerminalApprovalScope` now optionally decodes a protocol-neutral
  `TerminalApprovalContext`. New high-risk input approvals require that context;
  optionality exists only for historical journal decoding.
- The context contains the verified `TmuxSurface` plus a screen projection with
  revision, dimensions, cursor, normal/alternate and keyboard modes, and UTF-8
  text bounded to 8 KiB without splitting a scalar.
- Input routing reads surface, reads screen, then reads surface again. Surface
  drift during this observation window fails closed. The same exact surface is
  passed to policy preparation and is checked again after approval, so route or
  pane/window changes use the existing expiry path and never emit the batch.
- The broker verifies canonical payload digest and revision linkage. The
  mutation auditor recomputes policy against the recorded screen and validates
  new context against that exact screen. Historical nil-context journal events
  remain auditable, but the drawer reducer and UI cannot Allow Once without new
  verified context; Deny remains available.
- Approval cards now show exact endpoint, tmux session/window/pane/current
  command, screen revision/dimensions/cursor/modes/text, purpose, reason,
  proposed input, and digest. All free-form rendered details are bounded.

### Fail-closed endpoint readiness

- Drawer terminal context now distinguishes not-started, registering,
  registration-failed, detached, exited, closed, reconnecting, disconnected,
  and connected states with distinct notices.
- A pure Core projection returns `.connected` only for a present idle/running
  terminal plus a successfully registered endpoint. Known tmux identity alone
  is insufficient.
- `CodexDrawerEndpointRegistration` owns a generation UUID. Only the exact
  current generation can publish registration success or failure; detach and
  preparation failure clear it, preventing late tasks from reviving a stale
  route.
- `TerminalTabsModel` refreshes after registration begin/success/failure,
  detach, terminal exit/close, reconnect, identity changes, and selection. A
  late successful registration is explicitly unregistered when its token,
  session, or reducer generation is no longer current.

### Takeover without a live terminal

- An active selected conversation can request takeover from every terminal
  context that still carries its exact key, including disconnected/detached
  states. Connection is still required for new send/steer input.
- The reducer emits one stop command, changes ownership to
  `takeoverPending`, and ignores repeats. The visible button uses the same
  executable predicate and is disabled when the coordinator is absent.
- The App awaits `coordinator.stopAndTakeOver` through a testable Core
  sequencing seam and delivers `.takeoverCompleted` only after that await
  returns. Session failure alone does not prematurely restore ownership.

### Storage-bounded recent journal projection

- `recentEntries` accepts explicit event and byte caps plus an opaque older
  cursor. Requests clamp to 400 events and 1 MiB; the drawer requests at most
  400 events and 256 KiB.
- The file-backed implementation uses `fstat` and bounded reverse `pread`
  under the existing conversation/file locks. It checks cancellation before
  and after each physical read and never reads more journal bytes than the
  requested cap.
- Only complete JSONL records in the bounded window are decoded. Intentional
  partial boundaries are not classified as corruption. A record larger than a
  page yields an explicit omission flag and deterministic skip cursor, which
  can continue to older valid records without changing the complete audit
  file or weakening the strict full-journal reader.
- The drawer no longer loads the full audit before taking a suffix. It groups
  the bounded page, caps rendered screen/payload/failure text per item, and
  shows the older/oversized-history cue independently even when the visible
  page contains no decodable item.

## Changed files

- Core approval/routing:
  `TerminalPermissionPolicy.swift`, `TerminalApprovalBroker.swift`,
  `TerminalToolRouter.swift`, `TerminalScreen.swift`, and `TmuxSurface.swift`.
- Core drawer/journal:
  `CodexDrawerState.swift` and `TerminalOperationJournal.swift`.
- App projection/UI:
  `TerminalTabsModel.swift`, `CodexDrawerModel.swift`,
  `CodexDrawerView.swift`, `CodexApprovalCardView.swift`, and
  `CodexOperationView.swift`.
- Tests/support:
  `CodexDrawerStateTests.swift`, `TerminalOperationJournalTests.swift`,
  `TerminalPermissionPolicyTests.swift`, `TerminalToolRouterTests.swift`,
  `CodexSessionTestSupport.swift`, `TerminalPersistenceSupport.swift`,
  `TerminalToolTestSupport.swift`, and this report.

## Verification

- Focused permission/router/journal/drawer/approval run: 131/131 tests in 5
  suites passed.
- `/usr/bin/swift build`: passed before the final report and is rerun after it.
- `./scripts/test.sh`: final run passed 705/705 tests in 46 suites.
- During verification, two earlier full parallel runs exposed an existing
  observation race in
  `JSONLAppServerTransportTests.runningTransportOwnerLossCleansUp`: process
  terminate/wait counts were complete before the test immediately sampled the
  event-consumer continuation. The unchanged transport suite passed 62/62 in
  isolation, no Task 11 file touches that implementation/test, and the final
  unmodified full run passed 705/705. No out-of-scope fix was made.
- Final `git diff --check e101d71`, staged diff check, scope inspection, and
  worktree status are performed immediately before commit.
- No `Vendor/`, `Packaging/`, `Assets/`, or Task 12 files changed.

## Residual risks

- Historical approval records without immutable context remain decodable for
  audit compatibility, but they deliberately cannot be approved from the new
  drawer. Users may only deny such a pending legacy request.
- The drawer projects one bounded recent page and clearly indicates omitted
  older/oversized history; it does not yet expose interactive page navigation.
  The cursor API is available for a later UI without changing storage rules.
- App-level `TerminalSession` registration is validated by the pure Core
  projection/generation reducer tests plus a complete application build. The
  repository has no live tmux/SSH App integration harness, by design.
