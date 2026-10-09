# Xcode project for Cataclysm: Dark Days Ahead on iOS / iPadOS.
#
# Configure (see scripts/build-app.sh):
#   cmake -S ios -B build/iphoneos -G Xcode \
#         -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
#
# Expects:
#   ../cdda               upstream checkout with patches/ applied (scripts/fetch-cdda.sh)
#   ../deps/install/<sdk> SDL2 libraries built by scripts/build-deps.sh
cmake_minimum_required(VERSION 3.24)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "Configure with -DCMAKE_SYSTEM_NAME=iOS")
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum iOS version")
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "" FORCE)
endif()

project(CataclysmDDA LANGUAGES C CXX OBJC OBJCXX)

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(CDDA_DIR "${REPO_ROOT}/cdda" CACHE PATH "Patched Cataclysm-DDA checkout")
set(DEPS_INSTALL_DIR "${REPO_ROOT}/deps/install" CACHE PATH "Output of scripts/build-deps.sh")

# iphoneos or iphonesimulator, from -DCMAKE_OSX_SYSROOT (which CMake may have
# resolved to an SDK path such as .../iPhoneSimulator18.2.sdk).
string(TOLOWER "${CMAKE_OSX_SYSROOT}" _sysroot_lower)
if(_sysroot_lower MATCHES "iphonesimulator")
    set(IOS_PLATFORM iphonesimulator)
else()
    set(IOS_PLATFORM iphoneos)
endif()
set(DEPS_PREFIX "${DEPS_INSTALL_DIR}/${IOS_PLATFORM}")
if(NOT EXISTS "${DEPS_PREFIX}/lib/libSDL2.a")
    message(FATAL_ERROR "SDL2 for ${IOS_PLATFORM} not found in ${DEPS_PREFIX}; run scripts/build-deps.sh ${IOS_PLATFORM}")
endif()
if(NOT EXISTS "${CDDA_DIR}/src/main.cpp")
    message(FATAL_ERROR "Cataclysm sources not found in ${CDDA_DIR}; run scripts/fetch-cdda.sh")
endif()

# Read the pinned upstream version.
file(STRINGS "${REPO_ROOT}/cdda.env" _cdda_env REGEX "^CDDA_VERSION_STRING=")
string(REGEX REPLACE "^CDDA_VERSION_STRING=" "" CDDA_VERSION_STRING "${_cdda_env}")
# CFBundleShortVersionString must be numeric: 0.I-1 -> 0.9.1 (I is the 9th letter).
string(REGEX MATCH "^0\\.([A-Z])(-([0-9]+))?" _ver_match "${CDDA_VERSION_STRING}")
if(_ver_match)
    string(FIND "@ABCDEFGHIJKLMNOPQRSTUVWXYZ" "${CMAKE_MATCH_1}" _letter_index)
    set(_point "${CMAKE_MATCH_3}")
    if(_point STREQUAL "")
        set(_point 0)
    endif()
    set(_default_marketing_version "0.${_letter_index}.${_point}")
else()
    set(_default_marketing_version "0.0.0")
endif()

set(APP_BUNDLE_ID "io.github.h4zm47.cataclysmdda" CACHE STRING "CFBundleIdentifier")
set(APP_DEVELOPMENT_TEAM "" CACHE STRING "Apple developer team ID used for automatic signing (empty: sign manually or not at all)")
set(APP_MARKETING_VERSION "${_default_marketing_version}" CACHE STRING "CFBundleShortVersionString")
set(APP_BUILD_NUMBER "1" CACHE STRING "CFBundleVersion")
option(APP_BUNDLE_TRANSLATIONS "Bundle compiled translations from cdda/lang/mo if present" ON)
option(APP_INCREASED_MEMORY_LIMIT
    "Request the increased memory limit entitlement (the signing team must have this capability)" OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_XCODE_GENERATE_SCHEME ON)
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# ---------------------------------------------------------------------------
# Upstream sources
# ---------------------------------------------------------------------------
set(SRC "${CDDA_DIR}/src")
file(GLOB CDDA_SOURCES CONFIGURE_DEPENDS "${SRC}/*.cpp")
file(GLOB FLATBUFFERS_SOURCES CONFIGURE_DEPENDS "${SRC}/third-party/flatbuffers/*.cpp")
file(GLOB ZSTD_SOURCES CONFIGURE_DEPENDS
    "${SRC}/third-party/zstd/common/*.c"
    "${SRC}/third-party/zstd/compress/*.c"
    "${SRC}/third-party/zstd/decompress/*.c")
