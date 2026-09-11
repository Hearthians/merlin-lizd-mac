# TmuxHub Technical Specification

## Scope

The app manages local and arbitrary OpenSSH targets. A remote terminal always
attaches to a tmux session. Platform-specific inventories, nested login
commands, metrics dashboards and agent integrations are out of scope.

## Target model

`TerminalTarget` has two routes:

- `local`
- `ssh(destination)`

An SSH destination is an opaque value accepted by OpenSSH after passing the
local command-boundary validator. Hostname resolution, users, ports, jump hosts,
identity files and proxy commands remain owned by OpenSSH configuration.

## Host discovery

`SSHConfigCatalog` reads concrete `Host` declarations from `~/.ssh/config`,
recursively follows `Include`, expands include globs, prevents cycles and limits
the number and size of files. Wildcard and negated Host patterns are rules rather
than selectable destinations and are omitted. This complete result is a
searchable catalog, not the navigation model. Users may add validated custom
destinations, which are persisted in UserDefaults and pinned by default.

Navigation contains all explicitly pinned destinations plus at most six
unpinned destinations successfully reached during the previous seven days.
Literal IPv4 and IPv6 destinations remain valid connection targets but are
hidden from the library overview unless pinned, recent, searched or explicitly
revealed. Usage history is local; missing catalog/custom destinations are pruned.

## SSH transport

Read-only discovery and tmux mutations use `/usr/bin/ssh` with bounded timeouts.
`SSHMasterPool` maintains App-owned ControlMaster sockets keyed by a hash of the
destination. Concurrent preparations are coalesced; foreground requests take
priority, read-only operations may reconnect and replay once after exit 255,
and mutations never replay automatically.

Authentication remains key-first. A destination may opt into a password
fallback stored as a macOS Keychain generic-password item. For that destination,
OpenSSH tries public-key authentication before keyboard-interactive/password.
The packaged AskPass helper receives the password only through the child-process
environment; it never appears in argv, rendered Terminal.app commands, logs or
SSH configuration. Password fallback uses `StrictHostKeyChecking=accept-new`,
which accepts a host only on first contact and still rejects changed host keys.

Interactive terminals use `ssh -tt` plus the same control socket and run:

```text
exec tmux new-session -A -s <validated-name>
```

Quick connect first selects an existing tab for the destination. When none
exists, it derives one deterministic, bounded tmux session name from the exact
SSH destination. Explicit "new session" actions continue to create a unique
session name.

## Session discovery and identity

Discovery requests:

```text
tmux list-sessions -F#{session_name},#{session_id},#{session_created}
```

The stable identity is the tmux server session ID plus creation epoch. The
editable name is routing/display metadata. Concurrent refreshes for one target
coalesce. Fresh snapshots live for 30 seconds; stale rows remain visible during
reconnect or temporary failures.

## Mutations

Rename resolves identity before mutation and uses the quoted server session ID
when available. It propagates the new name to every matching local tab. Session
termination is explicit and never occurs when merely closing a tab or quitting
the app. Batch termination reports partial success and closes only tabs whose
remote sessions were confirmed terminated.

## Persistence

Validated custom destinations, pinned destinations, successful-use timestamps,
tab titles, session names and stable tmux identities are persisted in
UserDefaults. On first migration, named custom destinations become pins while
literal IP destinations remain unpinned. An existing empty pin set is respected.
Optional SSH passwords are isolated in macOS Keychain under service
`fun.gfyh.tmuxhub.ssh-password`. Private keys, raw SSH config, command output and
ControlPath values are not persisted by TmuxHub.
