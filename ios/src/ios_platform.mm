// iOS platform layer for Cataclysm: Dark Days Ahead. See ios_platform.h.
//
// Compiled with ARC. Everything here runs on the main thread: SDL runs the
// game loop there, and UIKit notifications are delivered while SDL pumps the
// run loop for events.

#include "ios_platform.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <cmath>
#include <sys/utsname.h>

#include <SDL.h>
#include <SDL_syswm.h>

@interface CataIOSOverlay : NSObject
@property( nonatomic, weak ) UIWindow *window;
@property( nonatomic, strong ) UIButton *keyboardButton;
@property( nonatomic, strong ) UILabel *toastLabel;
@property( nonatomic ) CGRect keyboardFrame; // screen coordinates, CGRectNull when hidden
@property( nonatomic ) CGRect lastLayoutBounds;
@property( nonatomic ) UIEdgeInsets lastLayoutInsets;
@property( nonatomic ) BOOL keyboardToggleRequested;
@property( nonatomic ) BOOL shortcutsToggleRequested;
@property( nonatomic ) UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation CataIOSOverlay

- ( instancetype )init
{
    self = [super init];
    if( self ) {
        _keyboardFrame = CGRectNull;
        _lastLayoutBounds = CGRectNull;
        _backgroundTask = UIBackgroundTaskInvalid;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver: self selector: @selector( keyboardWillChangeFrame: )
                       name: UIKeyboardWillChangeFrameNotification object: nil];
        [center addObserver: self selector: @selector( keyboardWillHide: )
                       name: UIKeyboardWillHideNotification object: nil];
        [center addObserver: self selector: @selector( applicationWillResignActive: )
                       name: UIApplicationWillResignActiveNotification object: nil];
        [center addObserver: self selector: @selector( keyboardsChanged: )
                       name: GCKeyboardDidConnectNotification object: nil];
        [center addObserver: self selector: @selector( keyboardsChanged: )
                       name: GCKeyboardDidDisconnectNotification object: nil];
    }
    return self;
}

- ( UIView * )hostView
{
    UIWindow *window = self.window;
    if( window.rootViewController.view ) {
        return window.rootViewController.view;
    }
    return window;
}

- ( void )keyboardWillChangeFrame: ( NSNotification * )notification
{
    NSValue *frame = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    self.keyboardFrame = frame ? frame.CGRectValue : CGRectNull;
}

- ( void )keyboardWillHide: ( NSNotification * )notification
{
    ( void )notification;
    self.keyboardFrame = CGRectNull;
}

- ( void )keyboardsChanged: ( NSNotification * )notification
{
    ( void )notification;
    [self updateKeyboardButtonVisibility];
}

// The game may quicksave when it loses focus (see ANDROID_QUICKSAVE). Ask for
// time to finish that before iOS suspends the app.
- ( void )applicationWillResignActive: ( NSNotification * )notification
{
    ( void )notification;
    if( self.backgroundTask != UIBackgroundTaskInvalid ) {
        return;
    }
    __weak CataIOSOverlay *weakSelf = self;
    self.backgroundTask = [[UIApplication sharedApplication]
                           beginBackgroundTaskWithName: @"Cataclysm quicksave"
                           expirationHandler: ^ {
                               [weakSelf endBackgroundTask];
                           }];
}

