# MerlinHub SwiftTerm patches

SwiftTerm is vendored so MerlinHub can keep two small embedding hooks that are
not part of the upstream API. Keep this list narrow when updating the vendor.

## Public read-only selection range

`AppleTerminalView.selectedColumnsRange(row:cols:)` is public. The method was
already used internally by the renderer and still exposes no selection
mutation. `AgentTerminalView` uses the returned range to copy the current
visible selection into immutable Core frame styles.

## Acknowledged local-process writes

`LocalProcess.send(data:completion:)` reports success only after the existing
stream `DispatchIO` channel accepts the full payload, and reports its POSIX
error on failure. The PTY file descriptor is already owned by that channel, so
the acknowledged overload must use `io.write`; the static
`DispatchIO.write(toFileDescriptor:)` convenience API can strand its completion
when another channel already manages the descriptor. A missing channel fails
with `EPIPE`, and success is reported only when the channel says the operation
is done with no remaining bytes. Its completion is guarded so it fires at most
once, and the real channel result is delivered on the `LocalProcess` callback
queue so terminal delegates do not receive an I/O-queue callback. The original
`send(data:)` API remains source-compatible and delegates to the acknowledged
overload while ignoring the result.

When updating SwiftTerm, reapply only these API changes and verify both the
MerlinLizd fixture suite and a full app build.
