// Scripted input for automated testing of the iOS build, e.g. in the
// simulator on CI. Inert unless the CATA_AUTOPLAY environment variable is set
// (simctl passes it through as SIMCTL_CHILD_CATA_AUTOPLAY).
//
// CATA_AUTOPLAY is a ';'-separated list of steps "[<seconds>:]<action>[=<arg>]".
// Each step waits <seconds> (default 1) after the previous one, then performs:
//   idle=<seconds>        wait until no frame has been drawn for that long,
//                         e.g. until loading finished (gives up after 10 min)
//   wait=<context>        wait until the game waits for input in that input
//                         context, e.g. DEFAULTMODE for gameplay (gives up
//                         after 10 min)
//   text=<utf-8>          type text (one SDL_TEXTINPUT per character)
//   key=<name>            press and release a key (SDL key name, e.g. Return)
//   tap=<x>,<y>           one-finger tap at normalized window coordinates
//   swipe=<x0>,<y0>,<x1>,<y1>  one-finger swipe
//   tap2=<x>,<y>          two-finger tap
//   keyboard              tap the keyboard button (show/hide the on-screen
//                         keyboard)
//   shot=<name>           save the window to Documents/autoplay/<name>.png
//   log=<text>            write a marker line to stderr
// Example: "idle=8;shot=menu;text=n;text=d;wait=DEFAULTMODE;shot=game"

#include "ios_platform.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>
#include <sys/stat.h>

#include <SDL.h>

