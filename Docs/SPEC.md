# MerlinHubX for macOS — v1 specification

## Product intent

MerlinHubX is a personal, native macOS workspace for seeing Lizd's Merlin CPU Devboxes and their Workers, entering any ready target quickly, and keeping remote shells durable through tmux.

The primary mental model is **machines**. Codex work is scoped to a real tmux
session inside that workspace; it is not a cross-machine fan-out facility.

## Vocabulary

- **Devbox**: a Merlin CPU Devbox Master discovered from Lizd's current Merlin account. A known SSH alias is its preferred connection route and display label.
- **Worker**: a Workspace Worker owned by one Devbox and entered through `mlx worker login <id>` on that Devbox.
- **Target**: Local Mac, one Devbox, or one Worker.
- **Terminal tab**: one interactive terminal bound to exactly one target and, for remote targets, one tmux session.
- **Managed session**: a tmux session created by this app. Existing external tmux sessions are also discoverable and attachable.
- **Tmux session identity**: the server-provided session ID plus creation time.
  It is stable across rename and is distinct from the editable session name.
- **Terminal conversation key**: a non-optional stable target identity plus a
  tmux session identity. It owns one persistent Codex conversation, run state,
  approvals, and operation journal.
- **Active visible pane**: the current window and active pane on the tmux
  client rendered by the tab. It is the only terminal observation and mutation
  surface for that conversation.
- **Codex drawer**: the bottom 42-point idle, 92-point active, or 20–50%
  expanded conversation surface attached to the selected tmux conversation.
- **Temporary pane lease**: typed provenance for a task-created, visibly active
  tmux pane and the original surface that must be restored after proven-safe
  close.

## v1 user experience

1. Open a full desktop window. A menu-bar companion is not part of v1.
2. The sidebar shows Local, all Devboxes, nested Workers, and an All Workers view.
3. Selecting a node shows current state and allocated resources. Double-click, Return, or the Connect button opens or restores its terminal.
4. Terminal tabs are independent. More than one tab may target the same machine, and each tab may have its own editable tmux session name.
5. Closing the app or losing SSH must not terminate remote work. On relaunch, restore tab metadata and reconnect only the selected tab; reconnect other tabs on demand.
6. Existing tmux sessions created outside the app can be listed and attached. The session browser supports selecting App-created sessions or arbitrary sessions, then terminating the selection after a destructive confirmation.
7. Closing a terminal tab leaves its tmux session running by default. The close dialog also offers an explicit “close and terminate tmux” action; terminating a session closes every local tab attached to that same target/session.
8. A stopped existing Devbox can be started after an explicit in-app confirmation. v1 has no stop, delete, Worker create, or Worker terminate actions.
9. A Local terminal tab is available for Mac commands and manual SSH.
10. Selecting a reachable Worker shows live utilization cards and five-minute curves for CPU, memory, GPU, and VRAM. GPU temperature and power remain visible with the latest sample.
11. A tmux-backed tab exposes the native Codex drawer. It reuses the local
    Codex login and model configuration, requires no API key, and supports
    local, Devbox, and Worker tmux sessions.
12. Matching tabs share the same Codex transcript and badges. Different tmux
    conversations may continue in parallel while the selected tab changes.

## Inventory and refresh

- Discover all CPU Devboxes from the current `merlin-cli` account, not only aliases already present in SSH config.
- Match a Devbox SID/name to a safe local SSH alias when possible. Never display or persist ProxyCommand contents.
- For every running Devbox, list Workers through `merlin-cli cpu-devbox workers list` with `filter.instance_sid`. This platform query does not require a local SSH alias. Use `NO_COLOR=1 TERM=dumb mlx worker list` through SSH only when the platform query fails and a safe alias exists.
- Keep Merlin's Worker lifecycle status separate from SSH/`mlx worker login` readiness. Platform `running` is not proof that a terminal connection is ready.
- Render the last safe snapshot immediately, then refresh Devboxes, platform Worker lists, and Worker connection readiness in separate stages. A slow platform query or `mlx worker login` must not block or clear the machine tree.
- Refresh immediately on launch, manually on request, and every 15 seconds while the app is active. Pause foreground polling when inactive.
- Show lifecycle/connectivity, CPU, memory, GPU type/count, Worker readiness, last refresh time, and actionable errors.
- While a Worker detail page is visible, obtain the official Grafana URL from the Worker **list** response, discover semantic panels with `merlin-cli grafana describe`, and load five-minute CPU, memory, GPU, VRAM, and temperature history with `grafana panel-data`. Do not hardcode panel IDs across dashboards.
- Grafana panel queries are large and may take tens of seconds, so they run independently from machine refresh and at low frequency. A single cancellation-aware SSH/`mlx worker login` stream may provide the live edge or act as fallback. The UI must label `Merlin 平台`, `Merlin + Worker`, or `Worker 直连` and explain degradation.
- Prefer cgroup CPU/memory data over host `/proc` values only on the direct fallback path. Retain all telemetry for at most five minutes in memory, persist none of it, and stop every process when the page leaves the view.
- A Worker appearing in a list is not proof that it is ready. Connection failures and the text `worker has not been ready yet` must remain visible as readiness/transport errors.

### SSH prewarming and tmux snapshot cache

