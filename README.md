# MerlinHubX for macOS

MerlinHubX is a personal native macOS dashboard and terminal for Merlin
development machines and their workers. It uses the existing Merlin CLI login,
system SSH configuration, and remote `mlx`/`tmux` tools; it does not store SSH
passwords or Merlin tokens itself.

Machine data uses stale-while-revalidate behavior: the last safe snapshot is
shown immediately, while Devboxes, Worker lists, and Worker readiness refresh
in separate background stages. The snapshot deliberately excludes Pod IPs,
ports, webshell URLs, ProxyCommand text, raw command output, and credentials.

Worker inventory and lifecycle state come from `merlin-cli cpu-devbox workers
list`; SSH is only the fallback inventory route and the connection path for
terminals. Selecting a Worker loads its official Merlin/Grafana five-minute
history and, when an SSH alias is available, supplements the live edge with one
read-only Worker stream. The UI always identifies the active data source and
marks direct-only data as degraded. Leaving the page cancels and reaps active
processes; telemetry and signed monitoring URLs are never persisted.

## SSH reuse and session prewarming

At launch, the app prepares one App-owned OpenSSH control socket for each
running Devbox and prewarms read-only tmux snapshots for current Workers. All
tmux discovery, including browser refreshes, shares a total limit of two
Worker logins in flight. Socket names use hashed aliases in a
private temporary directory. The app does not edit the user's SSH
configuration; child SSH commands continue to use that configuration and the
SSH Agent while explicitly opting into the App-owned socket.

Tmux snapshots are fresh for 60 seconds and are refreshed every five minutes.
A stale snapshot remains visible while verification runs and also remains the
last-known result if verification fails or a Worker is temporarily not ready.
Closing a terminal tab or quitting the app stops only local channels and the
App-owned SSH masters; it preserves remote tmux sessions and their processes.
The confirmed **terminate session** action is the only app path that kills a
tmux session.

Connection reuse removes the Devbox SSH handshake from warmed operations, and
a warmed Worker session sheet can render its cached rows immediately. Opening
the first interactive Worker terminal can still pay `mlx worker login` startup
latency. If that terminal-first-byte boundary remains unacceptable, a future
phase may evaluate a long-lived Worker `agent --stdio` transport; it is not
part of v1.

## Requirements

- macOS 14 or newer on Apple Silicon
- Apple Command Line Tools with Swift 6
- `merlin-cli` installed and logged in
- working SSH aliases for development machines
- `mlx` and `tmux` on the corresponding remote machines
- local Codex CLI `>= 0.144.2 && < 0.145.0` for the tmux Codex drawer
- `nvidia-smi` inside GPU Workers only for the live direct-sampling supplement
  or fallback; Merlin platform history remains available without it

The app is intentionally not sandboxed because it must invoke system SSH and
read the user's existing SSH and Merlin CLI state.

## Run during development

From this directory:

```sh
./scripts/test.sh
/usr/bin/swift run MerlinHubX
```

`test.sh` runs the repository's custom `MerlinLizdCoreTests` executable.

## Build the app

```sh
./scripts/package-app.sh
open "dist/MerlinHubX.app"
```

The packaging script builds the `MerlinHubX` release product, assembles a
Finder-launchable app bundle, and applies a local ad-hoc signature.
The result is written to `dist/MerlinHubX.app`. No Xcode project, Developer ID,
or signing certificate is required for local use.

SwiftTerm 1.14.0 is vendored with a small packaging patch so its Metal shader
lives under the standard `Contents/Resources` path. This keeps the local app
self-contained and allows strict signature verification.

For distribution to other Macs, add a Developer ID signature and notarization
as a separate release step; the local packaging path deliberately does neither.

## Codex UI for tmux sessions

Implementation status: shipped in this repository. The native drawer, local
app-server adapter, terminal permission router, persistent conversations,
operation journal, notifications, and failure containment are wired into the
`MerlinHubX` executable product and covered by cross-layer acceptance tests.

### Goal and scope

MerlinHubX provides a native Codex conversation drawer for every terminal
tab backed by tmux. Codex runs on the local Mac, reuses the user's existing
Codex login and model configuration, and operates the same tmux session shown
by MerlinHubX. The remote machine does not need Codex, and MerlinHubX has no
API-key field or separate model configuration.

