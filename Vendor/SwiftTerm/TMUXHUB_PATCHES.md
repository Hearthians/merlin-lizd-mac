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

macOS paste bypasses Kitty keyboard-event encoding even when bracketed paste is
disabled. Encoding an entire pasted string as one key otherwise drops its text
or strips newlines and tabs in report-all-keys modes. The paste path snapshots
the negotiated bracketed-paste mode and sends the optional delimiters with the
unchanged UTF-8 payload in one operation. `scripts/test-paste-ui.sh` covers the
keyboard flag combinations, mode changes, composition, and subsequent typing.

macOS legacy keyboard input maps Control punctuation and digit aliases, including
Control-/, instead of discarding them. Control-Option applies both modifiers;
modified navigation and F1–F12 keys send xterm modifier sequences. Option-arrow
word movement, Shift-page scrollback, and input-method composition remain on
their existing paths. Keys with no legacy Control alias preserve their text.
`scripts/test-keyboard-ui.sh` checks the bytes emitted by the app's terminal view.

Kitty keyboard input identifies Return, Tab, Backspace, and Escape by physical
key code. Printable key identities and shifted alternates use the current
keyboard layout without Control transformation; the US layout is only an
alternate identity. Alternate-key reporting enriches escape-coded events without
turning ordinary shifted typing into escape sequences. The enhanced keyboard
smoke test covers protocol flags, layout changes, composition, and Option text
input (`scripts/test-keyboard-enhanced-ui.sh`).

`LocalProcessTerminalView.requestOpenLink` is declared as an open class method
instead of relying only on the protocol-extension default. TmuxHub overrides it
to route terminal file links into its local-open/remote-download workflow.

`TerminalView.link(at:)` exposes the existing event-to-link lookup, and
`shouldActivateLink(_:with:)` lets the embedding app decline normal link
activation while retaining mouse reporting and selection cleanup. TmuxHub uses
these hooks to require Command + right-click for file links; the default
SwiftTerm activation policy stays unchanged.

Implicit link detection also recognizes bare filenames with alphabetic
extensions, including custom formats, in plain or colorized terminal output.
It reuses the terminal cell mapping for highlighting and click targets, with
URLs and directory paths taking precedence. This filename rule is excluded
from heuristic row joining so separate rows of `ls` output stay separate;
numeric versions and command flags are not treated as filenames.
Actual terminal wraps preserve spaces between columns, so names on either
side of a wrap are not combined into a nonexistent filename.

Slash-separated relative folder paths also become implicit links without a
filename extension, including colorized and parenthesized output. Lookup and
heuristic hard-row joining use separate versions of the same pattern: folder
recognition applies within a line or a real soft wrap, while hard-row joining
keeps the original dotted-path requirement. Command-option fragments remain
excluded from the broader relative-path lookup.

Display changes refresh the pixel-snapped character dimensions when a view is
attached to a window or its backing scale changes. The grid, cursor, and PTY
dimensions are updated together and the full view is redrawn, preventing stale
Retina half-point cell widths on a 1x external monitor. Grid sizing uses the
same scroller-aware calculation as window resizing.

Wide-character continuation cells and insert-mode padding inherit the inserted
character's attributes. The buffer's unused current-attribute copy was stuck at
`Attribute.empty`, whose inverted background exposed white rectangles when a
TUI incrementally replaced the leading half of Chinese text with ASCII/spaces.
Regression tests cover those partial repaints, color/style inheritance, and
wide characters clipped at the right edge in insert mode.

macOS text selection records the mouse-down position and extends from it on the
first drag event. Previously, the first drag position became the start, dropping
any characters or lines crossed before that event. The link UI smoke test checks
the copied text for fast, single-event, reverse, and Shift-bypass drags, while
preserving normal clicks, word/line selection, and remote mouse reporting.

The link UI smoke test also covers the app's selection-first file activation,
hard-wrapped selected paths, spaces at automatic-wrap boundaries, and gesture
cancellation when the selection changes.
