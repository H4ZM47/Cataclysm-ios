#!/usr/bin/env bash
# Archive Cataclysm.app, sign it for your Apple developer team and upload it
# to App Store Connect for TestFlight, from your Mac. Nothing runs on GitHub
# Actions.
#
# Usage: APP_DEVELOPMENT_TEAM=ABCDE12345 scripts/testflight.sh
#
# One-time setup (see "TestFlight" in the README): an app record in App Store
# Connect with the bundle ID below, and either Xcode signed in to an Apple ID
# on the team (Xcode > Settings > Accounts) or an App Store Connect API key.
#
# Environment:
#   APP_DEVELOPMENT_TEAM  your team ID (required)
#   APP_BUNDLE_ID         bundle ID of the app record
#                         (default io.github.h4zm47.cataclysmdda)
#   BUILD_NUMBER          CFBundleVersion; must be higher than every build
#                         already uploaded for this version
#                         (default: UTC date and time, YYYYMMDD.HHMM)
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#                         App Store Connect API key (.p8 file, key ID, issuer
#                         ID) to sign and upload with, instead of the account
#                         signed in to Xcode
#   TESTFLIGHT_INTERNAL_ONLY=1  limit the build to internal testers
#   TESTFLIGHT_EXPORT_ONLY=1    write the signed IPA to dist/ instead of
#                         uploading it (upload it later with Transporter)
#   EXTRA_CMAKE_ARGS      additional arguments for the CMake configure step,
#                         e.g. -DAPP_INCREASED_MEMORY_LIMIT=ON
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cdda.env
source "$ROOT/cdda.env"

TEAM="${APP_DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${APP_BUNDLE_ID:-io.github.h4zm47.cataclysmdda}"
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    stamp="$(date -u +%Y%m%d.%H%M)"
    hhmm="${stamp#*.}"
    BUILD_NUMBER="${stamp%.*}.$((10#$hhmm))"
fi
BUILD_DIR="$ROOT/build/testflight"
ARCHIVE="$BUILD_DIR/Cataclysm.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: this needs a Mac with Xcode" >&2
    exit 1
fi
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: set APP_DEVELOPMENT_TEAM to your 10-character team ID" >&2
    echo "       (developer.apple.com > Account > Membership details)" >&2
    exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: BUILD_NUMBER must be one to three dot-separated integers, not '$BUILD_NUMBER'" >&2
    exit 2
fi

# Authentication for automatic signing and the upload: an API key if given,
# otherwise the account signed in to Xcode.
auth=()
if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
    if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
        echo "error: set all of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or none" >&2
        exit 2
    fi
    if [[ ! -f "$ASC_KEY_PATH" ]]; then
        echo "error: API key file $ASC_KEY_PATH does not exist" >&2
        exit 1
    fi
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
          -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

cd "$ROOT"
scripts/prepare-cdda.sh
if [[ ! -f deps/install/iphoneos/lib/libSDL2.a ]]; then
    scripts/build-deps.sh iphoneos
fi
scripts/compile-translations.sh

echo "==> Configuring for team $TEAM, $BUNDLE_ID, build $BUILD_NUMBER"
cmake_args=(
    -S "$ROOT/ios" -B "$BUILD_DIR" -G Xcode
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT=iphoneos
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DAPP_DEVELOPMENT_TEAM="$TEAM"
    -DAPP_BUNDLE_ID="$BUNDLE_ID"
    -DAPP_BUILD_NUMBER="$BUILD_NUMBER"
)
# shellcheck disable=SC2206
cmake_args+=(${EXTRA_CMAKE_ARGS:-})
cmake "${cmake_args[@]}"

echo "==> Archiving (this compiles the whole game)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# Debug symbols go into a dSYM, so TestFlight crash reports are symbolicated.
xcodebuild \
    -project "$BUILD_DIR/CataclysmDDA.xcodeproj" \
    -scheme Cataclysm \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    -jobs "$(sysctl -n hw.ncpu)" \
    -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"} \
    -quiet \
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
    COMPILER_INDEX_STORE_ENABLE=NO \
    archive

# An iOS app archive, with the game data, the privacy manifest and a
# provisioning profile in the signed app.
APP="$ARCHIVE/Products/Applications/Cataclysm.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }
if ! plist ApplicationProperties:ApplicationPath "$ARCHIVE/Info.plist" >/dev/null; then
    echo "error: $ARCHIVE is not an iOS app archive" >&2
    exit 1
fi
for item in data/json gfx android/joystick.png PrivacyInfo.xcprivacy embedded.mobileprovision; do
    if [[ ! -e "$APP/$item" ]]; then
        echo "error: $item is missing from the archived app" >&2
        exit 1
    fi
done
codesign --verify --strict "$APP"
VERSION="$(plist CFBundleShortVersionString "$APP/Info.plist")"
echo "==> Archived $BUNDLE_ID $VERSION ($(plist CFBundleVersion "$APP/Info.plist"))"

# "app-store-connect" replaced "app-store" in Xcode 15.3.
xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
IFS=. read -r xcode_major xcode_minor _ <<<"$xcode_version.0"
method=app-store-connect
if (( xcode_major < 15 || (xcode_major == 15 && xcode_minor < 3) )); then
    method=app-store
fi
destination=upload
if [[ "${TESTFLIGHT_EXPORT_ONLY:-0}" == 1 ]]; then
    destination=export
fi
internal_only=""
if [[ "${TESTFLIGHT_INTERNAL_ONLY:-0}" == 1 ]]; then
    internal_only=$'\t<key>testFlightInternalTestingOnly</key>\n\t<true/>'
fi
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$method</string>
	<key>destination</key>
	<string>$destination</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
$internal_only
</dict>
</plist>
PLIST

if [[ "$destination" == upload ]]; then
    echo "==> Uploading to App Store Connect"
else
    echo "==> Exporting a signed IPA"
fi
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates \
    ${auth[@]+"${auth[@]}"}

if [[ "$destination" == upload ]]; then
    echo "==> Uploaded build $BUILD_NUMBER of version $VERSION."
    echo "    When App Store Connect has processed it, it appears under TestFlight,"
    echo "    where you can add testers."
else
    mkdir -p "$ROOT/dist"
    ipa="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
    out="$ROOT/dist/Cataclysm-$VERSION-$BUILD_NUMBER.ipa"
    cp -f "$ipa" "$out"
    echo "==> Wrote $out; upload it with Transporter."
fi
