#!/bin/bash
# Assembles Claudence.app from the SPM build product.
# Xcode is not required; only Command Line Tools.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Claudence.app"
BIN="$ROOT/.build/$CONFIG/Claudence"

# A stable signing identity keeps macOS from re-prompting for Keychain access
# on every rebuild. The identity is auto-detected so a plain `make app` picks it
# up; requiring an environment variable meant builds silently fell back to
# ad-hoc and the Keychain grant was lost.
#
# `security find-identity -p codesigning` does NOT list this certificate: it is
# self-signed and therefore not a "valid" identity for that filter. codesign
# still accepts it by name, so detection looks for the certificate itself.
#
# Resolve to a SHA-1 hash rather than the common name. If the certificate was
# ever created twice, codesign refuses the name outright with "ambiguous" and
# the build silently loses its stable identity. A hash is unambiguous.
DEFAULT_IDENTITY="Claudence Dev"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
else
    IDENTITY="$(security find-certificate -a -c "$DEFAULT_IDENTITY" -Z 2>/dev/null \
        | awk '/SHA-1 hash:/ {print $3; exit}')"
    IDENTITY="${IDENTITY:--}"
fi

swift build -c "$CONFIG" --product Claudence

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claudence"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo "warning: ad-hoc signed. macOS will re-prompt for Keychain access after every rebuild."
    echo "         run Scripts/make-signing-cert.sh once to fix this permanently."
else
    echo "signed with: $IDENTITY"
fi
echo "built $APP"
