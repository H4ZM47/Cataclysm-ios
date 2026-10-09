#!/usr/bin/env bash
# Install the simulator build in an iOS Simulator, start a game with scripted
# input and collect screenshots and logs.
#
# Usage: scripts/simulator-smoke-test.sh [path/to/Cataclysm.app] [output-dir]
#
# Environment:
#   SMOKE_DEVICE    simulator device type name to use (default: newest iPhone Pro)
#   SMOKE_SCRIPT    CATA_AUTOPLAY script (default: start a "Play Now" game)
#   SMOKE_TIMEOUT   seconds to wait for the script to finish (default 900)
#
# Exits non-zero if the app crashes or the expected screenshots are missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/iphonesimulator/Release-iphonesimulator/Cataclysm.app}"
OUT="${2:-$ROOT/dist/smoke-test}"
TIMEOUT="${SMOKE_TIMEOUT:-900}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

# Main menu -> New Game -> Play Now! (default scenario), then play a little
# with the touch controls and quicksave. "idle=<s>" waits until nothing was
# drawn for <s> seconds (the main menu after start-up); "wait=DEFAULTMODE"
# waits until the game asks for input in gameplay, i.e. world generation has
# finished.
DEFAULT_SCRIPT="5:idle=8;shot=01-main-menu;text=n;2:shot=02-new-game-menu;text=d"
DEFAULT_SCRIPT+=";wait=DEFAULTMODE;2:shot=03-game-start"
# Swipe right: walk east.
DEFAULT_SCRIPT+=";swipe=0.3,0.5,0.45,0.5;2:shot=04-swipe-move"
# Two-finger tap: inventory. Double tap: back out of it.
DEFAULT_SCRIPT+=";tap2=0.3,0.5;2:shot=05-two-finger-tap-inventory"
DEFAULT_SCRIPT+=";tap=0.3,0.5;0.1:tap=0.3,0.5;2:wait=DEFAULTMODE;shot=06-double-tap-back"
# Game menu, then quicksave from it.
DEFAULT_SCRIPT+=";key=Escape;2:shot=07-game-menu;text=e;5:shot=08-after-quicksave"
DEFAULT_SCRIPT+=";log=autoplay-finished"
SCRIPT="${SMOKE_SCRIPT:-$DEFAULT_SCRIPT}"

pick_device() {
    xcrun simctl list devices available -j | python3 -c '
import json, os, re, sys
want = os.environ.get("SMOKE_DEVICE", "")
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if want and name != want:
            continue
        if not want and not ("iPhone" in name and "Pro" in name and "Max" not in name):
            continue
        key = (version, name)
        if best is None or key > best[0]:
            best = (key, d["udid"], name, runtime)
if best is None:
    sys.exit("no matching simulator found")
print(best[1], best[2], best[3], sep="\t")
'
}

IFS=$'\t' read -r UDID DEVICE_NAME RUNTIME < <(pick_device)
echo "==> Using $DEVICE_NAME ($RUNTIME) $UDID"

xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "==> Installing $APP"
xcrun simctl install "$UDID" "$APP"

echo "==> Launching $BUNDLE_ID"
SIMCTL_CHILD_CATA_AUTOPLAY="$SCRIPT" xcrun simctl launch \
    --stdout="$OUT/stdout.log" --stderr="$OUT/stderr.log" \
    "$UDID" "$BUNDLE_ID"

DATA_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DOCS="$DATA_DIR/Documents"
echo "==> App documents: $DOCS"

app_running() {
    xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE_ID"
}

status=0
start=$SECONDS
while true; do
    if grep -q "autoplay-finished\|\[autoplay\] done" "$OUT/stderr.log" 2>/dev/null; then
        echo "==> Autoplay finished after $((SECONDS - start))s"
        sleep 3
        break
    fi
    if ! app_running; then
        echo "error: the app is no longer running after $((SECONDS - start))s" >&2
        status=1
        break
    fi
    if (( SECONDS - start > TIMEOUT )); then
        echo "error: timed out after ${TIMEOUT}s" >&2
        status=1
        break
    fi
    sleep 5
done

# Host-side screenshot of the whole simulator screen as a cross-check.
xcrun simctl io "$UDID" screenshot "$OUT/simulator-final.png" >/dev/null 2>&1 || true

mkdir -p "$OUT/screenshots" "$OUT/config"
cp -R "$DOCS/autoplay/." "$OUT/screenshots/" 2>/dev/null || true
cp -R "$DOCS/config/." "$OUT/config/" 2>/dev/null || true

# Crash reports for the app, if any.
find ~/Library/Logs/DiagnosticReports -name 'Cataclysm*' -newer "$OUT/stdout.log" \
    -exec cp {} "$OUT/" \; 2>/dev/null || true

echo "==> stderr (tail)"
tail -n 40 "$OUT/stderr.log" || true
echo "==> debug.log"
cat "$OUT/config/debug.log" 2>/dev/null | head -n 150 || echo "(no debug.log)"

shopt -s nullglob
shots=("$OUT"/screenshots/*.png)
echo "==> ${#shots[@]} screenshot(s): $(cd "$OUT/screenshots" && ls)"
for required in 01-main-menu 04-game; do
    if [[ ! -f "$OUT/screenshots/$required.png" ]]; then
        echo "error: missing screenshot $required.png" >&2
        status=1
    fi
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
exit $status