file(GLOB IMGUI_SOURCES CONFIGURE_DEPENDS "${SRC}/third-party/imgui/*.cpp")
set(IOS_PLATFORM_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_platform.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_platform.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_autoplay.cpp")

set(CDDA_DEFINITIONS
    TILES
    SDL_SOUND
    LOCALIZE
    BACKTRACE
    RELEASE
    CATA_IOS
    ZSTD_STATIC_LINKING_ONLY
    ZSTD_DISABLE_ASM)

set(CDDA_INCLUDE_DIRS
    "${SRC}"
    "${SRC}/third-party"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${DEPS_PREFIX}/include"
    "${DEPS_PREFIX}/include/SDL2"
    "${DEPS_PREFIX}/include/freetype2")

# Third-party code is compiled warning-free in its own static libraries.
add_library(cdda-third-party STATIC ${FLATBUFFERS_SOURCES} ${ZSTD_SOURCES} ${IMGUI_SOURCES})
target_compile_definitions(cdda-third-party PRIVATE ${CDDA_DEFINITIONS})
target_include_directories(cdda-third-party PRIVATE ${CDDA_INCLUDE_DIRS})
target_compile_options(cdda-third-party PRIVATE -w -fsigned-char)

add_executable(Cataclysm MACOSX_BUNDLE
    ${CDDA_SOURCES}
    ${IOS_PLATFORM_SOURCES}
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.xcassets")
target_compile_definitions(Cataclysm PRIVATE ${CDDA_DEFINITIONS})
target_include_directories(Cataclysm PRIVATE ${CDDA_INCLUDE_DIRS})
target_compile_options(Cataclysm PRIVATE
    -fsigned-char
    $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-deprecated-declarations>)

# ---------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------
set(DEPS_LIBS
    "${DEPS_PREFIX}/lib/libSDL2main.a"
    "${DEPS_PREFIX}/lib/libSDL2_ttf.a"
    "${DEPS_PREFIX}/lib/libSDL2_image.a"
    "${DEPS_PREFIX}/lib/libSDL2_mixer.a")
foreach(_vendored freetype harfbuzz)
    file(GLOB _vendored_lib "${DEPS_PREFIX}/lib/lib${_vendored}*.a")
    list(APPEND DEPS_LIBS ${_vendored_lib})
endforeach()
list(APPEND DEPS_LIBS "${DEPS_PREFIX}/lib/libSDL2.a")

target_link_libraries(Cataclysm PRIVATE
    cdda-third-party
    ${DEPS_LIBS}
    z
    iconv
    "-framework AVFoundation"
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework CoreBluetooth"
    "-framework CoreFoundation"
    "-framework CoreGraphics"
    "-framework CoreHaptics"
    "-framework CoreMotion"
    "-framework CoreVideo"
    "-framework Foundation"
    "-framework GameController"
    "-framework ImageIO"
    "-framework Metal"
    "-framework OpenGLES"
    "-framework QuartzCore"
    "-framework UIKit")

# ---------------------------------------------------------------------------
# App bundle
# ---------------------------------------------------------------------------
set_target_properties(Cataclysm PROPERTIES
    OUTPUT_NAME "Cataclysm"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    RESOURCE "${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.xcassets"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${APP_BUNDLE_ID}"
    XCODE_ATTRIBUTE_MARKETING_VERSION "${APP_MARKETING_VERSION}"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${APP_BUILD_NUMBER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "${CMAKE_OSX_DEPLOYMENT_TARGET}"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    XCODE_ATTRIBUTE_INFOPLIST_PREPROCESS "NO"
    XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++17"
    XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
    XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL[variant=Release] "2"
    XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL[variant=RelWithDebInfo] "2"
    XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT "dwarf"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
    XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING "YES"
    XCODE_ATTRIBUTE_COPY_PHASE_STRIP "NO"
    XCODE_ATTRIBUTE_ENABLE_USER_SCRIPT_SANDBOXING "NO"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${APP_DEVELOPMENT_TEAM}")
if(APP_INCREASED_MEMORY_LIMIT)
    set_target_properties(Cataclysm PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/resources/Cataclysm.entitlements")
endif()
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

# Game data is copied into the bundle as plain folders, which is where
# PATH_INFO looks for it (see ios_platform.mm / main.cpp):
#   Cataclysm.app/data, Cataclysm.app/gfx, Cataclysm.app/lang/mo
set(_bundle_dir "$<TARGET_BUNDLE_CONTENT_DIR:Cataclysm>")
set(_copy_cmds
    COMMAND rsync -a --delete
        --exclude CMakeLists.txt --exclude application_manifest.xml
        --exclude cataicon.ico --exclude xdg --exclude screenshots
        "${CDDA_DIR}/data/" "${_bundle_dir}/data/"
    COMMAND rsync -a --delete --exclude CMakeLists.txt
        "${CDDA_DIR}/gfx/" "${_bundle_dir}/gfx/"
    # Virtual joystick image used by the touch controls.
    COMMAND mkdir -p "${_bundle_dir}/android"
    COMMAND cp -f "${CDDA_DIR}/android/app/src/main/assets/android/joystick.png"
        "${_bundle_dir}/android/joystick.png")
if(APP_BUNDLE_TRANSLATIONS)
    list(APPEND _copy_cmds
        COMMAND /bin/sh -c "if [ -d '${CDDA_DIR}/lang/mo' ]; then mkdir -p '${_bundle_dir}/lang' && rsync -a --delete '${CDDA_DIR}/lang/mo/' '${_bundle_dir}/lang/mo/'; fi")
endif()
add_custom_command(TARGET Cataclysm POST_BUILD ${_copy_cmds}
    COMMENT "Copying Cataclysm game data into the app bundle"
    VERBATIM)