- ( void )endBackgroundTask
{
    if( self.backgroundTask != UIBackgroundTaskInvalid ) {
        [[UIApplication sharedApplication] endBackgroundTask: self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
}

- ( void )installKeyboardButton
{
    if( self.keyboardButton || !self.window ) {
        return;
    }
    UIButton *button = [UIButton buttonWithType: UIButtonTypeSystem];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize: 17 weight: UIImageSymbolWeightRegular];
    [button setImage: [UIImage systemImageNamed: @"keyboard" withConfiguration: config]
             forState: UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite: 1.0 alpha: 0.85];
    button.backgroundColor = [UIColor colorWithWhite: 0.0 alpha: 0.45];
    button.layer.cornerRadius = 8.0;
    button.accessibilityLabel = @"Keyboard";
    button.accessibilityHint = @"Shows or hides the keyboard. Touch and hold to show or hide the shortcut bar.";
    [button addTarget: self action: @selector( keyboardButtonTapped: )
     forControlEvents: UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget: self action: @selector( keyboardButtonHeld: )];
    longPress.minimumPressDuration = 0.5;
    [button addGestureRecognizer: longPress];
    [[self hostView] addSubview: button];
    self.keyboardButton = button;
    [self updateKeyboardButtonVisibility];
    [self layoutIfNeeded];
}

- ( void )keyboardButtonTapped: ( id )sender
{
    ( void )sender;
    self.keyboardToggleRequested = YES;
}

- ( void )keyboardButtonHeld: ( UILongPressGestureRecognizer * )recognizer
{
    if( recognizer.state == UIGestureRecognizerStateBegan ) {
        self.shortcutsToggleRequested = YES;
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle: UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
}

- ( void )updateKeyboardButtonVisibility
{
    // With a hardware keyboard attached the on-screen keyboard never shows.
    self.keyboardButton.hidden = cata_ios::hardware_keyboard_connected();
}

// Place the keyboard button in the right-hand safe-area margin when the
// device has one (notched iPhones in landscape), so it does not cover the
// game; otherwise in the top-right corner.
- ( void )layoutIfNeeded
{
    UIView *view = [self hostView];
    if( !view || !self.keyboardButton ) {
        return;
    }
    // SDL swaps in a new root view when it creates the Metal renderer.
    if( self.keyboardButton.superview != view ) {
        [view addSubview: self.keyboardButton];
        self.lastLayoutBounds = CGRectNull;
    }
    const CGRect bounds = view.bounds;
    const UIEdgeInsets insets = view.safeAreaInsets;
    if( CGRectEqualToRect( bounds, self.lastLayoutBounds ) &&
        UIEdgeInsetsEqualToEdgeInsets( insets, self.lastLayoutInsets ) ) {
        return;
    }
    self.lastLayoutBounds = bounds;
    self.lastLayoutInsets = insets;

    const CGFloat size = 36.0;
    const CGFloat margin = 6.0;
    CGPoint center;
    if( insets.right >= size + margin ) {
        // Upper part of the margin: clear of the rounded corner and of the
        // camera housing, which is centered vertically in landscape.
        center = CGPointMake( bounds.size.width - insets.right / 2.0, bounds.size.height * 0.22 );
    } else {
        center = CGPointMake( bounds.size.width - insets.right - margin - size / 2.0,
                              insets.top + margin + size / 2.0 );
    }
    self.keyboardButton.frame = CGRectMake( center.x - size / 2.0, center.y - size / 2.0, size, size );
}

- ( void )showToast: ( NSString * )message
{
    UIView *view = [self hostView];
    if( !view ) {
        return;
    }
    if( !self.toastLabel ) {
        UILabel *label = [[UILabel alloc] init];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite: 0.1 alpha: 0.85];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize: 15 weight: UIFontWeightMedium];
        label.layer.cornerRadius = 10.0;
        label.layer.masksToBounds = YES;
        label.userInteractionEnabled = NO;
        self.toastLabel = label;
    }
    UILabel *label = self.toastLabel;
    label.text = message;
    [label sizeToFit];
    const CGSize text_size = label.bounds.size;
    const CGFloat width = text_size.width + 32.0;
    const CGFloat height = text_size.height + 16.0;
    const UIEdgeInsets insets = view.safeAreaInsets;
    label.frame = CGRectMake( ( view.bounds.size.width - width ) / 2.0, insets.top + 16.0, width, height );
    [view addSubview: label];
    [label.layer removeAllAnimations];
    label.alpha = 1.0;
    [UIView animateWithDuration: 0.4 delay: 1.4 options: UIViewAnimationOptionBeginFromCurrentState
                     animations: ^ {
                         label.alpha = 0.0;
                     }
                     completion: nil];
}

@end

namespace
{

CataIOSOverlay *overlay()
{
    static CataIOSOverlay *instance = [[CataIOSOverlay alloc] init];
    return instance;
}

SDL_Window *sdl_window = nullptr;

std::string with_trailing_slash( NSString *path )
{
    std::string result = path ? std::string( path.fileSystemRepresentation ) : std::string();
    if( !result.empty() && result.back() != '/' ) {
        result += '/';
    }
    return result;
}

// Pixels per point of the game window's drawable.
CGFloat window_pixel_scale( UIView *view )
{
    if( sdl_window && view.bounds.size.width > 0 ) {
        int width = 0;
        int height = 0;
        SDL_GetWindowSizeInPixels( sdl_window, &width, &height );
        if( width > 0 ) {
            return width / view.bounds.size.width;
        }
    }
    return UIScreen.mainScreen.nativeScale;
}

cata_ios::pixel_rect to_pixels( UIView *view, CGRect rect )
{
    const CGFloat scale = window_pixel_scale( view );
    cata_ios::pixel_rect result;
    result.x = static_cast<int>( std::ceil( rect.origin.x * scale ) );
    result.y = static_cast<int>( std::ceil( rect.origin.y * scale ) );
    result.w = static_cast<int>( std::floor( ( rect.origin.x + rect.size.width ) * scale ) ) - result.x;
    result.h = static_cast<int>( std::floor( ( rect.origin.y + rect.size.height ) * scale ) ) - result.y;
    return result;
}

} // namespace