The first version supports local, Devbox, and Worker tmux sessions. It supports
shells and full-screen interactive programs such as Vim, REPLs, and terminal
menus. Plain local shell tabs without tmux are excluded. Remote Codex, an MCP
transport, API-key mode, audio or image input, and cross-device conversation
sync are also excluded.

Sending a message starts a Codex turn and transfers keyboard ownership to
Codex. The user can still scroll, select, and copy terminal content. Choosing
**Stop and Take Over** interrupts the turn, cancels input that has not been
sent, and restores the keyboard. It does not send Control-C, close a pane, or
terminate a remote process.

### Architecture and dependency direction

The dependency direction is:

```text
CodexDrawerView
    -> CodexSessionCoordinator
    -> CodexAgentClient
    <- CodexAppServerAdapter

CodexAppServerAdapter
    -> TerminalToolRouter
    -> TerminalSessionPort
    <- SwiftTermTerminalDriver
    -> active tmux window and pane
```

`CodexAgentClient` is a protocol for starting or resuming a conversation,
sending or steering a turn, interrupting a turn, and consuming agent events.
The first implementation uses `codex app-server`. JSONL RPC messages, Dynamic
Tool schemas, Codex version checks, and app-server process management remain
inside `CodexAppServerAdapter`.

The reusable domain layer contains `TerminalToolRouter`, terminal tool calls
and results, permission decisions, conversation routing, temporary-pane
leases, and the operation journal. These types do not import or expose Codex,
JSON-RPC, or Dynamic Tool types. A future MCP adapter can replace the
app-server adapter without changing terminal control, permissions, or routing.

SwiftTerm and AppKit integration stays in the App target. Reusable state
machines, policies, value types, codecs, and routing behavior stay in Core and
are testable through fake terminal ports.

### Terminal observation and control loop

Codex observes SwiftTerm's rendered character grid after escape-sequence
processing rather than reading raw PTY output. A `TerminalScreenSnapshot`
contains a monotonically increasing revision, terminal dimensions, cursor
position, visible text, significant cell attributes such as inverse or
selected runs, terminal mode, and a compact change summary. This representation
allows the agent to understand alternate-screen applications without treating
ANSI control bytes as a transcript.

The domain tool surface is:

- `observeScreen`: return the current rendered snapshot.
- `sendInput`: send text or semantic keys with an expected screen revision,
  purpose, and declared risk.
- `waitForScreen`: wait for a change, stability, or a timeout and then return
  the newest snapshot.
- `selectVisibleSurface`: select a tmux window or pane through the current tmux
  client and return the newly active screen.
- `createTemporaryPane`: create and activate a task-scoped pane and return a
  lease that records the original surface.
- `finishTemporaryPane`: close an idle temporary pane or retain it when a
  process is running or idleness cannot be proven.

Each action follows an observe, decide, guard, act, and wait cycle. `sendInput`
is rejected when its expected revision no longer matches the terminal. Codex
must observe again before acting. Waiting is driven by screen changes and
stability instead of fixed sleeps. An input batch is acknowledged only after
the PTY accepts it; an interrupted or failed batch is never replayed
automatically.

Text, Enter, Escape, navigation keys, function keys, and Control/Option key
combinations are represented as semantic input events and encoded only by the
terminal driver. Tmux window and pane selection changes that session's active
surface before any further observation or input. Codex does not inspect or
operate another hidden pane inside the same tmux session.

### Tmux surfaces and temporary panes

An app tab may be in the background while its Codex task continues. This is
allowed: different tmux sessions can run independently in parallel. Within
each tmux session, however, Codex only observes and operates its current window
and active pane. Switching uses tmux control behavior that also changes what
the user sees when returning to that tab; hidden panes are never mutated
silently.

Codex may create a temporary pane to keep investigation output out of the
user's original pane. The new pane becomes that session's active pane before
Codex uses it. At task completion, the pane is closed only when it is known to
be at an idle shell. A foreground process, a background job, or uncertain
state causes the pane to be retained as an ordinary pane and reported in the
conversation. When a temporary pane is safely closed, the original window and
pane are restored.

### Persistent conversations and concurrency

