#!/usr/bin/env bash
# Compile the upstream .po translations into cdda/lang/mo, which build-app.sh
# bundles into the app. Requires msgfmt (brew install gettext).
#
# Usage: scripts/compile-translations.sh [language...]   (default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CDDA="${CDDA_DIR:-$ROOT/cdda}"

if ! command -v msgfmt >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1 && [[ -x "$(brew --prefix gettext 2>/dev/null)/bin/msgfmt" ]]; then
        PATH="$(brew --prefix gettext)/bin:$PATH"
    else
        echo "error: msgfmt not found; install gettext (brew install gettext)" >&2
        exit 1
    fi
fi

cd "$CDDA"
if (( $# )); then
    sh lang/compile_mo.sh "$@" >/dev/null
else
    sh lang/compile_mo.sh all >/dev/null
fi
echo "==> Compiled $(find lang/mo -name '*.mo' | wc -l | tr -d ' ') translation(s) into $CDDA/lang/mo"
