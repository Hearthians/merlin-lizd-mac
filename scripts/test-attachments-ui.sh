#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
/usr/bin/swift build --target TmuxHubCore
BIN_DIR="$(/usr/bin/swift build --show-bin-path)"
TEST_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tmuxhub-ui-smoke.XXXXXX")"
trap '/bin/rm -rf "$TEST_DIR"' EXIT
/usr/bin/swiftc -swift-version 6 -parse-as-library \
    -I "$BIN_DIR/Modules" \
    Sources/TmuxHubApp/TerminalAttachmentModel.swift \
    Tests/TmuxHubAttachmentSmoke/AttachmentSmoke.swift \
    "$BIN_DIR"/TmuxHubCore.build/*.swift.o \
    -framework AppKit -framework Security \
    -o "$TEST_DIR/AttachmentSmoke"
"$TEST_DIR/AttachmentSmoke"
