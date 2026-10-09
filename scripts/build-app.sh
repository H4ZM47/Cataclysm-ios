#!/usr/bin/env bash
# Generate the Xcode project and build Cataclysm.app.
#
# Usage: scripts/build-app.sh [iphoneos|iphonesimulator] [Release|Debug|RelWithDebInfo]
#
# Environment:
#   APP_BUNDLE_ID         bundle identifier (default io.github.h4zm47.cataclysmdda)
#   APP_DEVELOPMENT_TEAM  Apple team ID; when set the app is signed automatically
#   SIMULATOR_ARCHS       simulator architectures (default: this Mac's architecture)
#   EXTRA_CMAKE_ARGS      additional arguments for the CMake configure step
#
# The app ends up in build/<platform>/<config>-<platform>/Cataclysm.app and the
# Xcode project in build/<platform>/CataclysmDDA.xcodeproj, which can also be
# opened directly in Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-iphoneos}"
CONFIG="${2:-Release}"
BUILD_DIR="$ROOT/build/$PLATFORM"

case "$PLATFORM" in
    iphoneos)
        ARCHS="arm64"
        DESTINATION="generic/platform=iOS"
        ;;
    iphonesimulator)
        ARCHS="${SIMULATOR_ARCHS:-$(uname -m)}"
        DESTINATION="generic/platform=iOS Simulator"
        ;;
    *)
        echo "usage: $0 [iphoneos|iphonesimulator] [config]" >&2
        exit 2
        ;;
esac

cmake_args=(
    -S "$ROOT/ios" -B "$BUILD_DIR" -G Xcode
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT="$PLATFORM"
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS"
)
if [[ -n "${APP_BUNDLE_ID:-}" ]]; then
    cmake_args+=(-DAPP_BUNDLE_ID="$APP_BUNDLE_ID")
fi
if [[ -n "${APP_DEVELOPMENT_TEAM:-}" ]]; then
    cmake_args+=(-DAPP_DEVELOPMENT_TEAM="$APP_DEVELOPMENT_TEAM")
fi
# shellcheck disable=SC2206
cmake_args+=(${EXTRA_CMAKE_ARGS:-})

# Optional compiler cache. Xcode has no compiler launcher setting, so point
# CC/CXX at small wrappers that call ccache.
if [[ "${USE_CCACHE:-0}" == 1 ]] && command -v ccache >/dev/null 2>&1; then
    mkdir -p "$BUILD_DIR/ccache-bin"
    for tool in clang clang++; do
        cat > "$BUILD_DIR/ccache-bin/$tool" <<WRAPPER
#!/bin/sh
exec "$(command -v ccache)" "$(xcrun -f "$tool")" "\$@"
WRAPPER
        chmod +x "$BUILD_DIR/ccache-bin/$tool"
    done
    cmake_args+=(
        -DCMAKE_XCODE_ATTRIBUTE_CC="$BUILD_DIR/ccache-bin/clang"
        -DCMAKE_XCODE_ATTRIBUTE_CXX="$BUILD_DIR/ccache-bin/clang++"
        -DCMAKE_XCODE_ATTRIBUTE_LD="$(xcrun -f clang)"
        -DCMAKE_XCODE_ATTRIBUTE_LDPLUSPLUS="$(xcrun -f clang++)"
    )
    export CCACHE_BASEDIR="$ROOT"
    export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-pch_defines,time_macros,include_file_mtime,include_file_ctime,modules,clang_index_store}"
    export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
    echo "==> Using ccache ($(ccache --version | head -1))"
fi

echo "==> Configuring ($PLATFORM, $ARCHS)"
cmake "${cmake_args[@]}"

signing=()
if [[ -z "${APP_DEVELOPMENT_TEAM:-}" ]]; then
    # Unsigned build: install with Xcode, or re-sign the IPA with a
    # sideloading tool (see README).
    signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
else
    signing=(-allowProvisioningUpdates)
fi

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "==> Building $CONFIG with $JOBS jobs"
xcodebuild \
    -project "$BUILD_DIR/CataclysmDDA.xcodeproj" \
    -scheme Cataclysm \
    -configuration "$CONFIG" \
    -sdk "$PLATFORM" \
    -destination "$DESTINATION" \
    -jobs "$JOBS" \
    -quiet \
    COMPILER_INDEX_STORE_ENABLE=NO \
    "${signing[@]}" \
    build

APP="$BUILD_DIR/$CONFIG-$PLATFORM/Cataclysm.app"
if [[ ! -d "$APP" ]]; then
    APP="$(find "$BUILD_DIR" -name Cataclysm.app -type d -path "*$PLATFORM*" -prune | head -1)"
fi
echo "==> Built $APP ($(du -sh "$APP" | cut -f1))"
