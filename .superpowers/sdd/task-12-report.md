# Task 12 Implementation Report

## Status and scope

Status: implemented, manually smoked, packaged, repaired after review, and
verified with the isolated transport-flake caveat documented below.

Starting commit: `6dd2afc`.

The original Task 12 commit is `931389b` (`test: verify tmux codex workflow`).
The follow-up repair commit is reported in the final handoff because a Git
commit cannot contain its own final object ID.

The planned acceptance tests, concurrency regression, README, and specification
were completed. During real-app smoke, four production defects blocked the
required workflow. Their narrowly scoped fixes were reported and explicitly
authorized before inclusion:

- a SwiftPM executable crashed before UI smoke when it constructed the macOS
  notification center outside an `.app` bundle;
- the drawer subscribed to availability but never initiated its first
  app-server probe;
- a thread created in the current app-server generation was immediately sent a
  redundant `thread/resume`, which Codex 0.144.2 rejected;
- SwiftTerm's acknowledged PTY overload opened a second `DispatchIO` writer for
  a descriptor already owned by its stream channel, stranding the completion.

The SwiftTerm fix is limited to the documented local patch surface. It uses the
existing channel, requires a complete/done write, reports `EPIPE`/`EIO`, guards
completion at most once, and returns on `LocalProcess`'s callback queue.

