# SSH Connection Reuse and tmux Prewarming Design

Status: approved for implementation planning
Date: 2026-07-12

## Context

Merlin Lizd currently starts a new local `ssh` process for each Devbox or
Worker operation. The user's SSH aliases have `ControlMaster false` and
`ControlPersist no`, so these processes do not share a transport. Worker
operations also start a fresh `mlx worker login` for every readiness probe,
tmux query, mutation, metrics stream, and terminal.

Measured on `hl_gpu_2` and Worker `3966762`:

- Devbox SSH plus `true`: about 1.6 seconds.
- Devbox SSH plus `tmux list-sessions`: about 1.4 seconds.
- Devbox SSH plus `mlx worker login ... -- true`: about 12.7 seconds.
- A second, immediately following Worker tmux query: about 12.4 seconds.

The second measurement shows that one disposable Worker login does not warm
the next operation. The first phase therefore combines two techniques:

1. an App-owned OpenSSH master for every running Devbox; and
2. read-only Worker/tmux prewarming whose results are served from a
   stale-while-revalidate cache.

This phase does not add a persistent Worker agent. It improves Devbox
operations directly and hides the first Worker query behind App startup, but
it does not make the first Worker terminal attach instantaneous.

## Goals

- Begin prewarming automatically when the App opens.
- Reuse one OpenSSH transport per running Devbox without editing
  `~/.ssh/config`.
- Prewarm every current Worker while prioritizing the selected and most
  recently used targets.
- Make the tmux session browser render immediately when a cached snapshot is
  available.
- Combine Worker readiness and tmux discovery into one `mlx worker login`
  during prewarming.
- Route App-owned read, mutation, metrics, and terminal SSH processes through
  the same Devbox master.
- Keep all prewarming read-only and guarantee that it never creates, attaches,
  renames, or terminates a tmux session.
- Close or drain App-owned SSH masters on shutdown without terminating remote
  tmux sessions.

## Non-goals

- A persistent agent or server on a Devbox or Worker.
- Multiplexing multiple Worker commands or PTYs over one `mlx worker login`.
- Eliminating the approximately 12-second first Worker terminal attach.
- Editing the user's global SSH configuration.
- Persisting the complete remote tmux inventory across App launches.
- Changing Worker lifecycle, creation, or termination behavior.

## Approaches considered

### Cache-only prefetch

Run the existing tmux queries at startup and cache their results. This makes a
later browser open quickly, but every refresh still pays for a new Devbox SSH
connection. It hides latency without removing repeated work and is rejected.

### Modify `~/.ssh/config`

Add `ControlMaster`, `ControlPath`, and `ControlPersist` to the user's aliases.
This would also benefit tools outside Merlin Lizd, but it changes global user
behavior, creates ownership and cleanup ambiguity, and is difficult to test in
isolation. It is rejected.

### App-owned SSH master and prewarming coordinator

Merlin Lizd owns short, private control-socket paths and explicitly supplies
multiplexing options to every App-created SSH command. A coordinator prewarms
Devboxes and Workers, records session snapshots, and refreshes them in the
background. This is the selected approach.

## Architecture

### `SSHMasterPool` module

`SSHMasterPool` is the seam between App features and OpenSSH connection
lifecycle. Callers do not know control-socket paths, master startup commands,
single-flight rules, stale-socket recovery, or shutdown control commands.

Its interface provides four behaviors:

```text
prepare(validated aliases, priority) -> per-alias link states
run(validated SSH request) -> bounded process output
interactiveCommand(validated SSH request) -> CommandSpec
shutdown() -> completion after masters stop accepting new channels
```

The interface accepts validated aliases and typed request policies. UI code
does not submit arbitrary shell strings. Existing typed Merlin/tmux command
builders remain responsible for producing fixed remote operations.

The implementation:

- creates one master per alias with system `/usr/bin/ssh`;
- uses `ControlMaster=auto`, an App-owned `ControlPath`, and a ten-minute
  `ControlPersist` safety timeout;
- coalesces concurrent attempts for the same alias into one startup;
- gives foreground user requests priority over background prewarming;
- supports noninteractive, streaming, and interactive child commands through
  the same socket;
- checks and removes an abandoned socket before starting a replacement;
- never logs expanded `ssh -G` output, ProxyCommand values, or credentials.

Control sockets live in a short user-private temporary directory with mode
`0700`. Socket names are hashes rather than raw aliases. A ten-minute persist
timeout ensures masters eventually disappear after an App crash.

On normal App termination, the pool sends OpenSSH's graceful `stop` control
operation. Existing channels may drain, but the master accepts no new
channels. This avoids disconnecting a Terminal.app window launched by Merlin
Lizd while still allowing the master to disappear when its last channel ends.

### `TargetWarmupCoordinator` module

`TargetWarmupCoordinator` owns scheduling rather than transport details. Its
small interface accepts the latest safe inventory snapshot plus a reason such
as App launch, inventory change, manual refresh, cache expiry, or foreground
selection.

At App launch it performs the following flow without delaying the first UI
frame:

1. Read the existing safe Devbox snapshot.
2. Ask `SSHMasterPool` to prepare all cached running aliases.
3. Refresh platform inventory normally.
4. Reconcile running aliases and prepare newly discovered Devboxes.
5. When Worker inventory arrives, enqueue every Worker for read-only warmup.
6. Prioritize the selected target, open tabs, and most recently used targets.
7. Run at most two Worker warmups concurrently.

