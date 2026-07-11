# Merlin Lizd for macOS

Merlin Lizd is a personal native macOS dashboard and terminal for Merlin
development machines and their workers. It uses the existing Merlin CLI login,
system SSH configuration, and remote `mlx`/`tmux` tools; it does not store SSH
passwords or Merlin tokens itself.

## Requirements

- macOS 14 or newer on Apple Silicon
- Apple Command Line Tools with Swift 6
- `merlin-cli` installed and logged in
- working SSH aliases for development machines
- `mlx` and `tmux` on the corresponding remote machines

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
