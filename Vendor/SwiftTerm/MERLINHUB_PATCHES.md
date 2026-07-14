# MerlinHub SwiftTerm patches

SwiftTerm is vendored so MerlinHub can keep two small embedding hooks that are
not part of the upstream API. Keep this list narrow when updating the vendor.

## Public read-only selection range

`AppleTerminalView.selectedColumnsRange(row:cols:)` is public. The method was
already used internally by the renderer and still exposes no selection
mutation. `AgentTerminalView` uses the returned range to copy the current
visible selection into immutable Core frame styles.

## Acknowledged local-process writes

`LocalProcess.send(data:completion:)` reports success only after
`DispatchIO.write` accepts the full payload, and reports its POSIX error on
failure. Its completion is guarded so it fires at most once. The original
`send(data:)` API remains source-compatible and delegates to the acknowledged
overload while ignoring the result.

When updating SwiftTerm, reapply only these API changes and verify both the
MerlinLizd fixture suite and a full app build.