A Worker warmup uses one fixed command that both proves readiness and lists
tmux sessions. `tmux` exit evidence for "no server" or "no sessions" is treated
as a ready Worker with an empty session list. A Worker-not-ready diagnostic is
stored as readiness evidence, not as an empty authoritative inventory.

Repeated inventory ticks do not restart a warmup. Work is single-flight by
target and generation. A removed or replaced Worker cancels its queued work.

### Session snapshot cache

The existing tmux discovery cache evolves into a snapshot model containing:

- target identity;
- session names;
- readiness evidence;
- fetch timestamp;
- verification state; and
- the last target-scoped error.

Snapshots remain in memory. Restored terminal tabs still provide their known
session names, but Merlin Lizd does not persist all non-App remote session
names to disk.

Freshness behavior:

- Up to 60 seconds: fresh; opening the browser causes no network request.
- Older than 60 seconds: immediately display the snapshot and verify it in the
  background.
- Every five minutes while the App remains active: enqueue a bounded refresh.
- A snapshot never becomes invisible solely because it is old; it remains
  last-known evidence with its timestamp and a stale indicator.

Successful rename and termination operations update the cached snapshot only
after the remote operation is authoritative. Failed or ambiguous mutations do
not optimistically alter the cache.

## Data flows

### Opening the tmux session browser

1. Read the current snapshot synchronously from the in-memory store.
2. Merge known sessions from restored/open terminal tabs.
3. Render immediately.
4. If stale, request a background verification without blocking the sheet.
5. Replace the list only when a newer authoritative response arrives.

### Opening a terminal

The terminal still launches its own `/usr/bin/ssh` child so SwiftTerm owns a
real PTY. That child uses the prepared control socket, eliminating the Devbox
handshake. For a Worker, `mlx worker login` still runs and remains the dominant
first-attach cost in this phase.

Closing a terminal tab disconnects its local channel and leaves tmux running.
The existing explicit "terminate session" operation remains the only path that
kills tmux.

### Read and mutation commands

Read-only commands may recover once from a dead master by invalidating the
socket, recreating the master, and retrying. Mutations are never automatically
replayed because transport loss can make their outcome ambiguous. The caller
must verify remote state before offering another attempt.

### App shutdown

1. Cancel queued background warmups.
2. Cancel active read-only warmups and wait for local process cleanup.
3. Stop accepting new SSH channels.
4. Gracefully stop each master.
5. Remove sockets only after OpenSSH confirms they are no longer live.

No shutdown step sends a tmux command.

## UI behavior

- App startup and inventory remain responsive; prewarming never blocks the
  machine tree.
- Prewarming and failures are target-scoped. They do not produce a global
  modal or global error banner.
- The session browser shows the cached timestamp and whether background
  verification is active.
- A stale snapshot stays usable when verification fails, with a concise
  target-level warning.
- Manual refresh raises the target's priority but still respects single-flight
  and concurrency limits.

## Error handling and safety

- All background connections use `BatchMode=yes`; prewarming cannot display a
  hidden password or confirmation prompt.
- Aliases, Worker IDs, and tmux names pass existing validators.
- Control sockets are user-private and do not listen on a TCP port.
- The App does not store keys, Merlin tokens, ProxyCommand expansions, or
  complete remote tmux inventories.
- Prewarming commands are fixed and read-only.
- A failed Devbox master does not block platform inventory or unrelated
  targets.
- Backoff is per target. Foreground requests can bypass a background delay but
  cannot create a second concurrent warmup for the same target.

## Testing

Automated tests cover the module interfaces rather than private OpenSSH
implementation details:

- concurrent preparation of one alias starts one master;
- different aliases respect the configured concurrency bound;
- every App-created SSH mode receives the same control socket;
- a stale socket is detected and replaced safely;
- a read retries once after transport loss;
- a mutation is never replayed automatically;
- App shutdown issues graceful stop and leaves tmux untouched;
- launch warmup uses cached inventory before fresh inventory completes;
- selected and recent targets outrank background targets;
- readiness and tmux list share one Worker login;
- a fresh snapshot prevents a foreground query;
- a stale snapshot renders before background verification completes;
- inventory replacement cancels obsolete queued work; and
- command inspection proves that warmup never contains tmux create, attach,
  rename, kill, or Worker lifecycle operations.

Manual verification records Devbox SSH, Worker login, tmux response, and
terminal-first-byte timings before and after the change.

## Success criteria

- The first UI frame and machine tree are not delayed by prewarming.
- Every running Devbox has at most one App-owned SSH master.
- A warmed Devbox tmux query no longer pays the measured 1.4-second handshake.
- A warmed Worker session browser renders from cache immediately.
- Opening the browser repeatedly within 60 seconds creates no remote query.
- Worker warmup eventually covers every current Worker with at most two
  concurrent Worker logins.
- No prewarming path creates or mutates a tmux session.
- The user's SSH configuration remains unchanged.
- App shutdown and restart leave remote tmux sessions intact.

## Deferred next phase

If Worker terminal-first-byte latency remains unacceptable after this phase,
introduce a bounded pool of long-lived `mlx worker login ... agent --stdio`
channels behind the same connection seam. That phase may reuse tmux, metrics,
and PTY operations over a typed multiplexed protocol without requiring UI
callers to change.
