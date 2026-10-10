#!/usr/bin/env bash
# Publish an unsigned IPA as a GitHub Release, from your own Mac. Nothing runs
# on GitHub Actions: the IPA is built (or taken) locally and uploaded with the
# GitHub CLI.
#
# Usage: scripts/release.sh <tag> [path/to/unsigned.ipa]
#
#   <tag>  tag for the release, e.g. v0.I-1-ios.1. It is created on the commit
#          you have checked out, which must be clean and pushed.
#   IPA    an existing unsigned IPA, e.g. one downloaded from a CI run. Without
#          it the script builds one: it fetches and patches upstream if ./cdda
#          is missing, builds the SDL2 libraries if needed, compiles the
#          translations, builds the device app and packages it.
#
# Environment:
#   RELEASE_DRAFT=1  create the release as a draft, to review before publishing
#   RELEASE_REPO     owner/repo to publish to (default: the repository of the
#                    current checkout, as gh resolves it)
#
# Requires Xcode, CMake and gettext to build, and an authenticated GitHub CLI
# (brew install gh; gh auth login).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cdda.env
source "$ROOT/cdda.env"

TAG="${1:-}"
IPA="${2:-}"
if [[ -z "$TAG" ]]; then
    echo "usage: $0 <tag> [path/to/unsigned.ipa]" >&2
    exit 2
fi

gh_args=()
if [[ -n "${RELEASE_REPO:-}" ]]; then
    gh_args=(--repo "$RELEASE_REPO")
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "error: the GitHub CLI is not installed (brew install gh)" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "error: the GitHub CLI is not logged in (gh auth login)" >&2
    exit 1
fi

cd "$ROOT"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: the working tree has uncommitted changes; commit or stash them first" >&2
    exit 1
fi
COMMIT="$(git rev-parse HEAD)"
if [[ -z "$(git branch -r --contains "$COMMIT")" ]]; then
    echo "error: commit ${COMMIT:0:7} is not on any remote branch; push it first" >&2
    exit 1
fi
if gh release view "$TAG" ${gh_args[@]+"${gh_args[@]}"} >/dev/null 2>&1; then
    echo "error: release $TAG already exists" >&2
    exit 1
fi

if [[ -z "$IPA" ]]; then
    if [[ ! -d cdda/.git ]]; then
        scripts/fetch-cdda.sh
    fi
    # ./cdda must carry exactly the patch series of this commit.
    exported="$(mktemp -d)"
    trap 'rm -rf "$exported"' EXIT
    git -C cdda format-patch --quiet --no-signature --zero-commit --no-numbered \
        -o "$exported" "$CDDA_COMMIT..ios"
    if ! diff -r -q "$exported" patches >/dev/null; then
        echo "error: ./cdda (branch ios) does not match patches/. Run" >&2
        echo "  scripts/export-patches.sh   to keep the changes made in ./cdda, or" >&2
        echo "  scripts/fetch-cdda.sh --force   to rebuild ./cdda from patches/" >&2
        exit 1
    fi
    if [[ ! -f deps/install/iphoneos/lib/libSDL2.a ]]; then
        scripts/build-deps.sh iphoneos
    fi
    scripts/compile-translations.sh
    scripts/build-app.sh iphoneos Release
    IPA="$ROOT/dist/Cataclysm-$CDDA_VERSION_STRING-unsigned.ipa"
    scripts/package-ipa.sh build/iphoneos/Release-iphoneos/Cataclysm.app "$IPA"
fi
if [[ ! -f "$IPA" ]]; then
    echo "error: $IPA does not exist" >&2
    exit 1
fi

# Name the uploaded file after the release.
ASSET="$ROOT/dist/Cataclysm-$TAG-unsigned.ipa"
mkdir -p "$ROOT/dist"
if [[ "$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")" != "$ASSET" ]]; then
    cp -f "$IPA" "$ASSET"
fi
SHA256="$(shasum -a 256 "$ASSET" | cut -d' ' -f1)"

NOTES="$(cat <<EOF
Cataclysm: Dark Days Ahead $CDDA_VERSION_STRING for iPhone and iPad (iOS/iPadOS 15 or later), built from ${COMMIT:0:12}.

The IPA is unsigned. Install it with a sideloading tool that signs it with your Apple ID, such as AltStore or Sideloadly, or build and sign it yourself as described in the README.

SHA-256 of \`$(basename "$ASSET")\`: \`$SHA256\`
EOF
)"

create_args=("$TAG" "$ASSET" --target "$COMMIT"
             --title "Cataclysm: DDA $CDDA_VERSION_STRING for iOS ($TAG)" --notes "$NOTES")
if [[ "${RELEASE_DRAFT:-0}" == 1 ]]; then
    create_args+=(--draft)
fi
echo "==> Creating release $TAG on ${COMMIT:0:12} with $(basename "$ASSET") ($(du -h "$ASSET" | cut -f1))"
gh release create "${create_args[@]}" ${gh_args[@]+"${gh_args[@]}"}
