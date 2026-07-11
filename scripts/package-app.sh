#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_NAME="MerlinLizd"
APP_NAME="Merlin Lizd"
DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
INFO_PLIST="$PROJECT_ROOT/Packaging/Info.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 "error: packaging Merlin Lizd requires macOS"
    exit 1
fi

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

cd "$PROJECT_ROOT"
/usr/bin/swift build -c release --product "$PRODUCT_NAME"
BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE" ]]; then
    print -u2 "error: release executable not found at $EXECUTABLE"
    exit 1
fi

STAGING_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/merlin-lizd-package.XXXXXX")"
trap '/bin/rm -rf "$STAGING_ROOT"' EXIT

STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
CONTENTS="$STAGED_APP/Contents"
/bin/mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
/usr/bin/install -m 0755 "$EXECUTABLE" "$CONTENTS/MacOS/$PRODUCT_NAME"
/usr/bin/install -m 0644 "$INFO_PLIST" "$CONTENTS/Info.plist"
/usr/bin/install -m 0644 \
    "$PROJECT_ROOT/Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal" \
    "$CONTENTS/Resources/Shaders.metal"
/usr/bin/install -m 0644 \
    "$PROJECT_ROOT/Assets/AppIcon.icns" \
    "$CONTENTS/Resources/AppIcon.icns"

# The vendored SwiftTerm build reads its shader from Bundle.main, so the app can
# use the standard resource layout and receive a valid local ad-hoc signature.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

/bin/mkdir -p "$DIST_DIR"
/bin/rm -rf "$APP_PATH"
/usr/bin/ditto "$STAGED_APP" "$APP_PATH"

print "Packaged: $APP_PATH"
print "Open with: open '$APP_PATH'"