One real tmux session maps to one persistent Codex thread. A
`TerminalConversationKey` combines a stable target identity with the tmux
session identity:

- Local: the local target plus the tmux identity.
- Devbox: Devbox SID plus the tmux identity.
- Worker: Devbox SID, Worker ID, and the tmux identity.

The tmux identity includes the server-provided session ID and creation time;
the editable session name is routing and display metadata, not identity.
Renaming a session therefore preserves its conversation. Terminating a session
and later creating another with the same name produces a new conversation;
the old thread remains available as history. MerlinHubX resolves the real tmux
identity before enabling Codex for a tab. Failure to resolve it disables Codex
for that tab without affecting the terminal.

Multiple local tabs attached to the same tmux session share the conversation,
run state, approvals, and operation journal. While idle, the most recently
focused matching tab becomes the next control endpoint. Starting a turn pins
that endpoint until the turn finishes or is interrupted. Closing the pinned
tab interrupts the turn rather than moving an in-flight action to another PTY.

There is at most one active turn per conversation key. A message submitted
during an active turn steers that turn. Different conversation keys may have
active turns in parallel. Their states are tracked independently as idle,
thinking, controlling, awaiting approval, waiting for the user, completed,
failed, or interrupted.

The conversation-to-thread mapping and operation journal are stored under the
App's Application Support directory. The journal records every Codex tool
request and result, screen revisions and observed diffs, emitted input batch,
risk classification, approval decision, endpoint selection, and temporary-pane
lifecycle. It is a complete record of Codex-mediated terminal activity, not a
byte-for-byte recording of unrelated user typing. Journal files are readable
only by the current macOS user and may contain terminal content or secrets.
They remain associated with the Codex thread when tmux is renamed, closed, or
terminated. Deleting a conversation is a separately confirmed action that
deletes its local mapping and journal as well as the corresponding Codex
thread; archiving does not delete either record.

### Permission policy

`TerminalPermissionPolicy` is authoritative and runs inside the domain layer;
the protocol adapter cannot bypass it. Observation, waiting, and harmless
navigation are automatic. Routine terminal work runs automatically. High-risk
operations pause the turn and require a one-time approval in the drawer.

High-risk signals include destructive deletion, overwriting valuable data,
terminating jobs or sessions, force operations, publishing or pushing changes,
credential changes, and accepting a destructive confirmation prompt. The
effective risk is the higher of the agent's declared risk and deterministic
rules applied to the proposed input and current screen. If an unfamiliar TUI
prompt cannot be classified confidently, confirmation-style input is
escalated instead of guessed safe.

An approval is bound to the exact input payload, endpoint, and expected screen
revision. Any screen or route change expires it. The first version supports
only allow once and deny; it does not persist broad allow rules. A background
approval pauses only its own turn, marks every matching terminal tab, and
sends a macOS notification without switching the selected tab.

### Codex app-server adapter

MerlinHubX launches a local `codex app-server` child using the user's existing
Codex home and authentication. Per-process overrides disable built-in shell,
file-editing, web, app, and unrelated tools and provide only the namespaced
`merlin_tmux` Dynamic Tools. The Codex process receives no remote filesystem
mount and uses an empty, read-only local working directory. All terminal side
effects must therefore enter through `TerminalToolRouter`.

At startup, the adapter resolves the Codex executable, checks a supported
version range, performs the initialize/capability handshake, and validates the
critical message shapes expected by the bundled protocol fixtures. Additive
unknown fields and notifications are ignored. A missing capability or an
incompatible critical field disables Codex while leaving the rest of the app
operational. Dynamic Tools remain an implementation detail of this adapter.

The adapter maps app-server thread and turn events into protocol-neutral agent
events. It also maps Dynamic Tool requests into domain tool calls and returns
domain results. No app-server request object crosses into Core.

### Bottom conversation drawer

The selected terminal shows a bottom drawer with three presentation states:

- Collapsed at 42 points: an idle composer that preserves terminal height.
- Compact at 92 points: the current action, a steer composer, and **Stop and
  Take Over** while a turn is active.
- Expanded and user-resizable between 20 and 50 percent of the window: full
  conversation history, tool activity, operation details, and approval cards.

