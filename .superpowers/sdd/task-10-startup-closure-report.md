# Task 10 startup closure report

Base: `d90fe58494fb98ed332da3f53d9522b1191e2fdf`

## Outcome

The shared app-server startup wait is now independently cancellable per
caller. Coordinator shutdown can cancel and join its pending start, reach the
supervisor, cancel the supervisor-owned startup task, and complete without
releasing normal startup. The change is confined to the Codex adapter and its
Core test coverage; no App, Vendor, Packaging, or Assets files changed.

## RED evidence

1. `cancellingStartupCallerOnlyRemovesItsWaiter` failed in 0.201 seconds at
   `cancelledReturnedBeforeStartup`: a canceled caller remained suspended on
   the shared `StartupOperation.task.value`.
2. `shutdownCancelsPendingSupervisorStartup` failed in 0.208 seconds at
   `completedThroughSupervisorCancellation`: coordinator shutdown was stuck
   joining its pending start and never reached supervisor shutdown.
3. The follow-up failure fan-out test failed at
   `factory.creationCount == 1`: the first completed waiter removed operation
   identity before the second waiter consumed the same failure, allowing an
   unintended second factory admission.

Each failure was observed before its corresponding production change. RED
cleanup released or canceled the gated startup only after recording the
expected failure, so the tests did not hang.

## Startup waiter ownership and races

- `StartupOperation` owns an operation UUID, its shared task, an explicit
  success/failure completion, and exact waiter UUID continuations.
- A caller checks cancellation before registration. Registration atomically
  verifies caller cancellation, operation identity, and incomplete state.
  Cancellation removes and resumes only that caller's waiter; it never cancels
  the shared startup task.
- The startup task reports success or failure back to the actor. Completion is
  retained before all current waiters are removed and resumed once, so a late
  registration observes the explicit completed state instead of stranding.
- After every startup wake, `readyGeneration` checks caller cancellation,
  supervisor stop state, and operation identity before reading the completion.
  A peer-installed generation is reused; a peer-consumed failure is returned
  as unavailable rather than admitting a replacement startup for an old
  waiter.
- Shutdown detaches the operation and clears its waiter metadata before waking
  callers, then cancels and joins the detached shared task. A client produced
  despite cancellation is shut down before supervisor cleanup finishes.

## Coordinator shutdown result

The real coordinator-plus-supervisor test gates the generation factory with a
cancellation-aware continuation. It starts a coordinator submit, invokes
coordinator shutdown while startup is pending, and completes through explicit
supervisor startup cancellation in 0.005-0.009 seconds without opening the
normal startup gate. The factory observes cancellation, no generation is
installed, and supervisor availability becomes `.stopped`.

## Verification

- `CodexAppServerSupervisorTests`: 26 tests passed.
- `CodexSessionCoordinatorTests`: 71 tests in 2 matched suites passed.
- `CodexAppLifecycleSupportTests`: 4 tests passed.
- `CodexAppServerContractTests`: 76 tests passed.
- `./scripts/test.sh`: 688 tests in 45 suites passed.
- `/usr/bin/swift build`: passed; `Build complete! (0.10s)` on the final run.
- `git diff --check`: exited 0.
- Scope audit: one adapter production file, three test files, and this report;
  no App, Vendor, Packaging, or Assets changes.

## Commit and concerns

Commit: `fix: make codex startup waits cancellable`

The shared startup intentionally continues when its last caller is canceled;
this preserves single-flight ownership for a later caller. Supervisor shutdown
is the boundary that cancels and reaps that owned work. No additional concern
was found within the Task 10 startup-closure scope.
