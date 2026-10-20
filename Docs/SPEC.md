# TmuxHub Technical Specification

## Scope

The app manages local and arbitrary OpenSSH targets. A remote terminal always
attaches to a tmux or Herdr session. The host mesh adds explicit membership,
directed connectivity checks, onboarding, and two independent throughput tests.
Nested login commands and agent integrations are out of scope.

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

When a user opens an explicit-port HTTP(S) loopback URL from an SSH terminal,
TmuxHub adds an App-owned local forwarding request to that terminal's existing
control master, rewrites the browser URL to the actual local loopback port, and
opens it only after the forwarding request succeeds. Local listeners bind to
`127.0.0.1`; conflicts fall back to another available port. Routes are shared
by matching remote endpoints and removed when their terminal owners or the App
shut down. This reaches the configured SSH host's network namespace, not an
implicit nested SSH host, Slurm node, or container.

Quick connect first selects an existing tab for the destination. When none
exists, it derives one deterministic, bounded tmux session name from the exact
SSH destination. Explicit "new session" actions continue to create a unique
session name.

## Host mesh

SSH catalog entries and the local host are candidates, not enrolled members.
A physical host groups endpoints; each endpoint belongs to an explicit runtime,
account and platform. Windows and WSL have separate SSH identities. Users select
the mesh membership, while all registered hosts retain independent online status.

The persisted reconciliation journal tracks desired membership, runtime public
keys, authenticated host keys, and pending add/revoke tasks. New members receive
bidirectional authorization with existing members. Removal revokes only tagged
TmuxHub mesh keys and managed configuration on both sides, retrying offline sides
later. Management access remains available for health and cleanup. User keys and
existing sessions remain intact.

The Mac's management key is separate from each runtime's mesh key. Private keys
never leave their originating environment. First authentication and trust are
interactive; host keys for other peers come from authenticated management
connections. Managed direct connections use the mesh key, a dedicated known-hosts
file, strict host-key checking, and no implicit proxy. A changed fingerprint or
authentication failure blocks the operation. Campus-to-ZeroTier fallback applies
only to management or direct network failures, not trust/authentication failures.

Endpoint health runs approximately every 30 seconds. Full directed member checks
run independently about every five minutes, without overlapping runs. Sleep,
network changes, missed polling intervals, and restart invalidate current state;
old measurements remain timestamped history. A timeout means unreachable from the
observer, not proof that the machine is powered off.

Every mesh edge executes from its actual source runtime and binds the selected
source IP. The Mac-to-source control channel is excluded from transfer timing.
SSH throughput uses a complete 32 MiB encrypted stream; iperf3 uses a separate
short receiver-measured run. Mbps uses decimal bits per second. Results retain
source/target endpoint snapshots, and partial or unverified measurements do not
become successful metrics. Bandwidth tests require reachable test ports and tools
on both ends. Temporary test listeners are owned and bounded by the test lifecycle.

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