namespace
{

struct autoplay_step {
    Uint32 delay_ms = 0;
    std::string action;
    std::string arg;
};

std::vector<autoplay_step> steps;
size_t next_step = 0;
SDL_TimerID timer_id = 0;
Uint32 game_window_id = 0;
std::string screenshot_dir;

std::mutex screenshot_mutex;
std::string pending_screenshot;

std::atomic<bool> keyboard_toggle_requested{ false };

// Updated by the game loop on every presented frame.
std::atomic<Uint32> last_frame_tick{ 0 };
std::atomic<Uint32> frame_count{ 0 };
Uint32 idle_wait_started = 0;
constexpr Uint32 idle_poll_ms = 250;
constexpr Uint32 idle_give_up_ms = 10 * 60 * 1000;

// The input context the game currently waits in, and since when.
std::mutex context_mutex;
std::string current_context;
Uint32 context_since = 0;
constexpr Uint32 context_settle_ms = 1500;

// Touches synthesized here use IDs far from real UITouch addresses.
SDL_FingerID next_finger_id = 0x7ac0;

std::vector<float> parse_floats( const std::string &text )
{
    std::vector<float> values;
    std::stringstream stream( text );
    std::string item;
    while( std::getline( stream, item, ',' ) ) {
        values.push_back( std::strtof( item.c_str(), nullptr ) );
    }
    return values;
}

Uint32 window_id()
{
    return game_window_id;
}

void push_finger( Uint32 type, SDL_FingerID finger, float x, float y )
{
    SDL_Event event;
    SDL_zero( event );
    event.type = type;
    event.tfinger.timestamp = SDL_GetTicks();
    event.tfinger.touchId = 1;
    event.tfinger.fingerId = finger;
    event.tfinger.x = x;
    event.tfinger.y = y;
    event.tfinger.pressure = type == SDL_FINGERUP ? 0.0f : 1.0f;
    event.tfinger.windowID = window_id();
    SDL_PushEvent( &event );
}

void push_key( SDL_Keycode key )
{
    for( Uint32 type : { SDL_KEYDOWN, SDL_KEYUP } ) {
        SDL_Event event;
        SDL_zero( event );
        event.type = type;
        event.key.timestamp = SDL_GetTicks();
        event.key.windowID = window_id();
        event.key.state = type == SDL_KEYDOWN ? SDL_PRESSED : SDL_RELEASED;
        event.key.keysym.sym = key;
        event.key.keysym.scancode = SDL_GetScancodeFromKey( key );
        SDL_PushEvent( &event );
    }
}

void push_text( const std::string &text )
{
    // One event per UTF-8 code point, as a keyboard would send them.
    size_t i = 0;
    while( i < text.size() ) {
        size_t len = 1;
        const unsigned char lead = static_cast<unsigned char>( text[i] );
        if( lead >= 0xF0 ) {
            len = 4;
        } else if( lead >= 0xE0 ) {
            len = 3;
        } else if( lead >= 0xC0 ) {
            len = 2;
        }
        SDL_Event event;
        SDL_zero( event );
        event.type = SDL_TEXTINPUT;
        event.text.timestamp = SDL_GetTicks();
        event.text.windowID = window_id();
        const std::string ch = text.substr( i, len );
        SDL_strlcpy( event.text.text, ch.c_str(), sizeof( event.text.text ) );
        SDL_PushEvent( &event );
        i += len;
    }
}

// Wake the game loop so it notices pending work.
void push_wakeup()
{
    SDL_Event event;
    SDL_zero( event );
    event.type = SDL_USEREVENT;
    SDL_PushEvent( &event );
}

void run_step( const autoplay_step &step )
{
    std::fprintf( stderr, "[autoplay] %s=%s\n", step.action.c_str(), step.arg.c_str() );
    if( step.action == "text" ) {
        push_text( step.arg );
    } else if( step.action == "key" ) {
        const SDL_Keycode key = SDL_GetKeyFromName( step.arg.c_str() );
        if( key == SDLK_UNKNOWN ) {
            std::fprintf( stderr, "[autoplay] unknown key %s\n", step.arg.c_str() );
        } else {
            push_key( key );
        }
    } else if( step.action == "tap" || step.action == "tap2" ) {
        const std::vector<float> p = parse_floats( step.arg );
        if( p.size() >= 2 ) {
            const SDL_FingerID first = next_finger_id++;
            push_finger( SDL_FINGERDOWN, first, p[0], p[1] );
            if( step.action == "tap2" ) {
                const SDL_FingerID second = next_finger_id++;
                push_finger( SDL_FINGERDOWN, second, p[0] + 0.05f, p[1] );
                push_finger( SDL_FINGERUP, second, p[0] + 0.05f, p[1] );
            }
            push_finger( SDL_FINGERUP, first, p[0], p[1] );
        }
    } else if( step.action == "swipe" ) {
        const std::vector<float> p = parse_floats( step.arg );
        if( p.size() >= 4 ) {
            const SDL_FingerID finger = next_finger_id++;
            push_finger( SDL_FINGERDOWN, finger, p[0], p[1] );
            for( int i = 1; i <= 4; ++i ) {
                const float t = i / 4.0f;
                push_finger( SDL_FINGERMOTION, finger, p[0] + ( p[2] - p[0] ) * t, p[1] + ( p[3] - p[1] ) * t );
            }
            push_finger( SDL_FINGERUP, finger, p[2], p[3] );
        }
    } else if( step.action == "shot" ) {
        mkdir( screenshot_dir.c_str(), 0755 );
        {
            std::lock_guard<std::mutex> lock( screenshot_mutex );
            pending_screenshot = screenshot_dir + "/" + step.arg + ".png";
        }
        push_wakeup();
    } else if( step.action == "keyboard" ) {
        keyboard_toggle_requested = true;
        push_wakeup();
    } else if( step.action != "log" && step.action != "idle" && step.action != "wait" ) {
        std::fprintf( stderr, "[autoplay] unknown action %s\n", step.action.c_str() );
    }
}

// Whether an idle step may proceed; otherwise poll again shortly.
bool idle_reached( const autoplay_step &step )
{
    const Uint32 now = SDL_GetTicks();
    if( idle_wait_started == 0 ) {
        idle_wait_started = now;
    }
    const Uint32 wanted = static_cast<Uint32>( std::strtod( step.arg.c_str(), nullptr ) * 1000 );
    if( frame_count.load() > 0 && now - last_frame_tick.load() >= wanted ) {
        std::fprintf( stderr, "[autoplay] idle after %.1fs\n", ( now - idle_wait_started ) / 1000.0 );
        idle_wait_started = 0;
        return true;
    }
    if( now - idle_wait_started >= idle_give_up_ms ) {
        std::fprintf( stderr, "[autoplay] never idle, continuing anyway\n" );
        idle_wait_started = 0;
        return true;
    }
    return false;
}

// Whether a wait step may proceed: the game has been waiting for input in
// the requested context for a moment.
bool context_reached( const autoplay_step &step )
{
    const Uint32 now = SDL_GetTicks();
    if( idle_wait_started == 0 ) {
        idle_wait_started = now;
    }
    bool reached = false;
    {
        std::lock_guard<std::mutex> lock( context_mutex );
        reached = current_context == step.arg && now - context_since >= context_settle_ms;
    }
    if( reached ) {
        std::fprintf( stderr, "[autoplay] in %s after %.1fs\n", step.arg.c_str(),
                      ( now - idle_wait_started ) / 1000.0 );
        idle_wait_started = 0;
        return true;
    }
    if( now - idle_wait_started >= idle_give_up_ms ) {
        std::fprintf( stderr, "[autoplay] never reached %s, continuing anyway\n", step.arg.c_str() );
        idle_wait_started = 0;
        return true;
    }
    return false;
}

// Runs on SDL's timer thread; SDL_PushEvent is thread-safe.
Uint32 timer_callback( Uint32, void * )
{
    if( next_step >= steps.size() ) {
        return 0;
    }
    const autoplay_step &step = steps[next_step];
    if( step.action == "idle" ) {
        if( !idle_reached( step ) ) {
            return idle_poll_ms;
        }
    } else if( step.action == "wait" ) {
        if( !context_reached( step ) ) {
            return idle_poll_ms;
        }
    } else {
        run_step( step );
    }
    ++next_step;
    if( next_step >= steps.size() ) {
        std::fprintf( stderr, "[autoplay] done\n" );
        return 0;
    }
    return std::max<Uint32>( steps[next_step].delay_ms, 1 );
}

} // namespace