- Start prewarming from the restored safe inventory without delaying the first App frame, then reconcile against authoritative inventory updates.
- Own at most one OpenSSH control socket per running Devbox. Store sockets in an App-owned owner-only temporary directory under hashed alias names. Pass `ControlMaster=auto`, that `ControlPath`, and `ControlPersist=600` explicitly to App SSH children; never modify the user's SSH configuration.
- Prewarm all current Workers with selected/open/recent targets first. Prewarming and browser refreshes share a total limit of two concurrent `mlx worker login` operations. Warmup commands are fixed, read-only readiness and `tmux list-sessions` probes.
- Treat a tmux snapshot as fresh for 60 seconds and schedule current targets for refresh every five minutes. Fresh sheets make no remote request. Stale rows remain visible during background verification and after transport or Worker-not-ready failures.
- A warmed Devbox operation avoids the measured SSH handshake, and a warmed Worker session sheet renders cached rows immediately. The first interactive Worker terminal may still incur `mlx worker login` latency. A long-lived Worker `agent --stdio` transport is deferred for a later phase if terminal-first-byte latency remains unacceptable.

## Authentication and safety

- Reuse the installed `merlin-cli` login, system SSH config, and SSH Agent. The app stores no password, private key, JWT, or raw ProxyCommand.
- A last-known inventory snapshot may be cached locally, but only from the safe projection: never Pod IPs, ports, webshell URLs, raw command output, or credentials.
- Read-only discovery may run automatically. Starting a Devbox requires confirmation; terminating one or more tmux sessions requires a separate destructive confirmation. No Devbox/Worker stop, delete, or kill mutation is exposed in v1.
- Closing a terminal tab or the App preserves every remote tmux session. Graceful App shutdown stops only App-owned OpenSSH masters after local channels drain. The explicitly confirmed terminate-session action is the only tmux-killing path.
- Use argument arrays when spawning local processes. Do not build a user-controlled shell command string.
- Remote tmux session names are sanitized to a conservative character set.

## Terminal routing

- Local target: start the user's login shell.
- Devbox target: start system `ssh` to its safe alias and attach/create the selected tmux session.
- Worker target: start system `ssh` to its parent Devbox, enter the Worker by numeric ID, and attach/create the selected tmux session there.
- The embedded terminal is primary. Opening the same target in Terminal/iTerm remains a fallback.

## Tmux Codex drawer invariants

- Codex support is enabled only after a tab resolves a non-optional stable tmux
  identity and registers its exact terminal endpoint. Plain local shells and
  unresolved, detached, exited, closed, reconnecting, or disconnected routes
  fail closed for new input.
- The local `codex app-server` adapter supports Codex CLI versions
  `>= 0.144.2 && < 0.145.0`. It inherits the existing Codex login, model, and
  auth environment. Dynamic Tool wire/schema names remain in the replaceable
  adapter; Core terminal tools, permissions, session routing, and journals are
  protocol-neutral.
- Codex observes the rendered SwiftTerm grid, including cursor, styles,
  alternate-screen state, and keyboard mode. It sends only semantic text/key
  events through the active terminal driver. Every mutation carries an
  expected revision; stale revisions require re-observation and failed input
  is never replayed.
- Window or pane navigation is a visible tmux selection. Codex never reads or
  mutates a hidden pane. A background tab may keep its already-running Codex
  turn, with complete activity/journal state and a badge, but its control
  endpoint remains pinned for the turn.
- Task-created panes become visible before use. Close requires the fixed
  visible `jobs -p` proof from a supported idle shell. Foreground processes,
  background jobs, marker ambiguity, disconnect, or any uncertainty retain the
  pane with typed provenance and a user-visible reason.
- `TerminalPermissionPolicy` computes effective risk from both the declared
  risk and exact visible screen/input. High-risk input exposes only **Allow
  Once** and **Deny**. Approval is bound to the exact payload, endpoint, screen,
  and canonical tmux surface; any drift expires it.
- One conversation key has at most one active turn and one serialized terminal
  mutation lane. Different keys may overlap. Duplicate tabs share messages and
  badges, while the most recently focused matching endpoint is pinned only
  when the next turn begins; an active pin never migrates.
- **Stop and Take Over** first quiesces the exact coordinator turn, then returns
  keyboard ownership. It emits no Control-C byte, pane/session kill, terminal
  close, or remote process signal. Notification selection may reveal a
  conversation but never grants approval.
- The owner-only operation journal is written before each side effect and
  records request, screen, risk, exact approval, endpoint, emitted batch,
  result, and temporary-pane lifecycle. Archiving preserves mapping and
  journal. Only separately confirmed deletion removes the Codex thread,
  mapping, and journal through staged recovery.
- App-server, PTY, SSH, endpoint, and app-shutdown failure quiesce only owned
  local turns and channels. Remote tmux sessions and processes remain intact;
  retry resumes durable conversations without replaying terminal input.

## Explicit non-goals

- Cross-machine batch commands or task fan-out.
- Resource creation, deletion, stopping, Worker launch, or Worker kill.
- File browser, editor, upload/download workflow, or IDE features.
- Multi-user onboarding, credential management, Windows, or Linux support.
- API-key configuration, remote Codex installation, hidden-pane readers,
  arbitrary remote shell/file APIs, MCP transport, or cross-device sync.

## Delivery and verification

The v1 tree contains the real-data machine browser, embedded local/SSH
terminal, persistent tmux-backed tabs, external tmux discovery, confirmed
Devbox start/session termination, and the tmux Codex drawer described above.
Automated acceptance uses fakes plus real local persistence and launches no
Merlin, SSH, tmux, Codex, OpenAI, or network process. Release verification runs
`./scripts/test.sh`, `/usr/bin/swift build`, and `./scripts/package-app.sh`; the
authoritative product is `MerlinHubX` and the signed local bundle is
`dist/MerlinHubX.app`.
