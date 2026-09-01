#!/bin/bash
# Assembles Claudence.app from the SPM build product.
# Xcode is not required; only Command Line Tools.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Claudence.app"
BIN="$ROOT/.build/$CONFIG/Claudence"

# A stable signing identity keeps macOS from re-prompting for Keychain access
# on every rebuild. Run Scripts/make-signing-cert.sh once to create one, then
# export CODESIGN_IDENTITY="Claudence Dev". Ad-hoc is the fallback.
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product Claudence

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claudence"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo "warning: ad-hoc signed. macOS will re-prompt for Keychain access after every rebuild."
    echo "         run Scripts/make-signing-cert.sh once, then export CODESIGN_IDENTITY=\"Claudence Dev\""
fi
echo "built $APP"
