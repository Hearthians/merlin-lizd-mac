# TmuxHub SwiftTerm patches

SwiftTerm is vendored to keep the macOS app self-contained. The local package
layout places `Shaders.metal` in the standard app resources directory so a
packaged build can load it and pass strict code-signature verification.

The vendor also retains two narrow upstream-compatible API additions from the
earlier embedding work:

- a public read-only selection-range accessor;
- an acknowledged `LocalProcess.send(data:completion:)` overload.

TmuxHub does not currently depend on those two APIs, but keeping them
avoids an unrelated vendor rewrite in this branch. When updating SwiftTerm,
prefer a clean upstream version plus only the shader packaging adjustment if
the upstream APIs and resource layout make these patches unnecessary.

Attachment support adds `TerminalView.pasteText(_:)`, which uses SwiftTerm's
existing paste path (including bracketed paste) without changing the system
clipboard. `keyDown(with:)` and `resignFirstResponder()` are made `open` so the
app's subclass can invalidate pending automatic attachment insertion when the
user types or moves focus. These methods otherwise retain upstream behavior.

`LocalProcessTerminalView.requestOpenLink` is declared as an open class method
instead of relying only on the protocol-extension default. TmuxHub overrides it
to route terminal file links into its local-open/remote-download workflow.

Display changes refresh the pixel-snapped character dimensions when a view is
attached to a window or its backing scale changes. The grid, cursor, and PTY
dimensions are updated together and the full view is redrawn, preventing stale
Retina half-point cell widths on a 1x external monitor. Grid sizing uses the
same scroller-aware calculation as window resizing.
