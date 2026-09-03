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
#
# Distribution changed on 2026-09-03: the app is handed to other people, so a
# Developer ID identity is used when the machine has one and the self-signed
# certificate is the fallback. The account does not exist yet and this script
# must not wait for it, so detection is ordered and silent:
#
#   1. CODESIGN_IDENTITY, when set, wins. It is what CI or a release script
#      would pass.
#   2. A "Developer ID Application" identity in the keychain, which only exists
#      once there is an Apple Developer account.
#   3. The self-signed "Claudence Dev" certificate, for this machine.
#   4. Ad-hoc, which works and re-prompts for Keychain access on every rebuild.
#
# A Developer ID signature also gets the hardened runtime and a secure
# timestamp, because notarisation refuses a signature without them. The
# self-signed path deliberately keeps `--timestamp=none`: a timestamp server
# will not vouch for a certificate no authority issued.
DEFAULT_IDENTITY="Claudence Dev"
SIGN_FLAGS=(--force --timestamp=none)
IDENTITY_KIND="self-signed"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
    IDENTITY_KIND="explicit"
    case "$IDENTITY" in
        *"Developer ID Application"*) IDENTITY_KIND="developer-id" ;;
    esac
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    if [ -n "$IDENTITY" ]; then
        IDENTITY_KIND="developer-id"
    else
        IDENTITY="$(security find-certificate -a -c "$DEFAULT_IDENTITY" -Z 2>/dev/null \
            | awk '/SHA-1 hash:/ {print $3; exit}')"
        IDENTITY="${IDENTITY:--}"
        [ "$IDENTITY" = "-" ] && IDENTITY_KIND="ad-hoc"
    fi
fi

if [ "$IDENTITY_KIND" = "developer-id" ]; then
    SIGN_FLAGS=(--force --options runtime --timestamp)
fi

swift build -c "$CONFIG" --product Claudence

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claudence"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"

case "$IDENTITY_KIND" in
    ad-hoc)
        echo "warning: ad-hoc signed. macOS will re-prompt for Keychain access after every rebuild."
        echo "         run Scripts/make-signing-cert.sh once to fix this permanently."
        ;;
    developer-id)
        echo "signed with Developer ID: $IDENTITY (hardened runtime, secure timestamp)"
        echo "note: notarisation happens in Scripts/make-dmg.sh, on the image rather than the app."
        ;;
    *)
        echo "signed with: $IDENTITY"
        echo "note: self-signed. Gatekeeper on another machine will refuse this build."
        ;;
esac
echo "built $APP"
