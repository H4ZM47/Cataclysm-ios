# Cataclysm: Dark Days Ahead for iOS

An iPhone and iPad port of [Cataclysm: Dark Days Ahead](https://cataclysmdda.org/), the open-source
post-apocalyptic survival roguelike. It builds the game's own SDL tiles front end for iOS, with
the touch controls of the official Android port, a layout that respects the notch and home
indicator, and saves you can reach from the Files app.

This is an unofficial port and is not affiliated with the Cataclysm: DDA team. The game itself
comes unmodified from [CleverRaven/Cataclysm-DDA](https://github.com/CleverRaven/Cataclysm-DDA);
this repository holds only the iOS build system, a small patch series and the iOS platform layer.

| | |
|---|---|
| Game version | **0.I-1** stable (upstream tag [`0.I-1`](https://github.com/CleverRaven/Cataclysm-DDA/tree/0.I-1)) |
| Devices | iPhone and iPad, arm64, iOS/iPadOS 15 or later, landscape |
| Graphics | Tilesets and ASCII, all upstream tilesets included |
| Sound | Supported (SDL2_mixer); add soundpacks yourself, see below |
| Languages | All upstream translations |

## Installing

There is no App Store release. Install the app with your own Apple ID:

1. Download the unsigned IPA from the [Releases](../../releases) page, or the
   **Cataclysm-unsigned-ipa** artifact from a successful run of the
   [iOS workflow](../../actions/workflows/ios.yml) (unzip it to get
   `Cataclysm-0.I-1-unsigned.ipa`).
2. Sign and install it with a sideloading tool such as [AltStore](https://altstore.io/) or
   [Sideloadly](https://sideloadly.io/). With a free Apple ID the signature lasts 7 days,
   after which the tool has to refresh it; your saves are kept.

Or build it yourself and run it from Xcode, see [Building](#building).

## Playing on a touch screen

The touch controls are the ones from upstream's Android port:

| Gesture | Effect |
|---|---|
| Tap | Wait a turn (`.`) in game, confirm in menus |
| Double tap | Escape / back |
| Swipe, or touch and hold then slide | Move or scroll in that direction; holding repeats, like a virtual joystick |
| Two-finger tap | Inventory (`i`) |
| Two-finger swipe | Wide-move keys (`H` `J` `K` `L`), e.g. to pan the view while looking around |
| Pinch | Zoom in and out |
| Three-finger tap | Show or hide the shortcut bar |
| Three-finger swipe | Tab, back-tab, page up and page down |
| Shortcut bar | Context-sensitive keys along the bottom edge; flick one upward to remove it |
| ⌨ button | Tap to show or hide the keyboard, touch and hold to show or hide the shortcut bar |

The shortcut bar learns: keys you type on the keyboard and actions picked from the action menu
are added to it. Everything above can be changed under **Settings → Touch**.

The ⌨ button sits in the empty margin beside the screen on iPhones with a notch or Dynamic
Island, and in the top right corner otherwise. It hides itself while a hardware keyboard is
connected.

### Keyboard, mouse and controllers

Hardware keyboards (Magic Keyboard, Bluetooth) work like on desktop. On iPad a trackpad or mouse
can click in menus and on the map. Game controllers supported by iOS can be enabled under
**Settings → Interface**.

### Text size

The terminal always fills the screen; its size follows from the font. A fresh install picks a
font cell height that gives about 28 rows. To fit more or less on screen, change
**Settings → Graphics → Font width / Font height / Font size** (and the map and overmap
variants) and restart the app.

## Files, saves and mods

Everything the game writes lives in the app's Documents folder, which shows up in the Files app
under *On My iPhone/iPad → Cataclysm* and in Finder when the device is connected to a Mac.

| Folder | Contents |
|---|---|
| `save/` | Worlds and characters |
| `config/` | Options, keybindings, `debug.log` and crash logs |
| `mods/` | Your own mods, one folder per mod |
| `gfx/` | Extra tilesets |
| `sound/` | Soundpacks, e.g. [CDDA-Soundpack](https://github.com/Fris0uman/CDDA-Soundpack) |
| `memorial/`, `achievements/` | Graveyard and achievements |

To move a game between devices or to and from desktop Cataclysm 0.I, copy the world folder
in `save/`.

iOS can stop an app in the background at any time, so save before switching away. Settings →
Touch → *Quicksave on app lose focus* saves automatically when the app goes to the background;
upstream marks this experimental.

## Building

Requirements: a Mac with Xcode 15 or later, CMake 3.24 or later, and optionally `gettext`
(`brew install cmake gettext`) for translations.

```sh
scripts/fetch-cdda.sh                 # clone upstream 0.I-1 into ./cdda and apply patches/
scripts/build-deps.sh                 # SDL2, SDL2_ttf, SDL2_image, SDL2_mixer for iOS
scripts/compile-translations.sh       # optional: lang/*.po -> lang/mo
scripts/build-app.sh iphoneos         # or: iphonesimulator
scripts/package-ipa.sh                # unsigned IPA in dist/
```

`build-app.sh` generates an Xcode project in `build/<platform>/CataclysmDDA.xcodeproj`. To
install on your own device, set your team and a bundle identifier you own and build again:

```sh
APP_DEVELOPMENT_TEAM=ABCDE12345 APP_BUNDLE_ID=com.example.cataclysm scripts/build-app.sh iphoneos
```

or open the project in Xcode, select the *Cataclysm* scheme, pick your team under *Signing &
Capabilities* and press Run.

Cataclysm keeps the whole game database in memory. If your App ID has the
[Increased Memory Limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
capability enabled, request it with `EXTRA_CMAKE_ARGS=-DAPP_INCREASED_MEMORY_LIMIT=ON`; this helps
on devices with less RAM. A full build takes a while: Cataclysm has around 450 large source
files.

### Repository layout

| Path | |
|---|---|
| `cdda.env` | Upstream repository, tag and commit the port is built from |
| `patches/` | Changes to upstream sources, applied as commits on branch `ios` of `./cdda` |
| `ios/CMakeLists.txt` | Xcode project: game sources, SDL2 libraries, app bundle, game data |
| `ios/src/ios_platform.mm` | iOS platform layer: paths, safe area, keyboard, haptics, keyboard button |
| `ios/src/ios_autoplay.cpp` | Scripted input for automated tests |
| `ios/scripts/copy-game-data.sh` | Build phase that copies `data/`, `gfx/` and translations into the app |
| `ios/resources/` | `Info.plist`, app icon |
| `scripts/` | Fetch, build, package, release and test scripts |
| `tools/linux-harness/` | Desktop build of the iOS code paths for development without a Mac |
| `.github/workflows/ios.yml` | CI: device build and IPA, simulator build and smoke test |

### How the port works

Upstream already runs on Android through SDL2, and most of what a phone needs lives behind
`#if defined(__ANDROID__)`. The patch adds a `CATA_IOS` build flag and turns on the same touch
interface for it, replacing the few Android Java calls with the iOS platform layer. On top of
that it:

- enters through `SDL_main`, reads data from the app bundle and writes to Documents/;
- renders at full Retina resolution and sizes the terminal to the safe area, so text is drawn
  1:1 and nothing hides behind the notch, shrinking it above the on-screen keyboard;
- maps iOS touches (which SDL identifies by `UITouch` address) to the finger indices the
  Android gesture code expects;
- maps trackpad and mouse positions from points to terminal pixels;
- finishes a background quicksave inside an iOS background task.

### Changing the patches

`scripts/fetch-cdda.sh` applies `patches/` as commits on a branch called `ios` in `./cdda`.
Commit your changes there, then run `scripts/export-patches.sh` to regenerate `patches/`.
To move to a newer upstream release, update `cdda.env`, run `scripts/fetch-cdda.sh --force`
and rebase the patches.

### Publishing a release

`scripts/release.sh` publishes an unsigned IPA as a GitHub Release from your Mac, without
GitHub Actions. It builds the device app (or takes an IPA you pass it), then creates the release
and tag on the current commit with the GitHub CLI:

```sh
gh auth login                                  # once
scripts/release.sh v0.I-1-ios.1                # build and publish
scripts/release.sh v0.I-1-ios.1 path/to.ipa    # publish an IPA you already have
RELEASE_DRAFT=1 scripts/release.sh v0.I-1-ios.1   # create a draft to review first
```

The commit must be clean and pushed, and `./cdda` must match `patches/`.

### Testing

CI builds both the device and the simulator app. The simulator job installs the app in an
iPhone and an iPad Simulator and drives it with `CATA_AUTOPLAY` (see
`ios/src/ios_autoplay.cpp`): it starts a *Play Now!* game, exercises the touch controls and the
on-screen keyboard, quicksaves, checks that the save was written and uploads screenshots and
logs as the **smoke-test** artifact.
The Simulator can report the Mac's keyboard as a hardware keyboard, which hides the quick
shortcuts, so the test sets `CATA_IOS_HARDWARE_KEYBOARD=0` to get the phone behaviour.
`scripts/simulator-smoke-test.sh` runs the same test locally (`SMOKE_DEVICE_KIND=ipad` for an
iPad).

`tools/linux-harness` builds the game for Linux with the iOS code paths enabled and a stand-in
platform layer (simulated notch, keyboard and screen scale). It runs the same layout, touch
controls and autoplay hook as the app, which is handy for working on them without a Mac:

```sh
cmake -S tools/linux-harness -B build/harness -G Ninja && cmake --build build/harness
tools/linux-harness/run.sh                       # in a window on the current display
CATA_AUTOPLAY="idle=8;shot=menu" tools/linux-harness/run.sh --headless   # under Xvfb
```

## License

Cataclysm: Dark Days Ahead is licensed under
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/) with some third-party parts under
their own licenses; see upstream's
[LICENSE.txt](https://github.com/CleverRaven/Cataclysm-DDA/blob/0.I-1/LICENSE.txt). The
patches and the rest of this repository are released under the same CC BY-SA 3.0 license.
SDL2 and its satellite libraries are under the [zlib license](https://www.libsdl.org/license.php).
