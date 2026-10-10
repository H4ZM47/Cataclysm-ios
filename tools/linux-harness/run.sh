#!/usr/bin/env bash
# Run the Linux harness build with the same file layout as the iOS app bundle.
#
# Usage: tools/linux-harness/run.sh [--headless] [--size WxH] [--user-dir DIR]
#
#   --headless      run in a virtual X server (Xvfb) instead of on $DISPLAY
#   --size WxH      screen size in pixels (default 2622x1206, an iPhone 16 Pro
#                   in landscape); also the Xvfb screen size
#   --user-dir DIR  writable user directory (default build/harness-user)
#
# Combine with CATA_AUTOPLAY (see ios/src/ios_autoplay.cpp) for scripted runs;
# screenshots end up in <user-dir>/autoplay. CATA_HARNESS_* variables (see
# ios_platform_harness.cpp) tune the simulated safe area, keyboard and scale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/harness/cataclysm-ios-harness"
CDDA="${CDDA_DIR:-$ROOT/cdda}"
HEADLESS=0
SIZE=2622x1206
USER_DIR="$ROOT/build/harness-user"

while (( $# )); do
    case "$1" in
        --headless) HEADLESS=1 ;;
        --size) SIZE="$2"; shift ;;
        --user-dir) USER_DIR="$2"; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ ! -x "$BIN" ]]; then
    echo "error: build the harness first: cmake -S tools/linux-harness -B build/harness && cmake --build build/harness" >&2
    exit 1
fi

# The app bundle holds data/, gfx/, lang/ and android/joystick.png side by side.
BUNDLE="$ROOT/build/harness-bundle"
mkdir -p "$BUNDLE" "$USER_DIR"
USER_DIR="$(cd "$USER_DIR" && pwd)"
ln -sfn "$CDDA/data" "$BUNDLE/data"
ln -sfn "$CDDA/gfx" "$BUNDLE/gfx"
ln -sfn "$CDDA/lang" "$BUNDLE/lang"
ln -sfn "$CDDA/android/app/src/main/assets/android" "$BUNDLE/android"

export CATA_HARNESS_RESOURCE_DIR="$BUNDLE/"
export CATA_HARNESS_USER_DIR="${USER_DIR%/}/"
export LANG="${LANG:-en_US.UTF-8}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"

cd "$BUNDLE"
if (( HEADLESS )); then
    display=":$(( 90 + RANDOM % 9 ))"
    Xvfb "$display" -screen 0 "${SIZE}x24" -nolisten tcp >/dev/null 2>&1 &
    xvfb_pid=$!
    trap 'kill $xvfb_pid 2>/dev/null || true' EXIT
    sleep 1
    DISPLAY="$display" "$BIN"
else
    "$BIN"
fi
