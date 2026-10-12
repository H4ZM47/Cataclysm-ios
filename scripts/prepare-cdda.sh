#!/usr/bin/env bash
# Make sure ./cdda holds upstream with exactly the patch series in patches/:
# fetch it if it is missing, and stop if it differs (for example because of
# changes made in ./cdda that were not exported).
#
# Usage: scripts/prepare-cdda.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cdda.env
source "$ROOT/cdda.env"
CDDA="${CDDA_DIR:-$ROOT/cdda}"

if [[ ! -d "$CDDA/.git" ]]; then
    "$ROOT/scripts/fetch-cdda.sh"
fi

exported="$(mktemp -d)"
trap 'rm -rf "$exported"' EXIT
git -C "$CDDA" format-patch --quiet --no-signature --zero-commit --no-numbered \
    -o "$exported" "$CDDA_COMMIT..ios"
if ! diff -r -q "$exported" "$ROOT/patches" >/dev/null; then
    echo "error: $CDDA (branch ios) does not match patches/. Run" >&2
    echo "  scripts/export-patches.sh   to keep the changes made in ./cdda, or" >&2
    echo "  scripts/fetch-cdda.sh --force   to rebuild ./cdda from patches/" >&2
    exit 1
fi
echo "==> $CDDA matches patches/"
