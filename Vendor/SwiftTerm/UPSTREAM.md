# SwiftTerm vendor note

- Upstream: `https://github.com/migueldeicaza/SwiftTerm`
- Version: `v1.14.0`
- License: MIT; see `LICENSE`.

Only the library sources required by this macOS app are retained. The package
resource declaration and `Bundle.module` lookup were removed so `Shaders.metal`
can be copied into the standard app `Contents/Resources` directory and the
finished app can receive a valid strict signature.
