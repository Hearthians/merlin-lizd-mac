# Repository Guidelines

## Project Structure & Module Organization

This is a macOS 14+ Swift 6 package. `Sources/MerlinLizdCore/` contains the domain, Merlin CLI, SSH, tmux, and metrics logic. `Sources/MerlinLizdApp/` contains the SwiftUI application and terminal UI. Keep UI orchestration in the app target and reusable, testable behavior in Core. Tests live in `Tests/MerlinLizdCoreTests/`; each production type generally has a matching `*Tests.swift` file. `Assets/` and `Packaging/Info.plist` support app packaging. `Vendor/SwiftTerm/` is a vendored dependency—modify it only when intentionally updating its documented local patch.

## Build, Test, and Development Commands

- `./scripts/test.sh` runs the repository's `MerlinLizdCoreTests` executable using Swift Testing.
- `/usr/bin/swift build` compiles the package for development.
- `/usr/bin/swift run MerlinLizd` builds and launches the native app.
- `./scripts/package-app.sh` builds the release product, validates the plist, signs an ad-hoc app bundle, and writes `dist/Merlin Lizd.app`.

Run the test script before submitting changes. Packaging requires macOS and Apple Command Line Tools.

## Coding Style & Naming Conventions

Follow the existing Swift style: four-space indentation, braces on the declaration line, and one focused type or extension per file where practical. Use `PascalCase` for types, `camelCase` for functions and properties, and descriptive protocol names ending in `-ing` (for example, `InventoryProcessRunning`). Prefer `async`/`await`, actors, `Sendable` values, typed errors, and argument arrays over shell command strings. Keep user-facing views in files named `*View.swift`, models in `*Model.swift`, and tests in `*Tests.swift`.

## Testing Guidelines

Write Swift Testing suites with `@Suite`, `@Test`, and `#expect`. Cover parsing, command construction, lifecycle behavior, and concurrency boundaries without calling live Merlin, SSH, or tmux services; use the local fakes and support types already in the test target. Name tests as behavior statements, such as `loadsDevboxRolesConcurrently`.

## Commit & Pull Request Guidelines

Use concise Conventional Commit prefixes reflected in history: `feat:`, `fix:`, `refactor:`, and `docs:`. Keep each commit scoped to one change. Pull requests should explain the behavioral impact, identify tests run, link the relevant issue or spec when available, and include screenshots for SwiftUI or terminal UI changes. Call out any changes to SSH, command execution, persistence, or packaging explicitly.
