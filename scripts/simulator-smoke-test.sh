#!/usr/bin/env bash
# Install the simulator build in an iOS Simulator, start a game with scripted
# input and collect screenshots and logs.
#
# Usage: scripts/simulator-smoke-test.sh [path/to/Cataclysm.app] [output-dir]
#
# Environment:
#   SMOKE_DEVICE    simulator device name to use (default: see SMOKE_DEVICE_KIND)
#   SMOKE_DEVICE_KIND=iphone|ipad  without SMOKE_DEVICE, use the newest
#                   iPhone Pro (default) or 11-inch iPad
#   SMOKE_SCRIPT    CATA_AUTOPLAY script (default: start a "Play Now" game)
#   SMOKE_TIMEOUT   seconds to wait for the script to finish (default 900)
#   SMOKE_HARDWARE_KEYBOARD=1  test with a hardware keyboard. By default the
#                   app is told there is none, as on a phone, so the quick
#                   shortcuts and the on-screen keyboard are exercised.
#   SMOKE_PRINT_SCREENSHOTS=1  also print small JPEG previews of the
#                   screenshots as base64 to the log, for CI setups where
#                   artifacts are hard to reach
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
# Keyboard button: the terminal makes room for the on-screen keyboard.
DEFAULT_SCRIPT+=";keyboard;3:shot=04-keyboard;keyboard;2:shot=05-keyboard-hidden"
# Swipe right: walk east. Then pass a turn, so there is something to save.
DEFAULT_SCRIPT+=";swipe=0.3,0.5,0.45,0.5;2:shot=06-swipe-move;text=."
# Two-finger tap: inventory. Double tap: back out of it.
DEFAULT_SCRIPT+=";2:tap2=0.3,0.5;2:shot=07-two-finger-tap-inventory"
DEFAULT_SCRIPT+=";tap=0.3,0.5;0.1:tap=0.3,0.5;2:wait=DEFAULTMODE;shot=08-double-tap-back"
# Game menu, then quicksave from it.
DEFAULT_SCRIPT+=";key=Escape;2:shot=09-game-menu;text=e;5:shot=10-after-quicksave"
DEFAULT_SCRIPT+=";log=autoplay-finished"
SCRIPT="${SMOKE_SCRIPT:-$DEFAULT_SCRIPT}"

pick_device() {
    xcrun simctl list devices available -j | python3 -c '
import json, os, re, sys
want = os.environ.get("SMOKE_DEVICE", "")
kind = os.environ.get("SMOKE_DEVICE_KIND", "iphone")
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
        if not want:
            if kind == "ipad":
                suitable = "iPad" in name and "11-inch" in name
            else:
                suitable = "iPhone" in name and "Pro" in name and "Max" not in name
            if not suitable:
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

# On a device the installed bundle is signed and read-only; in the Simulator
# it is writable. Make it read-only so that writes into it fail here too.
INSTALLED_APP="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)"
chmod -R a-w "$INSTALLED_APP"
trap 'chmod -R u+w "$INSTALLED_APP" 2>/dev/null || true' EXIT

echo "==> Launching $BUNDLE_ID"
launch_output="$(SIMCTL_CHILD_CATA_AUTOPLAY="$SCRIPT" \
    SIMCTL_CHILD_CATA_IOS_HARDWARE_KEYBOARD="${SMOKE_HARDWARE_KEYBOARD:-0}" \
    xcrun simctl launch \
    --stdout="$OUT/stdout.log" --stderr="$OUT/stderr.log" \
    "$UDID" "$BUNDLE_ID")"
echo "$launch_output"
# "<bundle id>: <pid>". Simulator apps are ordinary processes on the host.
APP_PID="${launch_output##*: }"
if [[ ! "$APP_PID" =~ ^[0-9]+$ ]]; then
    echo "error: could not read the app's process ID from simctl" >&2
    exit 1
fi

DATA_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DOCS="$DATA_DIR/Documents"
echo "==> App documents: $DOCS"

app_running() {
    kill -0 "$APP_PID" 2>/dev/null
}

autoplay_finished() {
    grep -q "autoplay-finished\|\[autoplay\] done" "$OUT/stderr.log" 2>/dev/null
}

status=0
start=$SECONDS
while true; do
    if autoplay_finished; then
        echo "==> Autoplay finished after $((SECONDS - start))s"
        sleep 3
        if ! app_running; then
            echo "error: the app quit after the script finished" >&2
            status=1
        fi
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
echo "==> Documents"
(cd "$DOCS" && find . -path ./autoplay -prune -o -type f -print | sort | head -n 60) || true

# Crash reports for the app, if any.
find ~/Library/Logs/DiagnosticReports -name 'Cataclysm*' -newer "$OUT/stdout.log" \
    -exec cp {} "$OUT/" \; 2>/dev/null || true
for report in "$OUT"/Cataclysm*.ips; do
    [[ -f "$report" ]] || continue
    echo "==> Crash report $(basename "$report")"
    head -c 20000 "$report"
    echo
done

echo "==> stdout (tail)"
tail -n 40 "$OUT/stdout.log" 2>/dev/null || true
echo "==> stderr (tail)"
tail -n 40 "$OUT/stderr.log" 2>/dev/null || true
echo "==> debug.log"
cat "$OUT/config/debug.log" 2>/dev/null | head -n 150 || echo "(no debug.log)"

shopt -s nullglob
shots=("$OUT"/screenshots/*.png)
echo "==> ${#shots[@]} screenshot(s): $(cd "$OUT/screenshots" && ls)"
if [[ "${SMOKE_PRINT_SCREENSHOTS:-0}" == 1 ]] && (( ${#shots[@]} )); then
    for shot in "${shots[@]}"; do
        name="$(basename "$shot" .png)"
        sips -Z 700 -s format jpeg -s formatOptions 30 "$shot" --out "$OUT/preview-$name.jpg" >/dev/null
        echo "----- BEGIN PREVIEW $name -----"
        base64 -b 120 -i "$OUT/preview-$name.jpg"
        echo "----- END PREVIEW $name -----"
    done
fi
for required in 01-main-menu 03-game-start; do
    if [[ ! -f "$OUT/screenshots/$required.png" ]]; then
        echo "error: missing screenshot $required.png" >&2
        status=1
    fi
done
# Writes into the read-only bundle (or anywhere else not permitted).
if grep -n "Permission denied\|Read-only file system\|Operation not permitted" \
        "$OUT/config/debug.log" 2>/dev/null; then
    echo "error: the game tried to write where it may not (see above)" >&2
    status=1
fi
# The quicksave at the end of the default script writes the character.
if [[ -z "${SMOKE_SCRIPT:-}" && -z "$(find "$DOCS/save" -name '*.sav*' -print -quit 2>/dev/null)" ]]; then
    echo "error: no saved character in $DOCS/save" >&2
    status=1
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
exit $status
