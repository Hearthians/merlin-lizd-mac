# Merlin Lizd for macOS

Merlin Lizd is a personal native macOS dashboard and terminal for Merlin
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
running Devbox and prewarms read-only tmux snapshots for current Workers, with
at most two Worker logins in flight. Socket names use hashed aliases in a
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
- `nvidia-smi` inside GPU Workers only for the live direct-sampling supplement
  or fallback; Merlin platform history remains available without it

The app is intentionally not sandboxed because it must invoke system SSH and
read the user's existing SSH and Merlin CLI state.

## Run during development

From this directory:

```sh
./scripts/test.sh
/usr/bin/swift run MerlinLizd
```

`test.sh` runs the repository's custom `MerlinLizdCoreTests` executable.

## Build the app

```sh
./scripts/package-app.sh
open "dist/Merlin Lizd.app"
```

The packaging script builds the `MerlinLizd` release product, assembles a
Finder-launchable app bundle, and applies a local ad-hoc signature.
The result is written to `dist/Merlin Lizd.app`. No Xcode project, Developer ID,
or signing certificate is required for local use.

SwiftTerm 1.14.0 is vendored with a small packaging patch so its Metal shader
lives under the standard `Contents/Resources` path. This keeps the local app
self-contained and allows strict signature verification.

For distribution to other Macs, add a Developer ID signature and notarization
as a separate release step; the local packaging path deliberately does neither.
