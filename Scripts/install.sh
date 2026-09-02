#!/bin/bash
# Installs Claudence.app into /Applications.
#
# Installing rather than running from the repository is not cosmetic. Launch at
# login goes through SMAppService, and macOS is entitled to refuse a login item
# for an app living in a build directory; from /Applications the registration
# has a stable path to point at. See Sources/Claudence/App/LaunchAtLogin.swift.
#
# Override the destination with DEST=~/Applications ./Scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Claudence.app"
DEST="${DEST:-/Applications}"
TARGET="$DEST/Claudence.app"
BUNDLE_ID="com.tungao.claudence"

if [ ! -d "$SOURCE" ]; then
    echo "error: $SOURCE does not exist. run 'make app' first." >&2
    exit 1
fi

if [ ! -w "$DEST" ]; then
    echo "error: $DEST is not writable." >&2
    echo "       either run with sudo, or install for this user only:" >&2
    echo "         DEST=~/Applications ./Scripts/install.sh" >&2
    exit 1
fi

# Quit a running copy first. Replacing the bundle underneath a live process
# leaves it running from a deleted inode, so the version on disk and the version
# in the menu bar disagree until the next login.
if pgrep -f "$TARGET/Contents/MacOS/Claudence" >/dev/null 2>&1; then
    echo "quitting the running copy"
    pkill -f "$TARGET/Contents/MacOS/Claudence" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$TARGET/Contents/MacOS/Claudence" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

# Only ever delete a bundle that is actually Claudence. A stray DEST value
# should fail here rather than remove someone else's application.
if [ -e "$TARGET" ]; then
    EXISTING="$(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"
    if [ "$EXISTING" != "$BUNDLE_ID" ]; then
        echo "error: $TARGET exists and is not $BUNDLE_ID (found '${EXISTING:-nothing}')." >&2
        echo "       refusing to replace it. move it aside by hand." >&2
        exit 1
    fi
    rm -rf "$TARGET"
fi

cp -R "$SOURCE" "$TARGET"

# A bundle copied from a download carries the quarantine flag; one built here
# does not. Clear it either way so the first launch is not a Gatekeeper prompt.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

codesign --verify --strict "$TARGET"

echo "installed $TARGET"
echo "open it with: open \"$TARGET\""
