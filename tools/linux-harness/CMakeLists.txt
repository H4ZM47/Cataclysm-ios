# Builds the game for the desktop with the iOS code paths enabled (CATA_IOS)
# and a stand-in platform layer, to develop the touch interface without a
# device. Needs SDL2, SDL2_ttf, SDL2_image, SDL2_mixer and FreeType dev files.
#
#   cmake -S tools/linux-harness -B build/harness -G Ninja
#   cmake --build build/harness
#   cd cdda && ../build/harness/cataclysm-ios-harness
cmake_minimum_required(VERSION 3.20)
project(cataclysm_ios_harness LANGUAGES C CXX)

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(CDDA_DIR "${REPO_ROOT}/cdda" CACHE PATH "Patched Cataclysm-DDA checkout")
set(SRC "${CDDA_DIR}/src")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL REQUIRED IMPORTED_TARGET sdl2 SDL2_ttf SDL2_image SDL2_mixer freetype2 zlib)

file(GLOB CDDA_SOURCES CONFIGURE_DEPENDS "${SRC}/*.cpp")
file(GLOB THIRD_PARTY_SOURCES CONFIGURE_DEPENDS
    "${SRC}/third-party/flatbuffers/*.cpp"
    "${SRC}/third-party/zstd/common/*.c"
    "${SRC}/third-party/zstd/compress/*.c"
    "${SRC}/third-party/zstd/decompress/*.c"
    "${SRC}/third-party/imgui/*.cpp")

set(DEFS TILES SDL_SOUND LOCALIZE BACKTRACE RELEASE CATA_IOS ZSTD_STATIC_LINKING_ONLY ZSTD_DISABLE_ASM)
set(INCS "${SRC}" "${SRC}/third-party" "${REPO_ROOT}/ios/src")

add_library(harness-third-party STATIC ${THIRD_PARTY_SOURCES})
target_compile_definitions(harness-third-party PRIVATE ${DEFS})
target_include_directories(harness-third-party PRIVATE ${INCS})
target_compile_options(harness-third-party PRIVATE -w -fsigned-char)
target_link_libraries(harness-third-party PUBLIC PkgConfig::SDL)

add_executable(cataclysm-ios-harness
    ${CDDA_SOURCES}
    "${REPO_ROOT}/ios/src/ios_autoplay.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ios_platform_harness.cpp")
target_compile_definitions(cataclysm-ios-harness PRIVATE ${DEFS})
target_include_directories(cataclysm-ios-harness PRIVATE ${INCS})
target_compile_options(cataclysm-ios-harness PRIVATE -fsigned-char -Wno-deprecated-declarations)
target_link_libraries(cataclysm-ios-harness PRIVATE harness-third-party PkgConfig::SDL pthread)
