# Codex notifications

Open **Codex 通知** in the sidebar. Select the local machine or an SSH host and
choose **配置并启用**. This installs a small Python 3 recorder on the machine where
Codex runs, and merges its `Stop`, `PermissionRequest`, and `UserPromptSubmit`
hooks into the user-level Codex `hooks.json`. Existing hooks are retained and a
backup is made before changing an existing file. The active connection's
`CODEX_HOME`, or `~/.codex`, determines the configuration location.

Use a current Codex CLI with hooks enabled. Review and trust the new hooks with
Codex's `/hooks` command, then start a new session. Installation does not bypass
Codex's trust review or change any approval decision. If hooks are disabled,
run `codex features enable hooks` on that machine. The page distinguishes a
successful connection from actually receiving the first event.

Choose **开启系统通知** separately on each Mac to request macOS notification
permission. Notification history and unread indicators work without that
permission. In macOS System Settings, allow notifications for TmuxHub if they
were previously denied. Hooks never approve a tool, block a turn, or send text
back to the model.

## Multiple devices and reconnects

Read status is shared through the host: reading a notification on one Mac marks
the same event read on every other connected Mac after its next sync. Existing
system reminders are removed there too. This uses the same host feed and SSH
account, even when each Mac uses a different SSH alias. Offline read actions are
saved locally and retried after reconnecting; concurrent reads are merged.

Each device stores its own sources, delivery cursor, and session mute settings.
Reading an event never removes its history from the host.
Install/enable the same host on each Mac that should receive its notifications;
repeated setup preserves the host feed identity and does not duplicate hooks.
Aliases that lead to the same feed are deduplicated on each device.

TmuxHub checks enabled sources about every 20 seconds while running and when the
Mac wakes. The host keeps up to 2,000 events for 30 days. Closing a terminal tab
does not stop collection. If TmuxHub is closed or the Mac is offline, events
within those limits are collected after reconnecting. The initial connection
imports retained history without a burst of old system alerts; its read status
still comes from the shared host state. Subsequent unread events are eligible
for a system alert. The local history retains
the latest 300 entries. Pausing or removing a source affects only that device.

The feed stores event IDs, time, host, working directory, Codex session/turn IDs,
and tmux routing metadata. It does not store prompts, tool arguments,
transcripts, or assistant output. Files live under
`~/.local/share/tmuxhub/codex-notifications/`, with private directory/file
permissions. SSH uses the existing TmuxHub connection pool; no incoming network
port or third-party notification service is needed.

## Returning to a terminal

Opening a notification checks the original hostname, tmux socket, server PID,
session creation time, and pane ID before focusing the pane and attaching.
It does not create a replacement tmux session if the original is gone. A tab
previously opened from that session's notifications is reused; otherwise an
attach-only tab is opened. Closing this tab only disconnects it.

Automatic return requires Codex to run inside tmux on the selected host.
Events from plain shells can still appear in history, but have no tmux pane to
open. If a cluster shares the same home directory across login and compute
nodes, events may be visible through the login host while their tmux server
exists on another node. TmuxHub reports that the original terminal is
unavailable rather than attaching to a different machine's pane.

Official interface: [Codex hooks](https://learn.chatgpt.com/docs/hooks).

## Development checks

- `swift run TmuxHubCoreTests --no-parallel`
- `python3 Tests/CodexNotificationBridgeTests.py`
- `zsh scripts/test-codex-notifications-model.sh`

Bridge tests use isolated temporary homes; model tests use separate local
stores and fake deliveries. They do not alter real Codex hooks or request OS
notification permission.
