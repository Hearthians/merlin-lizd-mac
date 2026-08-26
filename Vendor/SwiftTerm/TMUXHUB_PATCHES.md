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
