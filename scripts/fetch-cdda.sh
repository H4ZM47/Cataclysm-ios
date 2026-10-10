#!/usr/bin/env bash
# Fetch the pinned upstream Cataclysm: DDA revision into ./cdda and apply the
# iOS patch series from ./patches on top of it as individual commits.
#
# Usage: scripts/fetch-cdda.sh [--force]
#   --force  delete an existing ./cdda checkout first
#
# The resulting ./cdda checkout has branch "ios" with one commit per patch, so
# changes can be made there and exported again with scripts/export-patches.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cdda.env
source "$ROOT/cdda.env"
DEST="${CDDA_DIR:-$ROOT/cdda}"

if [[ "${1:-}" == "--force" ]]; then
    rm -rf "$DEST"
fi

GIT=(git -c advice.detachedHead=false -c user.name="cataclysm-ios" -c user.email="cataclysm-ios@localhost")

if [[ ! -d "$DEST/.git" ]]; then
    echo "==> Cloning $CDDA_REPO ($CDDA_REF) into $DEST"
    "${GIT[@]}" clone --depth 1 --branch "$CDDA_REF" "$CDDA_REPO" "$DEST"
else
    echo "==> Reusing existing checkout at $DEST"
fi

actual="$("${GIT[@]}" -C "$DEST" rev-parse "refs/tags/$CDDA_REF^{commit}" 2>/dev/null || true)"
if [[ -z "$actual" ]]; then
    actual="$("${GIT[@]}" -C "$DEST" rev-parse HEAD)"
fi
if [[ "$actual" != "$CDDA_COMMIT" ]]; then
    echo "error: $CDDA_REF resolved to $actual, expected $CDDA_COMMIT" >&2
    exit 1
fi

if "${GIT[@]}" -C "$DEST" rev-parse --verify --quiet refs/heads/ios >/dev/null; then
    echo "==> Branch 'ios' already exists in $DEST; leaving it untouched."
    echo "    Use --force to start over from a clean upstream checkout."
    exit 0
fi

"${GIT[@]}" -C "$DEST" checkout -q -b ios "$CDDA_COMMIT"

shopt -s nullglob
patches=("$ROOT"/patches/*.patch)
if (( ${#patches[@]} )); then
    echo "==> Applying ${#patches[@]} patch(es)"
    "${GIT[@]}" -C "$DEST" am --quiet --whitespace=nowarn --committer-date-is-author-date "${patches[@]}"
fi

# version.h is normally generated from `git describe`, which reports a dirty
# shallow clone poorly. Pin it to the release name instead.
printf '// NOLINT(cata-header-guard)\n#define VERSION "%s-ios"\n' "$CDDA_VERSION_STRING" > "$DEST/src/version.h"

echo "==> Upstream ready at $DEST ($("${GIT[@]}" -C "$DEST" log --oneline "$CDDA_COMMIT"..HEAD | wc -l | tr -d ' ') iOS commit(s) on top of $CDDA_REF)"
