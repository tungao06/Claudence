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

# ---------------------------------------------------------------------------
# Version stamping
#
# Two numbers, and only one of them is a decision.
#
# CFBundleShortVersionString is what a person sees and chooses -- 0.2.0 means
# something about the release and no script can know what. It is edited in
# Resources/Info.plist, or overridden here for one build with MARKETING_VERSION.
#
# CFBundleVersion is bookkeeping: it only has to go up, and it has to differ
# between two builds a friend might both have. It is the commit count, which is
# monotonic, identical for anyone building the same commit, and needs no state
# file that would go stale or dirty the tree. BUILD_NUMBER overrides it.
#
# Stamped into the copy inside the bundle, never back into the source plist, so
# building never modifies the working tree.
# ---------------------------------------------------------------------------
PLIST_BUDDY=/usr/libexec/PlistBuddy
BUNDLE_PLIST="$APP/Contents/Info.plist"

if [ -n "${MARKETING_VERSION:-}" ]; then
    "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$BUNDLE_PLIST"
fi

if [ -n "${BUILD_NUMBER:-}" ]; then
    RESOLVED_BUILD="$BUILD_NUMBER"
elif RESOLVED_BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null) && [ -n "$RESOLVED_BUILD" ]; then
    : # commit count
else
    # Not a git checkout. Leave whatever the source plist says rather than
    # inventing a number that could go backwards.
    RESOLVED_BUILD=""
fi

if [ -n "$RESOLVED_BUILD" ]; then
    "$PLIST_BUDDY" -c "Set :CFBundleVersion $RESOLVED_BUILD" "$BUNDLE_PLIST"
fi

# The exact source this bundle came from, for a problem report sent by hand.
# A dirty tree says so, because "0.1.1 (412)" from a modified checkout is not
# the same software as "0.1.1 (412)" from the commit.
if SOURCE_REVISION=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null); then
    if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
        SOURCE_REVISION="$SOURCE_REVISION-modified"
    fi
    "$PLIST_BUDDY" -c "Add :ClaudenceSourceRevision string $SOURCE_REVISION" "$BUNDLE_PLIST" 2>/dev/null \
        || "$PLIST_BUDDY" -c "Set :ClaudenceSourceRevision $SOURCE_REVISION" "$BUNDLE_PLIST"
fi

STAMPED_SHORT=$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$BUNDLE_PLIST")
STAMPED_BUILD=$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$BUNDLE_PLIST")
echo "version $STAMPED_SHORT ($STAMPED_BUILD)${SOURCE_REVISION:+, source $SOURCE_REVISION}"

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
