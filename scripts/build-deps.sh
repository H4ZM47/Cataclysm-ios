#!/usr/bin/env bash
# Build the SDL2 libraries Cataclysm needs as static libraries for iOS.
#
# Usage: scripts/build-deps.sh [iphoneos|iphonesimulator]...
#   (default: both)
#
# Output: deps/install/<platform>/{include,lib}
#   lib: libSDL2.a libSDL2main.a libSDL2_ttf.a libSDL2_image.a libSDL2_mixer.a
#        plus the vendored freetype/harfbuzz archives built by SDL2_ttf
#   include: SDL2/*.h and freetype2/ (used by Dear ImGui's FreeType backend)
#
# Requires macOS with Xcode and CMake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
SRC="$DEPS/src"
BUILD="$DEPS/build"
INSTALL="$DEPS/install"

IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"

SDL2_VERSION=2.32.10
SDL2_TTF_VERSION=2.24.0
SDL2_IMAGE_VERSION=2.8.12
SDL2_MIXER_VERSION=2.8.2

platforms=("$@")
if (( ${#platforms[@]} == 0 )); then
    platforms=(iphoneos iphonesimulator)
fi

if command -v ninja >/dev/null 2>&1; then
    GENERATOR=(-G Ninja)
else
    GENERATOR=(-G "Unix Makefiles")
fi
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

fetch() {
    local name="$1" tag="$2" recursive="${3:-}"
    local dest="$SRC/$name-$tag"
    if [[ ! -d "$dest" ]]; then
        echo "==> Fetching $name $tag" >&2
        local args=(clone --quiet --depth 1 --branch "$tag" -c advice.detachedHead=false)
        if [[ -n "$recursive" ]]; then
            args+=(--recurse-submodules --shallow-submodules)
        fi
        git "${args[@]}" "https://github.com/libsdl-org/$name.git" "$dest" >&2
    fi
    echo "$dest"
}

mkdir -p "$SRC"
SDL2_SRC="$(fetch SDL "release-$SDL2_VERSION")"
TTF_SRC="$(fetch SDL_ttf "release-$SDL2_TTF_VERSION" recursive)"
IMAGE_SRC="$(fetch SDL_image "release-$SDL2_IMAGE_VERSION")"
MIXER_SRC="$(fetch SDL_mixer "release-$SDL2_MIXER_VERSION")"

build_one() {
    local platform="$1" name="$2" src="$3"
    shift 3
    local archs
    if [[ "$platform" == "iphonesimulator" ]]; then
        archs="${SIMULATOR_ARCHS:-arm64;x86_64}"
    else
        archs="arm64"
    fi
    local bdir="$BUILD/$platform/$name"
    local prefix="$INSTALL/$platform"
    echo "==> Building $name for $platform ($archs)"
    cmake -S "$src" -B "$bdir" "${GENERATOR[@]}" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES="$archs" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_FIND_ROOT_PATH="$prefix" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL2_DIR="$prefix/lib/cmake/SDL2" \
        "$@" >"$BUILD/$platform-$name-configure.log" 2>&1 \
        || { cat "$BUILD/$platform-$name-configure.log"; return 1; }
    cmake --build "$bdir" --config Release --parallel "$JOBS"
    cmake --install "$bdir" --config Release >/dev/null
}

for platform in "${platforms[@]}"; do
    mkdir -p "$BUILD/$platform"
    prefix="$INSTALL/$platform"

    build_one "$platform" SDL2 "$SDL2_SRC" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL2_DISABLE_SDL2MAIN=OFF

    build_one "$platform" SDL2_ttf "$TTF_SRC" \
        -DSDL2TTF_VENDORED=ON -DSDL2TTF_HARFBUZZ=ON -DSDL2TTF_SAMPLES=OFF \
        -DSDL2TTF_INSTALL=ON

    build_one "$platform" SDL2_image "$IMAGE_SRC" \
        -DSDL2IMAGE_VENDORED=OFF -DSDL2IMAGE_SAMPLES=OFF -DSDL2IMAGE_TESTS=OFF \
        -DSDL2IMAGE_BACKEND_IMAGEIO=OFF -DSDL2IMAGE_BACKEND_STB=ON \
        -DSDL2IMAGE_AVIF=OFF -DSDL2IMAGE_JXL=OFF -DSDL2IMAGE_TIF=OFF -DSDL2IMAGE_WEBP=OFF

    build_one "$platform" SDL2_mixer "$MIXER_SRC" \
        -DSDL2MIXER_VENDORED=OFF -DSDL2MIXER_SAMPLES=OFF \
        -DSDL2MIXER_VORBIS=STB -DSDL2MIXER_OPUS=OFF -DSDL2MIXER_MOD=OFF \
        -DSDL2MIXER_MIDI=OFF -DSDL2MIXER_FLAC=ON -DSDL2MIXER_FLAC_DRFLAC=ON \
        -DSDL2MIXER_MP3=ON -DSDL2MIXER_MP3_MINIMP3=ON -DSDL2MIXER_WAVPACK=OFF \
        -DSDL2MIXER_GME=OFF

    # Dear ImGui's FreeType rasterizer includes <ft2build.h>; reuse the
    # FreeType that SDL2_ttf vendors so both link against the same library.
    rm -rf "$prefix/include/freetype2"
    mkdir -p "$prefix/include/freetype2"
    cp -R "$TTF_SRC/external/freetype/include/." "$prefix/include/freetype2/"

    # The vendored freetype/harfbuzz static archives are not always installed;
    # copy them out of the build tree so the app can link them.
    while IFS= read -r -d '' lib; do
        cp -f "$lib" "$prefix/lib/"
    done < <(find "$BUILD/$platform/SDL2_ttf" -name 'lib*.a' -print0)

    echo "==> $platform libraries:"
    ls -1 "$prefix/lib"/*.a
done
