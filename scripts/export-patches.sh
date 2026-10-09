#!/usr/bin/env bash
# Regenerate ./patches from the commits on branch "ios" in ./cdda.
# Run after committing changes inside ./cdda.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cdda.env
source "$ROOT/cdda.env"
SRC="${CDDA_DIR:-$ROOT/cdda}"

rm -f "$ROOT"/patches/*.patch
git -C "$SRC" format-patch --quiet --no-signature --zero-commit --no-numbered \
    -o "$ROOT/patches" "$CDDA_COMMIT..ios"
ls -1 "$ROOT/patches"
