#pragma once
#ifndef CATA_IOS_PLATFORM_H
#define CATA_IOS_PLATFORM_H

// iOS services used by the Cataclysm sources when built with CATA_IOS.
// Implemented in ios_platform.mm. Call these from the main thread only;
// on iOS SDL runs the game loop on the main thread.

#include <string>

struct SDL_Window;

namespace cata_ios
{

struct pixel_rect {
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
};

// Read-only directory in the app bundle that holds data/, gfx/ and lang/,
// with a trailing slash.
std::string resource_dir();

// Writable directory for saves, config, mods and logs, with a trailing slash.
// This is the app's Documents folder, which the Files app can browse.
std::string user_dir();

// Pixels per point of the main screen (2 or 3 on Retina displays).
float display_scale();

// Start tracking the game window: safe area, keyboard and the overlay button.
void attach_window( SDL_Window *window );

// Area of the window in pixels where the terminal is drawn: inside the
// notch and rounded corners, extending down to the bottom edge.
pixel_rect terminal_area();

// Area of the window in pixels that is fully unobstructed, including by the
// home indicator. On-screen controls are laid out here.
pixel_rect safe_area();

// Pixels at the bottom of the window currently covered by the on-screen
// keyboard (0 when it is hidden).
int keyboard_overlap();

bool hardware_keyboard_connected();

// Light haptic tap, used as key-press feedback.
void haptic_feedback();

// Short message overlay, the counterpart of an Android toast.
void show_toast( const std::string &message );

// The keyboard button overlay stands in for Android's Back button. A tap
// requests the on-screen keyboard be toggled, a long press requests the quick
// shortcuts be toggled. Each request is reported once.
bool consume_keyboard_toggle_request();
bool consume_shortcuts_toggle_request();

// When the app is about to move to the background the platform layer asks
// iOS for time to finish a quicksave. The game ends that request here.
void end_background_task();

// For example "iOS 18.1 (iPhone16,1)".
std::string os_version();

// Default font cell height in pixels, chosen so a terminal of roughly 28 rows
// fills the screen in landscape.
int default_font_height();

// Scripted input for automated tests, see ios_autoplay.cpp. Does nothing
// unless the CATA_AUTOPLAY environment variable is set.
void autoplay_start( SDL_Window *window );
// Whether a scripted step asked for a screenshot of the next frame.
bool screenshot_pending();
// Reports the input context the game is waiting in.
void autoplay_input_context( const std::string &category );
// Called for every frame about to be presented. Returns true, with the PNG
// path to write, if the frame should be saved as a screenshot.
bool autoplay_frame( std::string &path );

} // namespace cata_ios

#endif // CATA_IOS_PLATFORM_H
