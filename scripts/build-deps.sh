#!/usr/bin/env bash
# Build the SDL3 libraries Cataclysm needs as static libraries for iOS.
#
# Usage: scripts/build-deps.sh [iphoneos|iphonesimulator]...
#   (default: both)
#
# Output: deps/install/<platform>/{include,lib}
#   lib: libSDL3.a libSDL3_ttf.a libSDL3_image.a libSDL3_mixer.a
#        plus the vendored freetype/harfbuzz archives built by SDL3_ttf
#   include: SDL3/*.h and freetype2/ (used by Dear ImGui's FreeType backend)
#
# Requires macOS with Xcode and CMake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
SRC="$DEPS/src"
BUILD="$DEPS/build"
INSTALL="$DEPS/install"

IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"

SDL3_VERSION=3.4.0
SDL3_TTF_VERSION=3.2.2
SDL3_IMAGE_VERSION=3.2.4
SDL3_MIXER_VERSION=3.2.0

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
SDL3_SRC="$(fetch SDL "release-$SDL3_VERSION")"
TTF_SRC="$(fetch SDL_ttf "release-$SDL3_TTF_VERSION" recursive)"
IMAGE_SRC="$(fetch SDL_image "release-$SDL3_IMAGE_VERSION")"
MIXER_SRC="$(fetch SDL_mixer "release-$SDL3_MIXER_VERSION")"

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
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DSDL3_DIR="$prefix/lib/cmake/SDL3" \
        "$@" >"$BUILD/$platform-$name-configure.log" 2>&1 \
        || { cat "$BUILD/$platform-$name-configure.log"; return 1; }
    cmake --build "$bdir" --config Release --parallel "$JOBS"
    cmake --install "$bdir" --config Release >/dev/null
}

for platform in "${platforms[@]}"; do
    mkdir -p "$BUILD/$platform"
    prefix="$INSTALL/$platform"

    build_one "$platform" SDL3 "$SDL3_SRC" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_INSTALL=ON

    build_one "$platform" SDL3_ttf "$TTF_SRC" \
        -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=ON -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_INSTALL=ON \
        -DSDLTTF_SAMPLES=OFF

    build_one "$platform" SDL3_image "$IMAGE_SRC" \
        -DSDLIMAGE_VENDORED=OFF -DSDLIMAGE_INSTALL=ON -DSDLIMAGE_SAMPLES=OFF -DSDLIMAGE_TESTS=OFF \
        -DSDLIMAGE_BACKEND_IMAGEIO=OFF -DSDLIMAGE_BACKEND_STB=ON \
        -DSDLIMAGE_AVIF=OFF -DSDLIMAGE_JXL=OFF -DSDLIMAGE_TIF=OFF -DSDLIMAGE_WEBP=OFF

    build_one "$platform" SDL3_mixer "$MIXER_SRC" \
        -DSDLMIXER_VENDORED=OFF -DSDLMIXER_INSTALL=ON -DSDLMIXER_EXAMPLES=OFF -DSDLMIXER_TESTS=OFF \
        -DSDLMIXER_VORBIS_STB=ON -DSDLMIXER_VORBIS_VORBISFILE=OFF \
        -DSDLMIXER_OPUS=OFF -DSDLMIXER_MOD=OFF -DSDLMIXER_MIDI=OFF \
        -DSDLMIXER_FLAC=ON -DSDLMIXER_FLAC_LIBFLAC=OFF -DSDLMIXER_FLAC_DRFLAC=ON \
        -DSDLMIXER_MP3=ON -DSDLMIXER_MP3_DRMP3=ON -DSDLMIXER_MP3_MPG123=OFF \
        -DSDLMIXER_WAVPACK=OFF -DSDLMIXER_GME=OFF

    # Dear ImGui's FreeType rasterizer includes <ft2build.h>; reuse the
    # FreeType that SDL3_ttf vendors so both link against the same library.
    rm -rf "$prefix/include/freetype2"
    mkdir -p "$prefix/include/freetype2"
    cp -R "$TTF_SRC/external/freetype/include/." "$prefix/include/freetype2/"

    # The vendored freetype/harfbuzz static archives are not always installed;
    # copy them out of the build tree so the app can link them.
    while IFS= read -r -d '' lib; do
        cp -f "$lib" "$prefix/lib/"
    done < <(find "$BUILD/$platform/SDL3_ttf" -name 'lib*.a' -print0)

    echo "==> $platform libraries:"
    ls -1 "$prefix/lib"/*.a
done