This follows Apple's primary `DispatchIO` contract. Apple explicitly says that
when a file descriptor is already used by another channel, callers should use
the channel's `write(offset:data:queue:ioHandler:)` rather than the static
file-descriptor convenience method. The channel handler may be invoked more
than once; `done == false` is partial progress, `done == true` is terminal,
the data argument is the remaining data, and `error == 0` is success. See
[Apple: write to an existing DispatchIO channel](https://developer.apple.com/documentation/dispatch/dispatchio/write%28offset%3Adata%3Aqueue%3Aiohandler%3A%29)
and
[Apple: write to a file descriptor](https://developer.apple.com/documentation/dispatch/dispatchio/2300085-write?changes=_4___1).

## RED and GREEN evidence

- Review found that the first acceptance harness bypassed the coordinator with
  `router.beginTurn`, used an in-memory journal for behaviors 1-7, and manually
  forged the duplicate-tab transcript and approval. The repaired harness is
  GREEN only after `CodexSessionCoordinator.submit` establishes each real turn
  and pin, and router calls use the coordinator-owned thread/turn identity. All
  ten behaviors now share the production coordinator, endpoint registry,
  router, default permission policy, `FileCodexConversationStore`, and
  `FileTerminalOperationJournal`, with only the agent, PTY, and surface ports
  faked. Duplicate-tab messages and approval come through real agent/coordinator
  streams. The crash behavior drives an actual scripted supervisor generation
  crash plus endpoint disconnect, and asserts no replay, terminal bytes, or
  surface mutation. The ten behaviors pass without launching Merlin, SSH,
  tmux, Codex, OpenAI, or network processes.
- The first late-resume test hung because it started and resumed the same
  current-generation thread, correctly taking the production idempotent fast
  path before the scripted resume gate. GREEN uses three generations: the
  bootstrap generation creates an active durable mapping, its crash leaves the
  thread unloaded in generation two, generation two gates a real resume and
  crashes, and generation three resumes the exact durable thread. The old
  completion is rejected. A bounded bootstrap-shutdown signal proves the
  supervisor has detached generation one before the public resume begins, so
  the scenario cannot race into the current-generation idempotent fast path.
  The three relevant scripted waits have cancellation-aware one-second bounds
  so an impossible scenario fails instead of hanging CI; production resume
  logic is unchanged. The exact regression passed 25 consecutive runs after
  this synchronization was added.
- The crash-recovery regression now waits for the supervisor's bounded
  `.ready` publication instead of treating entry into the replacement
  generation's `resumeThread` as recovery completion.
- The lifecycle stress regression began RED before its deterministic
  publication/wait/interrupt harness existed. GREEN drives 24 exact keys:
  8 stable waits complete, 16 are interrupted, no waiter continuation remains,
  no action crosses keys, and every pin is released.
- `/usr/bin/swift run MerlinLizd` initially exited 134 while constructing
  `UNUserNotificationCenter.current()` from a non-`.app` SwiftPM product.
  GREEN selects a no-op notification delivery for that launch form while the
  packaged `.app` still selects system delivery.
- The packaged drawer initially stayed at **Starting** indefinitely. GREEN
  installs the availability stream first and then starts one initial
  `retryAvailability()` probe; the real drawer reached ready.
- The first real prompt initially failed with remote error `-32600` after a
  newly started thread was redundantly resumed. A focused supervisor test is
  RED/GREEN evidence that resuming a thread started in the current generation
  is idempotent; the real first turn then completed.
- The original acknowledged `sendInput` smoke visibly emitted the fixed jobs
  marker but never produced a receipt/result. Replacing the static writer with
  the existing SwiftTerm stream channel unblocked the receipt. The first
  channel-only patch then exposed a `_dispatch_assert_queue_fail` / MainActor
  SIGTRAP because completion ran on the libdispatch I/O queue. Delivering the
  at-most-once result on `LocalProcess.dispatchQueue` fixed that second RED.
  Final manual GREEN recorded `{acceptedRevision: 15, byteCount: 21}` and
  visibly printed `ACK-GREEN` without crashing the app.

## Acceptance invariant map

| Required invariant | Cross-layer behavior |
| --- | --- |
| Shell observe, input acknowledgement, stable screen | `shellObserveInputAcknowledgementAndStableScreen` |
| Alternate-screen semantic navigation and stale re-observe | `alternateScreenNavigationRequiresFreshRevision` |
| Background destructive approval expires after route drift | `destructiveApprovalExpiresAfterRouteChange` |
| Fixed jobs probe safely closes and restores | `temporaryPaneClosesAfterVisibleIdleProof` |
| Jobs/uncertainty retains typed provenance | `temporaryPaneJobsRetainTypedReport` |
| Different conversations overlap; one key serializes | `conversationsOverlapButOneKeySerializes` |
| Duplicate tabs share state and one pin | `duplicateTabsShareConversationAndOnePin` |
| Pinned tab close interrupts with zero terminal control bytes | `pinnedTabCloseInterruptsWithoutControlBytes` |
| Transport crash is contained to the owning key without replay | `crashContainsFailureToOwningConversation` |
| Store/journal reopen, archive, and confirmed deletion | `persistenceReopenArchiveAndConfirmedDelete` |

## Containment audit

The final source audit used these commands:

```bash
rg -n 'capture-pane|capturePane|OPENAI_API_KEY|apiKey|APIKey' Sources
rg -n 'Dynamic Tool|dynamicTool|experimental_api' Sources
rg -n 'sendAgentBytes|process\.send|sendInput' Sources/MerlinLizdApp
rg -n 'struct TerminalConversationKey|let tmux:|var tmux:' Sources/MerlinLizdCore
rg -n 'Control-C|controlC|kill-pane|kill-session|terminateSession|closeTerminal|sendAgentBytes|sendInput' \
  Sources/MerlinLizdCore/CodexSessionCoordinator.swift \
  Sources/MerlinLizdApp/CodexDrawerModel.swift \
  Sources/MerlinLizdCodexAdapter/CodexAppServerSupervisor.swift
rg -n 'capture-pane|capturePane|hiddenPane|HiddenPane|arbitrary shell|OPENAI_API_KEY|apiKey|APIKey|remote filesystem|mount' Sources
```

Results and classification:

- Dynamic Tool wire/schema occurrences are confined to
  `CodexLaunchConfiguration.swift`, `CodexDynamicTools.swift`, and
  `CodexAppServerAdapter.swift`. Core permissions, tools, routes, journals, and
  terminal domain values contain no app-server Dynamic Tool names.
- Agent PTY bytes have one App path:
  `SwiftTermTerminalDriver.sendInput` ->
  `AgentTerminalView.sendAgentBytes` -> `LocalProcess.send`.
- `TerminalConversationKey.tmux` is a non-optional `TmuxSessionIdentity`.
- No source occurrence introduced `capture-pane`, a hidden-pane reader, an
  arbitrary shell/file API, an API-key field, or a remote filesystem mount.
- Stop/takeover paths in the coordinator, drawer model, and supervisor contain
  no Control-C/input emission, kill-pane/session, or terminal close operation.
  User-confirmed tmux session termination elsewhere in the app is a separate
  pre-existing lifecycle feature and not a Codex stop path.
- Complete numbered inspection of `TerminalToolRouter.swift` confirmed every
  mutation verifies the rendered revision before `prepareMutation`. That
  preparation authorizes the exact turn, durably appends request/screen/risk,
  evaluates deterministic permission, waits for and consumes exact approval
  where required, rechecks route/screen, and durably appends endpoint plus
  emitted batch before calling a terminal or surface port. The concrete side
  effects remain after preparation at send line 1131, select line 1189, create
  line 1260, and finish-probe send line 1714.

## Native manual smoke

All smoke sessions used names beginning
`merlin-lizd-codex-smoke-20260716-task12` and were disposable local tmux
sessions. No valuable session or remote process was targeted.

Observed behavior:

- The drawer rendered its idle, active compact, and expanded terminal-preserving
  layouts; composer text, running state, approval state, and scrollable history
  remained usable.
- A plain-shell prompt completed through the real bundled Codex 0.144.2
  app-server using the existing local login/model configuration.
- Renaming the tmux session preserved stable identity and transcript.
- Two sessions ran independently; the background tab exposed running/approval
  badges while changing tabs did not cancel either task.
- Exact **Allow Once**, **Deny**, approval expiry, and **Stop and Take Over**
  were exercised. Takeover returned keyboard ownership without Control-C,
  pane/session kill, or remote process interruption.
- A direct acknowledged write succeeded end to end. Journal operation
  `23DA7781-5710-4479-AB2D-669D79CC2A86` recorded
  request -> screen -> risk -> approvedOnce -> endpoint -> emittedBatch ->
  result success with revision 15 and 21 bytes. The following visible screen
  contained `ACK-GREEN`.
- Idle close/restore succeeded on a fresh identity `$4@1784158684`. The first
  finish attempt retained fail-closed after layout revision drift. After
  re-observation, the exact fixed jobs probe was approved, acknowledged with
  revision 8 and 60 bytes, the journal recorded `temporaryPane.closed` with
  `restoration.restored`, and tmux contained only origin pane `%6`, active.
- `status off` was scoped only to that final disposable session to keep the
  tmux status clock from invalidating an exact approval. Earlier clock-induced
  revision changes correctly expired approval before any input was sent. This
  is an operational consequence of the strict stale-screen guard, not a reason
  to weaken it.

Honest limitations:

- A full Vim/menu navigation sequence was not independently exercised in the
  native smoke. Scripted SwiftTerm fixtures and the alternate-screen acceptance
  behavior cover its semantic input/stale-revision contract.
- The system notification banner was not independently asserted; the native UI
  approval badge/card and ownership behavior were observed.
- Unsupported-version UI could not be induced safely because the bundled
  supported Codex 0.144.2 resolver won. Typed availability/retry states remain
  covered by automated tests.
- Copy/selection behavior was not exhaustively audited by accessibility
  automation; keyboard ownership and takeover were behaviorally observed.

Cleanup is complete: the worktree app process is stopped and every exact
Task-12 disposable tmux session is removed. The user's pre-existing app process
at PID 68250 was not touched. Manual smoke created owner-only conversation
mapping/journal history under Application Support; it is intentionally left as
non-running test history because no safe exact deletion API was authorized.
No GUI Delete Conversation action or broad Application Support deletion was
performed.

## Documentation and packaging

- README now states shipped implementation, the exact supported range
  `>= 0.144.2 && < 0.145.0`, local auth/model reuse with no API key, owner-only
  Application Support paths and journal sensitivity, archive versus confirmed
  delete, availability/retry states, and troubleshooting.
- `Docs/SPEC.md` now defines stable conversation identity, active visible pane,
  drawer/lease vocabulary, background-session behavior, approvals, journaling,
  takeover, and failure containment.
- Stale `MerlinHub` product wording was corrected to the repository's actual
  `Merlin Lizd` / `MerlinLizd` names. The package and bundle were not renamed.
- The adapter adds no resources, so `scripts/package-app.sh` remains unchanged.
  It produced `dist/Merlin Lizd.app`; strict deep signature verification passed.

## Final verification

- Focused suites were run individually with the equivalent filters because
  concurrent SwiftPM invocations serialize on `.build`: acceptance 10/10,
  concurrency 11/11, and supervisor 28/28, for 49/49 affected tests.
- `./scripts/test.sh` listed 726 tests in 47 suites. Full run #1 and full run #2
  each passed the 725 tests outside the known unrelated
  `continuousDescendantOutputHasAbsoluteDeadline` transport fixture. The first
  run failed only its descriptor-delta assertion (`7`, expected `<= 2`); the
  second reported `timedOut` and three issues within that fixture and its
  cleanup assertions. The exact test was then isolated with
  `/usr/bin/swift run MerlinLizdCoreTests --filter 'MerlinLizdCoreTests.JSONLAppServerTransportTests/continuousDescendantOutputHasAbsoluteDeadline'`
  and passed 1/1 in 0.078 seconds. Per the review constraint, the unrelated
  timing test was not edited. A third fresh `./scripts/test.sh` run then passed
  all 726 tests in 47 suites in 2.891 seconds.
- `/usr/bin/swift build` — passed under Swift 6.
- `./scripts/package-app.sh` — passed and produced the real app bundle.
- `/usr/bin/codesign --verify --deep --strict 'dist/Merlin Lizd.app'` — passed.
- `git diff --check` — passed before staging. The cumulative
  `git diff --check 6dd2afc..HEAD` is run immediately after the final commit and
  reported in the handoff.

The known unrelated transport timing fixture fluctuated in full runs #1 and
#2 as reported above; the isolated rerun and final full run were green.

## Protected-path review

The cumulative Task 12 range contains only the planned
acceptance/concurrency/docs/report paths plus the four explicitly authorized
production closures and the two-file documented SwiftTerm patch. The repair
commit itself changes only this report, the acceptance test, the supervisor
test, and its test-support file.

The cumulative authorized closure paths are:

- `Sources/MerlinLizdApp/CodexDrawerModel.swift`
- `Sources/MerlinLizdApp/CodexNotificationController.swift`
- `Sources/MerlinLizdCodexAdapter/CodexAppServerSupervisor.swift`
- `Tests/MerlinLizdCoreTests/CodexAppServerSupervisorTests.swift`
- `Vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift`
- `Vendor/SwiftTerm/MERLINHUB_PATCHES.md`

No other production Core file, adapter transport file, package manifest,
packaging script, asset, plist, unrelated test, or unrelated Vendor file was
modified.
