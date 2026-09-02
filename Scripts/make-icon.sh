#!/bin/bash
# Regenerates Resources/AppIcon.icns from Scripts/make-icon.swift.
#
# The .icns is committed, so a normal build never runs this. Run it only after
# changing the icon's geometry or colours, and commit the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$(mktemp -d)/Claudence.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/AppIcon.icns"

echo "wrote $ROOT/Resources/AppIcon.icns"