The drawer is scoped to the selected tmux conversation. Matching terminal tabs
show shared run and approval badges. Other running sessions show their own
badges while continuing in the background. Tool activity is summarized by
default and can be expanded to the operation journal. Approval cards show the
exact proposed input, reason, target surface, and relevant screen context.

### Failure and shutdown behavior

- An app-server crash interrupts active turns. A supervisor retries with
  exponential backoff, resumes persistent threads, and never replays terminal
  input.
- A PTY or SSH disconnect interrupts only the associated turn. The user
  reconnects the terminal explicitly before continuing the thread.
- A stale screen revision is a normal tool result that asks Codex to observe
  again, not a fatal error.
- A screen wait timeout returns the newest snapshot without duplicating input.
- Authentication, unsupported versions, unavailable capabilities, and server
  overload appear as retryable drawer errors when appropriate.
- App shutdown interrupts turns and stops the local app-server and terminal
  channels. Existing shutdown behavior continues to preserve all remote tmux
  sessions and their processes.

### Operations, storage, and troubleshooting

The supported Codex CLI range is exactly `>= 0.144.2 && < 0.145.0`. MerlinHubX
resolves the installed local executable, inherits the user's Codex home,
login, model, and auth environment, and never asks for an API key. Use the
normal Codex CLI or ChatGPT login flow if the drawer reports authentication is
required; do not add credentials to MerlinHubX.

For compatibility with existing installs, Codex state remains below
`~/Library/Application Support/MerlinLizd/`:

- `CodexConversations/conversations.json` stores the stable tmux-to-thread
  mapping, archive state, and staged deletion recovery.
- `TerminalOperations/Mappings/` and `TerminalOperations/Journals/` store the
  per-conversation operation audit. Journal JSONL can contain visible terminal
  text, proposed input, approval context, and other secrets shown in the pane.
- `CodexRuntime/` is the owner-only empty runtime working directory for the
  local app-server child.

These directories are created owner-only (`0700`) and durable data files are
owner-readable/writable (`0600`). They should be protected and backed up with
the same care as terminal history. Archiving a conversation preserves its
mapping, Codex thread, and journal. Only the separately confirmed **Delete
Conversation** action removes the remote Codex thread, local mapping, and
journal through a recoverable staged deletion.

Drawer availability is explicit. **Starting** means local app-server startup
is in progress. **Authentication required** means the local Codex login must be
repaired. **Unsupported version** requires installing a CLI in the supported
range and is not blindly retried. **Capability unavailable**, **overloaded**,
and **crashed** preserve terminal sessions and offer a bounded, non-sensitive
retry path. **Endpoint registering**, **registration failed**, **detached**,
**reconnecting**, and **disconnected** refer to the selected terminal route;
reconnect or reopen that tmux tab before sending more work.

For a drawer that cannot start, first run `codex --version`, confirm the exact
range above, and verify the normal Codex CLI can use the existing login. For a
terminal availability error, reconnect the tab and confirm its tmux session
identity still resolves. Retry never replays a previously failed terminal
input. The expanded drawer shows recent bounded journal history; the files on
disk remain the complete audit record.

### Verification

Automated tests use fakes and scripted frames; they do not connect to live
Merlin, SSH, tmux, or OpenAI services.

- Core tests cover conversation identity, rename and same-name recreation,
  endpoint pinning, same-session serialization, cross-session concurrency,
  screen revisions, risk classification, approval expiry, temporary-pane
  leases, interruption, and journal persistence.
- Adapter contract tests replay JSONL fixtures for initialization, thread start
  and resume, streaming items, steering, Dynamic Tool requests, interruption,
  unknown notifications, overload, malformed messages, and process crashes.
- Terminal-loop tests use scripted shell and alternate-screen grids to cover
  cursor movement, significant cell attributes, semantic key encoding, screen
  stability, timeouts, and stale-input rejection.
- UI-model tests cover drawer transitions, keyboard ownership, takeover,
  shared badges, background approvals, notifications, and graceful degradation.

Acceptance requires every Codex input to pass through the domain permission
layer and appear in the operation journal; takeover to restore the keyboard
must not disturb remote processes; parallel sessions must remain independent;
and Codex, PTY, SSH, or App failure must preserve remote tmux. Before changes
are submitted, `./scripts/test.sh` and `/usr/bin/swift build` must pass.