namespace cata_ios
{

std::string resource_dir()
{
    return with_trailing_slash( [[NSBundle mainBundle] resourcePath] );
}

std::string user_dir()
{
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains( NSDocumentDirectory, NSUserDomainMask, YES );
    return with_trailing_slash( paths.firstObject );
}

float display_scale()
{
    return static_cast<float>( UIScreen.mainScreen.nativeScale );
}

void attach_window( SDL_Window *window )
{
    sdl_window = window;
    SDL_SysWMinfo info;
    SDL_VERSION( &info.version );
    if( SDL_GetWindowWMInfo( window, &info ) && info.subsystem == SDL_SYSWM_UIKIT ) {
        overlay().window = info.info.uikit.window;
        [overlay() installKeyboardButton];
    }
}

pixel_rect terminal_area()
{
    UIView *view = [overlay() hostView];
    if( !view ) {
        return {};
    }
    UIEdgeInsets insets = view.safeAreaInsets;
    // The home indicator is a thin, auto-hidden overlay; let the terminal run
    // underneath it rather than giving up two rows of text.
    insets.bottom = 0;
    return to_pixels( view, UIEdgeInsetsInsetRect( view.bounds, insets ) );
}

pixel_rect safe_area()
{
    UIView *view = [overlay() hostView];
    if( !view ) {
        return {};
    }
    [overlay() layoutIfNeeded];
    return to_pixels( view, UIEdgeInsetsInsetRect( view.bounds, view.safeAreaInsets ) );
}

int keyboard_overlap()
{
    CataIOSOverlay *state = overlay();
    // Cheap when nothing changed; keeps the button placed after rotation.
    [state layoutIfNeeded];
    UIView *view = [state hostView];
    if( !view || CGRectIsNull( state.keyboardFrame ) ) {
        return 0;
    }
    UIScreen *screen = view.window.screen ? view.window.screen : UIScreen.mainScreen;
    const CGRect keyboard = [view convertRect: state.keyboardFrame
                          fromCoordinateSpace: screen.coordinateSpace];
    const CGRect covered = CGRectIntersection( view.bounds, keyboard );
    if( CGRectIsNull( covered ) || covered.size.height <= 0 ) {
        return 0;
    }
    return static_cast<int>( std::ceil( covered.size.height * window_pixel_scale( view ) ) );
}

bool hardware_keyboard_connected()
{
    return GCKeyboard.coalescedKeyboard != nil;
}

void haptic_feedback()
{
    static UIImpactFeedbackGenerator *generator =
        [[UIImpactFeedbackGenerator alloc] initWithStyle: UIImpactFeedbackStyleLight];
    [generator impactOccurred];
}

void show_toast( const std::string &message )
{
    [overlay() showToast: [NSString stringWithUTF8String: message.c_str()]];
}

bool consume_keyboard_toggle_request()
{
    CataIOSOverlay *state = overlay();
    const bool requested = state.keyboardToggleRequested;
    state.keyboardToggleRequested = NO;
    return requested;
}

bool consume_shortcuts_toggle_request()
{
    CataIOSOverlay *state = overlay();
    const bool requested = state.shortcutsToggleRequested;
    state.shortcutsToggleRequested = NO;
    return requested;
}

void end_background_task()
{
    [overlay() endBackgroundTask];
}

std::string os_version()
{
    UIDevice *device = UIDevice.currentDevice;
    std::string result = std::string( device.systemName.UTF8String ) + " " +
                         device.systemVersion.UTF8String;
    struct utsname name;
    if( uname( &name ) == 0 ) {
        result += std::string( " (" ) + name.machine + ")";
    }
    return result;
}

int default_font_height()
{
    UIScreen *screen = UIScreen.mainScreen;
    const CGFloat scale = screen.nativeScale;
    const CGFloat short_side = std::min( screen.bounds.size.width, screen.bounds.size.height );
    // Landscape: about 28 rows, but keep cells between 10 and 16 points tall.
    const CGFloat cell_points = std::clamp<CGFloat>( short_side / 28.0, 10.0, 16.0 );
    int pixels = static_cast<int>( std::lround( cell_points * scale ) );
    // Even, so that the default font width (half the height) is exact.
    pixels -= pixels % 2;
    return std::clamp( pixels, 16, 100 );
}

} // namespace cata_ios
