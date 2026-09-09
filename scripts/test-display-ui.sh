#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
/usr/bin/swift build --target SwiftTerm
BIN_DIR="$(/usr/bin/swift build --show-bin-path)"
TEST_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tmuxhub-display-smoke.XXXXXX")"
trap '/bin/rm -rf "$TEST_DIR"' EXIT
/usr/bin/swiftc -swift-version 6 -parse-as-library \
    -I "$BIN_DIR/Modules" \
    Tests/TmuxHubDisplaySmoke/DisplaySmoke.swift \
    "$BIN_DIR"/SwiftTerm.build/*.swift.o \
    -framework AppKit -framework MetalKit \
    -o "$TEST_DIR/DisplaySmoke"
"$TEST_DIR/DisplaySmoke"
