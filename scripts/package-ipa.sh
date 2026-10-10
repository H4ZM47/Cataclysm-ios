#!/usr/bin/env bash
# Package a built Cataclysm.app into an unsigned .ipa for sideloading.
#
# Usage: scripts/package-ipa.sh [path/to/Cataclysm.app] [output.ipa]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/iphoneos/Release-iphoneos/Cataclysm.app}"
# shellcheck source=../cdda.env
source "$ROOT/cdda.env"
OUT="${2:-$ROOT/dist/Cataclysm-$CDDA_VERSION_STRING-unsigned.ipa}"

if [[ ! -f "$APP/Info.plist" ]]; then
    echo "error: $APP is not a built app bundle" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
# ditto keeps symlinks, permissions and extended attributes intact.
ditto "$APP" "$STAGE/Payload/Cataclysm.app"
rm -f "$OUT"
(cd "$STAGE" && ditto -c -k --sequesterRsrc --keepParent Payload "$OUT.zip" && mv "$OUT.zip" "$OUT")
echo "==> Wrote $OUT ($(du -h "$OUT" | cut -f1))"

# Check the archive has the layout installers expect and a device executable.
listing="$(unzip -Z1 "$OUT")"
missing=0
for prefix in Payload/Cataclysm.app/Info.plist Payload/Cataclysm.app/Cataclysm \
              Payload/Cataclysm.app/data/json/ Payload/Cataclysm.app/gfx/ \
              Payload/Cataclysm.app/android/joystick.png; do
    if ! grep -qF -- "$prefix" <<<"$listing"; then
        echo "error: $prefix is missing from $OUT" >&2
        missing=1
    fi
done
archs="$(lipo -archs "$APP/Cataclysm")"
if [[ " $archs " != *" arm64 "* ]]; then
    echo "error: the executable is built for '$archs', not arm64" >&2
    missing=1
fi
(( missing == 0 )) || exit 1
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null || echo "?"; }
echo "==> $(plist CFBundleIdentifier) $(plist CFBundleShortVersionString) ($(plist CFBundleVersion)), $archs, iOS $(plist MinimumOSVersion)+, $(grep -c . <<<"$listing") entries"
