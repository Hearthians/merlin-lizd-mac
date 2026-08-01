# MerlinHub for macOS — v1 specification

## Product intent

MerlinHub is a personal, native macOS workspace for seeing Lizd's Merlin CPU Devboxes and their Workers, entering any ready target quickly, and keeping remote shells durable through tmux.

The primary mental model is **machines**. A future **tasks** workspace may add fan-out execution without mixing task orchestration into the v1 machine browser.

## Vocabulary

- **Devbox**: a Merlin CPU Devbox Master discovered from Lizd's current Merlin account. Its platform name is the display label; its validated platform SSH destination is the preferred connection route, with a local alias as fallback.
- **Worker**: a Workspace Worker owned by one Devbox. Its validated platform SSH destination is preferred; `mlx worker login <id>` through the Devbox remains a fallback.
- **Target**: Local Mac, one Devbox, or one Worker.
- **Terminal tab**: one interactive terminal bound to exactly one target and, for remote targets, one tmux session.
- **Managed session**: a tmux session created by this app. Existing external tmux sessions are also discoverable and attachable.

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

## Inventory and refresh

- Discover all CPU Devboxes from the current `merlin-cli` account, not only aliases already present in SSH config.
- Validate and use the platform `ssh_proxy_cmd` destination when its encoded identity matches the Devbox SID. Match a safe local SSH alias only as fallback. Never display or persist raw ProxyCommand contents.
- For every Devbox, list Workers through `merlin-cli cpu-devbox workers list` with `filter.instance_sid`. This control-plane query does not require the Devbox process or a local SSH alias. Use `NO_COLOR=1 TERM=dumb mlx worker list` through SSH only when the platform query fails, the Devbox is running, and a validated connection target exists.
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
- Own at most one OpenSSH control socket per validated active connection target. Direct Workers use their own platform destination; relay-only Workers share the running parent Devbox target. Store sockets in an App-owned owner-only temporary directory under hashed target names. Pass `ControlMaster=auto`, that `ControlPath`, and `ControlPersist=600` explicitly to App SSH children; never modify the user's SSH configuration.
- Prewarm all current reachable Workers with selected/open/recent targets first. Direct probes bypass the parent Devbox; relay probes use `mlx worker login` only while the parent is running. Prewarming and browser refreshes are bounded globally and serialized per shared connection target. Warmup commands are fixed, read-only readiness and `tmux list-sessions` probes.
- Treat a tmux snapshot as fresh for 60 seconds and schedule current targets for refresh every five minutes. Fresh sheets make no remote request. Stale rows remain visible during background verification and after transport or Worker-not-ready failures.
- A warmed target avoids the measured SSH handshake, and a warmed Worker session sheet renders cached rows immediately. A direct Worker terminal also avoids `mlx worker login`; only a relay fallback may still incur that startup latency. A long-lived Worker `agent --stdio` transport is deferred for a later phase if fallback terminal-first-byte latency remains unacceptable.

## Authentication and safety

- Reuse the installed `merlin-cli` login, system SSH client, and SSH Agent. Platform routes do not require `~/.ssh/config`; local aliases remain a compatibility fallback. The app stores no password, private key, JWT, or raw ProxyCommand.
- A last-known inventory snapshot may be cached locally, but only from the safe projection: never Pod IPs, ports, webshell URLs, raw command output, or credentials.
- Read-only discovery may run automatically. Starting a Devbox requires confirmation; terminating one or more tmux sessions requires a separate destructive confirmation. No Devbox/Worker stop, delete, or kill mutation is exposed in v1.
- Closing a terminal tab or the App preserves every remote tmux session. Graceful App shutdown stops only App-owned OpenSSH masters after local channels drain. The explicitly confirmed terminate-session action is the only tmux-killing path.
- Use argument arrays when spawning local processes. Do not build a user-controlled shell command string.
- Remote tmux session names are sanitized to a conservative character set.

## Terminal routing

- Local target: start the user's login shell.
- Devbox target: start system `ssh` to its validated platform destination on the Merlin proxy port, or a safe local alias as fallback, and attach/create the selected tmux session.
- Worker target: start system `ssh` to the Worker's validated platform destination on the Merlin proxy port. If no direct destination exists, connect to the running parent Devbox, enter the Worker by numeric ID, and attach/create the selected tmux session there.
- The embedded terminal is primary. Opening the same target in Terminal/iTerm remains a fallback.

## Explicit non-goals

- Cross-machine batch commands or task fan-out.
- Resource creation, deletion, stopping, Worker launch, or Worker kill.
- File browser, editor, upload/download workflow, or IDE features.
- Multi-user onboarding, credential management, Windows, or Linux support.

## Delivery sequence

1. Real-data, read-only machine tree and overview.
2. Embedded local/SSH terminal and persistent tmux-backed tabs.
3. External tmux discovery and confirmed Devbox start action.
4. Package a locally runnable `.app`, then run the full tests and a two-axis code review against this specification.
