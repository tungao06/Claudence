#!/bin/bash
# Builds an unsigned installer .pkg that drops Claudence.app into /Applications.
#
# Use this when something has to run an install non-interactively; for a normal
# hand-off the .dmg from make-dmg.sh is simpler and shows the user what they are
# copying. The package is unsigned: signing one needs a "Developer ID Installer"
# certificate, which is a paid Apple account, and a self-signed certificate is
# not accepted for installer packages the way it is for application bundles.
#
# Consequence: `installer` from the command line accepts it, and double-clicking
# it on another Mac does not. Install it with:
#
#     sudo installer -pkg Claudence-<version>.pkg -target /
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Claudence.app"

if [ ! -d "$APP" ]; then
    echo "error: $APP does not exist. run 'make app' first." >&2
    exit 1
fi

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
IDENTIFIER="$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"
PKG="$ROOT/Claudence-$VERSION.pkg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/Claudence.app"

rm -f "$PKG"
pkgbuild \
    --root "$STAGE" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location /Applications \
    "$PKG"

echo "built $PKG"
