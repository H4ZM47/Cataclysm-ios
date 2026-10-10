#!/bin/sh
# Copy Cataclysm's game data into the app bundle. Runs as an Xcode build
# phase (see ios/CMakeLists.txt), which provides TARGET_BUILD_DIR and
# CONTENTS_FOLDER_PATH for the bundle being built.
#
# Usage: copy-game-data.sh <cdda checkout>
set -eu

CDDA="$1"
DEST="${TARGET_BUILD_DIR:?not run from Xcode}/${CONTENTS_FOLDER_PATH:?not run from Xcode}"

rsync -a --delete \
    --exclude CMakeLists.txt --exclude application_manifest.xml \
    --exclude cataicon.ico --exclude xdg --exclude screenshots --exclude cache \
    "$CDDA/data/" "$DEST/data/"
rsync -a --delete --exclude CMakeLists.txt "$CDDA/gfx/" "$DEST/gfx/"

# Virtual joystick image used by the touch controls.
mkdir -p "$DEST/android"
cp -f "$CDDA/android/app/src/main/assets/android/joystick.png" "$DEST/android/joystick.png"

# Compiled translations, if scripts/compile-translations.sh was run.
if [ -d "$CDDA/lang/mo" ]; then
    mkdir -p "$DEST/lang"
    rsync -a --delete "$CDDA/lang/mo/" "$DEST/lang/mo/"
fi

echo "Copied game data into $DEST"