namespace cata_ios
{

void autoplay_start( SDL_Window *window )
{
    const char *script = std::getenv( "CATA_AUTOPLAY" );
    if( !script || !*script || timer_id != 0 ) {
        return;
    }
    game_window_id = SDL_GetWindowID( window );
    screenshot_dir = user_dir() + "autoplay";
    std::stringstream stream( script );
    std::string item;
    while( std::getline( stream, item, ';' ) ) {
        if( item.empty() ) {
            continue;
        }
        autoplay_step step;
        step.delay_ms = 1000;
        // An optional "<seconds>:" prefix, before any "=<arg>".
        const size_t colon = item.find( ':' );
        if( colon != std::string::npos && colon < item.find( '=' ) ) {
            step.delay_ms = static_cast<Uint32>( std::strtod( item.substr( 0, colon ).c_str(), nullptr ) * 1000 );
            item = item.substr( colon + 1 );
        }
        const std::string command = item;
        const size_t equals = command.find( '=' );
        step.action = command.substr( 0, equals );
        if( equals != std::string::npos ) {
            step.arg = command.substr( equals + 1 );
        }
        steps.push_back( step );
    }
    if( steps.empty() ) {
        return;
    }
    std::fprintf( stderr, "[autoplay] %zu step(s), hardware keyboard: %s\n", steps.size(),
                  hardware_keyboard_connected() ? "yes" : "no" );
    timer_id = SDL_AddTimer( std::max<Uint32>( steps.front().delay_ms, 1 ), timer_callback, nullptr );
}

bool screenshot_pending()
{
    std::lock_guard<std::mutex> lock( screenshot_mutex );
    return !pending_screenshot.empty();
}

void autoplay_input_context( const std::string &category )
{
    std::lock_guard<std::mutex> lock( context_mutex );
    if( category != current_context ) {
        current_context = category;
        context_since = SDL_GetTicks();
    }
}

bool autoplay_frame( std::string &path )
{
    last_frame_tick = SDL_GetTicks();
    ++frame_count;
    std::lock_guard<std::mutex> lock( screenshot_mutex );
    if( pending_screenshot.empty() ) {
        return false;
    }
    path = pending_screenshot;
    pending_screenshot.clear();
    return true;
}

bool autoplay_consume_keyboard_toggle()
{
    return keyboard_toggle_requested.exchange( false );
}

} // namespace cata_ios
