// Desktop stand-in for ios_platform.mm, so the CATA_IOS code paths (screen
// layout, touch controls, autoplay) can be run and debugged on Linux or macOS
// without a device. Behaviour is configured with environment variables:
//
//   CATA_HARNESS_RESOURCE_DIR  directory holding data/ and gfx/ (default: cwd)
//   CATA_HARNESS_USER_DIR      writable user directory (default: ./harness-user/)
//   CATA_HARNESS_SCALE         pixels per point (default 3, like a Pro iPhone)
//   CATA_HARNESS_INSETS        safe-area insets in pixels "left,top,right,bottom"
//                              (default "177,0,177,63", an iPhone 15 Pro in landscape)
//   CATA_HARNESS_KEYBOARD      fraction of the window the on-screen keyboard
//                              covers while text input is active (default 0.45)
//   CATA_HARNESS_FONT          default font cell height in pixels (default 42)

#include "ios_platform.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

#include <SDL.h>

namespace
{

SDL_Window *harness_window = nullptr;

std::string env_or( const char *name, const std::string &fallback )
{
    const char *value = std::getenv( name );
    return value && *value ? std::string( value ) : fallback;
}

std::string with_slash( std::string path )
{
    if( !path.empty() && path.back() != '/' ) {
        path += '/';
    }
    return path;
}

void insets( int &left, int &top, int &right, int &bottom )
{
    const std::string spec = env_or( "CATA_HARNESS_INSETS", "177,0,177,63" );
    left = top = right = bottom = 0;
    std::sscanf( spec.c_str(), "%d,%d,%d,%d", &left, &top, &right, &bottom );
}

cata_ios::pixel_rect window_rect( bool include_bottom_inset )
{
    cata_ios::pixel_rect r;
    if( !harness_window ) {
        return r;
    }
    int w = 0;
    int h = 0;
    SDL_GetWindowSizeInPixels( harness_window, &w, &h );
    int left;
    int top;
    int right;
    int bottom;
    insets( left, top, right, bottom );
    if( !include_bottom_inset ) {
        bottom = 0;
    }
    r.x = left;
    r.y = top;
    r.w = w - left - right;
    r.h = h - top - bottom;
    return r;
}

} // namespace

namespace cata_ios
{

std::string resource_dir()
{
    char cwd[4096];
    return with_slash( env_or( "CATA_HARNESS_RESOURCE_DIR", getcwd( cwd, sizeof( cwd ) ) ? cwd : "." ) );
}

std::string user_dir()
{
    return with_slash( env_or( "CATA_HARNESS_USER_DIR", "./harness-user/" ) );
}

std::string cache_dir()
{
    return user_dir() + "Caches/";
}

float display_scale()
{
    return std::strtof( env_or( "CATA_HARNESS_SCALE", "3" ).c_str(), nullptr );
}

void attach_window( SDL_Window *window )
{
    harness_window = window;
    // Let a mouse stand in for a finger.
    SDL_SetHint( SDL_HINT_MOUSE_TOUCH_EVENTS, "1" );
}

pixel_rect terminal_area()
{
    return window_rect( false );
}

pixel_rect safe_area()
{
    return window_rect( true );
}

int keyboard_overlap()
{
    if( !harness_window || !SDL_IsTextInputActive() ) {
        return 0;
    }
    int w = 0;
    int h = 0;
    SDL_GetWindowSizeInPixels( harness_window, &w, &h );
    return static_cast<int>( h * std::strtof( env_or( "CATA_HARNESS_KEYBOARD", "0.45" ).c_str(), nullptr ) );
}

bool hardware_keyboard_connected()
{
    return env_or( "CATA_IOS_HARDWARE_KEYBOARD", "0" ) != "0";
}

void haptic_feedback()
{
}

void show_toast( const std::string &message )
{
    std::fprintf( stderr, "[toast] %s\n", message.c_str() );
}

bool consume_keyboard_toggle_request()
{
    return autoplay_consume_keyboard_toggle();
}

bool consume_shortcuts_toggle_request()
{
    return false;
}

void end_background_task()
{
}

std::string os_version()
{
    return "iOS harness";
}

int default_font_height()
{
    return std::atoi( env_or( "CATA_HARNESS_FONT", "42" ).c_str() );
}

} // namespace cata_ios

// On iOS SDL2main provides main() and calls the game's SDL_main(); do the same.
extern "C" int SDL_main( int argc, char **argv );

int main( int argc, char **argv )
{
    return SDL_main( argc, argv );
}
