# Task 11 Third Repair Report

Status: `DONE`

Base: `b8cea7f`

Commit: the commit containing this report, with subject
`fix: show stable tmux approval identity`; its final object ID is reported in
the agent handoff because a Git commit cannot contain its own final object ID.

## RED evidence

- Added a Core behavior test with two `TmuxSessionIdentity` values sharing
  `serverSessionID == "$1"` and differing only by `createdAtEpoch`.
- The first focused run failed to compile because
  `TmuxSessionIdentity.stableDisplayString` did not exist. The test requires
  exact `$1@1720000000` / `$1@1720000001` output and proves the two lifecycle
  identities format differently.

## Implementation

- Added the testable Core `stableDisplayString` projection on
  `TmuxSessionIdentity`. It uses the unlocalized, unambiguous
  `serverSessionID@createdAtEpoch` representation.
- The approval card's live context branch now displays the complete stable
  identity from `context.surface.sessionIdentity`.
- The legacy/fallback branch now displays the complete stable identity from
  `conversationKey.tmux`; it no longer drops lifecycle information when the
  full conversation key is already present.
- Equality, hashing, Codable persistence, and stored field shape are unchanged.
  No date localization or human-time conversion was introduced.

## Changed files

- `Sources/MerlinLizdCore/TmuxSessionParser.swift`
- `Sources/MerlinLizdApp/CodexApprovalCardView.swift`
- `Tests/MerlinLizdCoreTests/TerminalConversationTests.swift`
- This report

## Verification

- RED: `TerminalConversationTests` failed on the missing formatter API.
- GREEN Core identity suite: 4/4 tests passed.
- Focused formatter/approval command: 31/31 tests in 3 suites passed.
- Task 11 focused command: 141/141 tests in 6 suites passed.
- `./scripts/test.sh`: 714/714 tests in 46 suites passed; no transport flake was
  observed.
- `/usr/bin/swift build`: passed before this report and is rerun after it.
- Cumulative `git diff --check f9197f9..HEAD`, staged diff check, protected-path
  inspection, and final worktree status are performed immediately before
  commit.
- No Task 12, `Vendor/`, `Packaging/`, `Assets/`, transport test, or unrelated
  behavior was modified.

## Self-review

- Both approval display branches use the same Core formatter and expose both
  stable identity components.
- The formatter is bounded by the existing validated server identifier and
  fixed-width `Int64` decimal representation.
- The repair adds no new persisted state and introduces no authorization or
  routing behavior change.
