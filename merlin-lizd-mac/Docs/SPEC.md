# Merlin Lizd for macOS — v1 specification

## Product intent

Merlin Lizd is a personal, native macOS workspace for seeing Lizd's Merlin CPU Devboxes and their Workers, entering any ready target quickly, and keeping remote shells durable through tmux.

The primary mental model is **machines**. A future **tasks** workspace may add fan-out execution without mixing task orchestration into the v1 machine browser.

## Vocabulary

- **Devbox**: a Merlin CPU Devbox Master discovered from Lizd's current Merlin account. A known SSH alias is its preferred connection route and display label.
- **Worker**: a Workspace Worker owned by one Devbox and entered through `mlx worker login <id>` on that Devbox.
- **Target**: Local Mac, one Devbox, or one Worker.
- **Terminal tab**: one interactive terminal bound to exactly one target and, for remote targets, one tmux session.
- **Managed session**: a tmux session created by this app. Existing external tmux sessions are also discoverable and attachable.

## v1 user experience

1. Open a full desktop window. A menu-bar companion is not part of v1.
2. The sidebar shows Local, all Devboxes, nested Workers, and an All Workers view.
3. Selecting a node shows current state and allocated resources. Double-click, Return, or the Connect button opens or restores its terminal.
4. Terminal tabs are independent. More than one tab may target the same machine, and each tab may have its own editable tmux session name.
5. Closing the app or losing SSH must not terminate remote work. On relaunch, restore tab metadata and reconnect only the selected tab; reconnect other tabs on demand.
6. Existing tmux sessions created outside the app can be listed and attached.
7. A stopped existing Devbox can be started after an explicit in-app confirmation. v1 has no stop, delete, Worker create, or Worker terminate actions.
8. A Local terminal tab is available for Mac commands and manual SSH.

## Inventory and refresh

- Discover all CPU Devboxes from the current `merlin-cli` account, not only aliases already present in SSH config.
- Match a Devbox SID/name to a safe local SSH alias when possible. Never display or persist ProxyCommand contents.
- For every running, routable Devbox, list Workers with `NO_COLOR=1 TERM=dumb mlx worker list` through SSH. Worker list requests may run concurrently with a bounded limit.
- Refresh immediately on launch, manually on request, and every 15 seconds while the app is active. Pause foreground polling when inactive.
- Show lifecycle/connectivity, CPU, memory, GPU type/count, Worker readiness, last refresh time, and actionable errors. Real-time utilization charts are not part of v1.
- A Worker appearing in a list is not proof that it is ready. Connection failures and the text `worker has not been ready yet` must remain visible as readiness/transport errors.

## Authentication and safety

- Reuse the installed `merlin-cli` login, system SSH config, and SSH Agent. The app stores no password, private key, JWT, or raw ProxyCommand.
- Read-only discovery may run automatically. Starting a Devbox requires a user confirmation. No other resource mutation is exposed in v1.
- Use argument arrays when spawning local processes. Do not build a user-controlled shell command string.
- Remote tmux session names are sanitized to a conservative character set.

## Terminal routing

- Local target: start the user's login shell.
- Devbox target: start system `ssh` to its safe alias and attach/create the selected tmux session.
- Worker target: start system `ssh` to its parent Devbox, enter the Worker by numeric ID, and attach/create the selected tmux session there.
- The embedded terminal is primary. Opening the same target in Terminal/iTerm remains a fallback.

## Explicit non-goals

- Cross-machine batch commands or task fan-out.
- Resource creation, deletion, stopping, Worker launch, or Worker kill.
- File browser, editor, upload/download workflow, IDE features, or monitoring charts.
- Multi-user onboarding, credential management, Windows, or Linux support.

## Delivery sequence

1. Real-data, read-only machine tree and overview.
2. Embedded local/SSH terminal and persistent tmux-backed tabs.
3. External tmux discovery and confirmed Devbox start action.
4. Package a locally runnable `.app`, then run the full tests and a two-axis code review against this specification.
