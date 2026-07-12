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
