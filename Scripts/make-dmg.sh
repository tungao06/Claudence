#!/bin/bash
# Packages Claudence.app into a .dmg that opens as the familiar install window:
# the app on the left, an Applications alias on the right, an arrow between
# them, on a background drawn by Scripts/make-dmg-art.swift.
#
# How the layout is applied: a read-write image is created, mounted, arranged
# through Finder over AppleScript, unmounted, and only then compressed to the
# read-only image that ships. The arrangement lives in the volume's .DS_Store,
# and there is no way to write that file except by having Finder write it.
#
# Consequence worth knowing before the first run: driving Finder needs
# Automation permission, so macOS will ask once whether this terminal may
# control Finder. Refusing is not fatal. The script says so and continues, and
# the image still installs correctly; it just opens with Finder's default
# layout instead of the arranged one.
#
# Notarisation, since 2026-09-03: the image is notarised when this machine can,
# and is not when it cannot, and the script says which happened either way. It
# needs two things, both absent until there is an Apple Developer account:
#
#   - the app inside signed with a Developer ID identity and the hardened
#     runtime, which Scripts/make-app.sh does by itself when one exists;
#   - notarytool credentials stored as a keychain profile, created once with
#     `xcrun notarytool store-credentials <name> --apple-id ... --team-id ...`
#     and named here through NOTARY_PROFILE, defaulting to "claudence".
#
# Without them the image still builds and still installs. What the receiving
# user meets is Gatekeeper refusing the first launch, so they have to
# right-click the app and choose Open, or run:
#
#     xattr -dr com.apple.quarantine /Applications/Claudence.app
#
# Say so when handing an un-notarised image to someone rather than letting them
# meet the dialog cold.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Claudence.app"

if [ ! -d "$APP" ]; then
    echo "error: $APP does not exist. run 'make app' first." >&2
    exit 1
fi

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
VOLUME="Claudence $VERSION"
DMG="$ROOT/Claudence-$VERSION.dmg"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
MOUNT=""
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ] && hdiutil info | grep -q "$DEVICE"; then
        hdiutil detach "$DEVICE" -force -quiet 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- what goes in the image -------------------------------------------------

mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Claudence.app"
ln -s /Applications "$STAGE/Applications"

swift "$ROOT/Scripts/make-dmg-art.swift" "$STAGE/.background" >/dev/null

# One multi-resolution TIFF rather than two PNGs: Finder picks the 2x
# representation on a Retina display only if both live in a single file.
tiffutil -cathidpicheck \
    "$STAGE/.background/background.png" \
    "$STAGE/.background/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
rm -f "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

# --- a writable image, so Finder can arrange it ------------------------------

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))

rm -f "$RW"
hdiutil create \
    -srcfolder "$STAGE" \
    -volname "$VOLUME" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_MB}m" \
    -quiet \
    "$RW"

ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEVICE="$(echo "$ATTACH" | grep '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="$(echo "$ATTACH" | grep -o '/Volumes/.*' | head -1)"

if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    echo "error: the image mounted but no mount point was reported." >&2
    exit 1
fi

# The name Finder answers to is the mounted volume's, which is not necessarily
# $VOLUME: a volume of that name already mounted makes macOS append a number.
MOUNTED_NAME="$(basename "$MOUNT")"


# --- the arrangement ---------------------------------------------------------
#
# The icon centres here and the arrow drawn in Scripts/make-dmg-art.swift
# describe the same 600 x 400 window. Move one and the other has to move.

if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "$MOUNTED_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 180, 1000, 580}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.tiff"
        set position of item "Claudence.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "arranged the install window"
else
    echo "warning: could not drive Finder, so the image keeps the default layout."
    echo "         this is usually Automation permission: System Settings ->"
    echo "         Privacy & Security -> Automation, allow this terminal to"
    echo "         control Finder, then run 'make dmg' again."
fi

# The volume's own icon, on the desktop and in Finder's sidebar. Written after
# the arrangement, not before: Finder removes the file while it is rearranging
# the window, so a copy made earlier is silently absent from the finished image.
# The C attribute is what makes the file take effect; without it the icns sits
# there inert.
cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true

# Finder writes .DS_Store lazily. Without the flush the arrangement is
# sometimes still in memory when the volume is detached, and the shipped image
# opens unarranged for no visible reason.
sync

for _ in 1 2 3 4 5 6 7 8 9 10; do
    if hdiutil detach "$DEVICE" -quiet 2>/dev/null; then
        DEVICE=""
        break
    fi
    sleep 1
done
if [ -n "$DEVICE" ]; then
    hdiutil detach "$DEVICE" -force -quiet
    DEVICE=""
fi

# --- the image that ships ----------------------------------------------------

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet

# --- notarisation, when this machine can ------------------------------------
#
# Ordered so that a machine with no account does nothing slow and says nothing
# alarming: the app's own signature is read first, and only a Developer ID
# signature is worth submitting. `notarytool submit --wait` blocks for as long
# as Apple takes, which is usually a minute or two, and `stapler staple` writes
# the ticket into the image so a machine with no network still launches it.
NOTARY_PROFILE="${NOTARY_PROFILE:-claudence}"
APP_AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F'=' '/Authority=/ {print $2; exit}')"

if [[ "$APP_AUTHORITY" != *"Developer ID Application"* ]]; then
    echo "not notarised: $APP is not signed with a Developer ID identity."
    echo "               receiving users must right-click Open, or clear the quarantine flag."
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "not notarised: no notarytool credentials in keychain profile '$NOTARY_PROFILE'."
    echo "               create them once with: xcrun notarytool store-credentials $NOTARY_PROFILE"
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'\"' '/Developer ID Application/ {print $2; exit}')"
    # The image carries its own signature as well as the app's. Notarisation
    # accepts an unsigned image, but a signed one tells the user who built it
    # before it is ever opened.
    [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    echo "notarising $DMG ..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "notarised and stapled."
fi

echo "built $DMG"
