#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <string.h>
#include "sys/macos/titlebar.h"
#include <stdbool.h>
void sc_audio_player_set_muted(bool muted);
bool sc_lanadb_set_display_power(bool on);
bool sc_lanadb_press_key(int keycode);
// LANADB: on-demand recording of single-app windows.
bool lanadb_record_start(const char *filename, int format, bool audio);
bool lanadb_record_stop(void);
void sc_lanadb_flush_pending(void);
enum { LANADB_FORMAT_MP4 = 1, LANADB_FORMAT_MKV = 2 };
bool sc_lanadb_snapshot(uint8_t **rgba, int *width, int *height);
void *sc_lanadb_snapshot_buffer(void);
bool sc_audio_player_is_muted(void);

enum {
    SC_BUTTON_PIN,
    SC_BUTTON_BACK,
    SC_BUTTON_HOME,
    SC_BUTTON_RECENTS,
    SC_BUTTON_MUTE,
    SC_BUTTON_SHADE,
    SC_BUTTON_VOLUME_DOWN,
    SC_BUTTON_VOLUME_UP,
    SC_BUTTON_POWER,
    SC_BUTTON_SCREEN_OFF,
    SC_BUTTON_SCREENSHOT,
    SC_BUTTON_RECORD,
    SC_BUTTON_GIF,
    SC_BUTTON_COUNT,
};

@interface LANADBFlashView : NSView
@end
@implementation LANADBFlashView
- (NSView *)hitTest:(NSPoint)point { (void) point; return nil; }
@end

// Recording status over the top centre of the device picture: a blinking red
// dot with the kind and elapsed time while recording, a spinner while the file
// is saved. Clicking it while recording stops the capture.
@interface LANADBStatusPill : NSView
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSView *dot;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic) BOOL busy;
// A short confirmation ("已复制到剪贴板") instead of the recording clock.
@property(nonatomic) BOOL notice;
- (void)showNotice:(NSString *)text symbol:(NSString *)name color:(NSColor *)color;
@property(nonatomic, copy) void (^onClick)(void);
- (void)showText:(NSString *)text busy:(BOOL)busy;
- (CGFloat)preferredWidth;
@end

@implementation LANADBStatusPill
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) { return nil; }
    self.wantsLayer = YES;
    self.layer.cornerRadius = 14;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.08 alpha:0.78].CGColor;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.16].CGColor;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _dot = [[NSView alloc] initWithFrame:NSMakeRect(12, 11, 7, 7)];
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = 3.5;
    _dot.layer.backgroundColor = NSColor.systemRedColor.CGColor;
    [self addSubview:_dot];
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(9, 7, 14, 14)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    [self addSubview:_spinner];
    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightSemibold];
    _label.textColor = NSColor.whiteColor;
    [self addSubview:_label];
    self.hidden = YES;
    return self;
}
- (NSView *)hitTest:(NSPoint)point {
    return [super hitTest:point] ? self : nil;
}
- (void)mouseDown:(NSEvent *)event {
    (void) event;
    if (!self.busy && self.onClick) { self.onClick(); }
}
- (void)resetCursorRects {
    if (!self.busy) { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
}
- (CGFloat)preferredWidth {
    [self.label sizeToFit];
    return ceil((self.notice ? 13 : 28) + self.label.frame.size.width + 14);
}
- (void)layout {
    [super layout];
    [self.label sizeToFit];
    NSRect frame = self.label.frame;
    frame.origin = NSMakePoint(self.notice ? 13 : 28,
                               round((self.bounds.size.height - frame.size.height) / 2));
    self.label.frame = frame;
}
- (void)showNotice:(NSString *)text symbol:(NSString *)name color:(NSColor *)color {
    self.notice = YES;
    self.busy = YES;
    [self.spinner stopAnimation:nil];
    [self.dot.layer removeAllAnimations];
    self.dot.hidden = YES;
    self.toolTip = nil;
    NSImage *symbol = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    symbol = [symbol imageWithSymbolConfiguration:[[NSImageSymbolConfiguration
        configurationWithPointSize:12.5 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration
            configurationWithHierarchicalColor:color]]];
    NSTextAttachment *mark = [[NSTextAttachment alloc] init];
    mark.image = symbol;
    mark.bounds = NSMakeRect(0, -2.5, symbol.size.width, symbol.size.height);
    NSMutableAttributedString *value = [[NSMutableAttributedString alloc] init];
    [value appendAttributedString:[NSAttributedString attributedStringWithAttachment:mark]];
    [value appendAttributedString:[[NSAttributedString alloc]
        initWithString:[@" " stringByAppendingString:text] attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: NSColor.whiteColor,
        }]];
    self.label.attributedStringValue = value;
    self.alphaValue = 1;
    self.hidden = NO;
    [self.window invalidateCursorRectsForView:self];
    self.needsLayout = YES;
}
- (void)showText:(NSString *)text busy:(BOOL)busy {
    BOOL changedState = busy != self.busy || self.hidden || self.notice;
    self.notice = NO;
    self.alphaValue = 1;
    self.busy = busy;
    self.label.font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightSemibold];
    self.label.stringValue = text;
    self.label.textColor = busy ? [NSColor colorWithWhite:1 alpha:0.8] : NSColor.whiteColor;
    self.dot.hidden = busy;
    if (busy) { [self.spinner startAnimation:nil]; } else { [self.spinner stopAnimation:nil]; }
    self.toolTip = busy ? nil : @"点按停止录制";
    if (changedState) {
        [self.dot.layer removeAllAnimations];
        if (!busy) {
            CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
            blink.fromValue = @1.0;
            blink.toValue = @0.25;
            blink.duration = 0.8;
            blink.autoreverses = YES;
            blink.repeatCount = HUGE_VALF;
            [self.dot.layer addAnimation:blink forKey:@"blink"];
        }
        [self.window invalidateCursorRectsForView:self];
    }
    self.hidden = NO;
    self.needsLayout = YES;
}
@end

// Short message over the top of the device picture (instead of a popover).
@interface LANADBToastView : LANADBFlashView
- (instancetype)initWithMessage:(NSString *)message symbol:(NSString *)symbol;
@end

@implementation LANADBToastView
- (instancetype)initWithMessage:(NSString *)message symbol:(NSString *)symbol {
    self = [super initWithFrame:NSZeroRect];
    if (!self) { return nil; }
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.08 alpha:0.86].CGColor;
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.14].CGColor;
    NSImageView *icon = [NSImageView imageViewWithImage:
        [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                configurationWithPointSize:14 weight:NSFontWeightSemibold]]];
    icon.contentTintColor = NSColor.systemYellowColor;
    NSTextField *label = [NSTextField wrappingLabelWithString:message];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = NSColor.whiteColor;
    label.preferredMaxLayoutWidth = 240;
    NSSize text = [label sizeThatFits:NSMakeSize(240, CGFLOAT_MAX)];
    CGFloat height = MAX(36, ceil(text.height) + 18);
    self.frame = NSMakeRect(0, 0, ceil(text.width) + 14 + 18 + 8 + 14, height);
    icon.frame = NSMakeRect(14, round((height - 18) / 2), 18, 18);
    label.frame = NSMakeRect(14 + 18 + 8, round((height - ceil(text.height)) / 2),
                             ceil(text.width) + 2, ceil(text.height));
    [self addSubview:icon];
    [self addSubview:label];
    self.shadow = [[NSShadow alloc] init];
    self.layer.shadowColor = NSColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.3;
    self.layer.shadowRadius = 10;
    self.layer.shadowOffset = CGSizeMake(0, -3);
    return self;
}
@end

// The screenshot thumbnail: clicking it shows the file in Finder.
@interface LANADBThumbnailView : NSView
@property(nonatomic, copy) void (^onClick)(void);
@end
@implementation LANADBThumbnailView
- (NSView *)hitTest:(NSPoint)point {
    // The image view inside would otherwise swallow the click.
    return [super hitTest:point] ? self : nil;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void) event; return YES; }
- (void)mouseDown:(NSEvent *)event {
    (void) event;
    if (self.onClick) { self.onClick(); }
}
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
@end

// Dims the device picture and shows the countdown digit in its centre.
// LANADB: shown over a single-app window until the app has drawn, instead of
// the empty (black) virtual display it starts with.
@interface LANADBLaunchView : NSView
- (instancetype)initWithFrame:(NSRect)frame label:(NSString *)label icon:(NSImage *)icon;
@end

@implementation LANADBLaunchView
- (instancetype)initWithFrame:(NSRect)frame label:(NSString *)label icon:(NSImage *)icon {
    self = [super initWithFrame:frame];
    if (!self) { return nil; }
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    if (icon) {
        NSImageView *image = [NSImageView imageViewWithImage:icon];
        image.wantsLayer = YES;
        image.layer.cornerRadius = 18;
        image.layer.masksToBounds = YES;
        [image.widthAnchor constraintEqualToConstant:76].active = YES;
        [image.heightAnchor constraintEqualToConstant:76].active = YES;
        [stack addArrangedSubview:image];
    }
    NSTextField *title = [NSTextField labelWithString:label.length ? label : @"正在打开"];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    title.textColor = NSColor.labelColor;
    [stack addArrangedSubview:title];
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] init];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    [spinner startAnimation:nil];
    [stack addArrangedSubview:spinner];
    [self addSubview:stack];
    [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
    [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-20].active = YES;
    return self;
}
- (void)updateLayer {
    self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
}
// Clicks and keys go to the app underneath while it is still loading.
- (NSView *)hitTest:(NSPoint)point {
    (void) point;
    return nil;
}
@end

@interface LANADBCountdownView : LANADBFlashView
@property(nonatomic, strong) NSTextField *digit;
- (void)showNumber:(NSInteger)number;
@end

@implementation LANADBCountdownView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) { return nil; }
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.5].CGColor;
    _digit = [NSTextField labelWithString:@""];
    _digit.alignment = NSTextAlignmentCenter;
    _digit.textColor = NSColor.whiteColor;
    _digit.wantsLayer = YES;
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    shadow.shadowBlurRadius = 12;
    shadow.shadowOffset = NSMakeSize(0, -2);
    _digit.shadow = shadow;
    _digit.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_digit];
    [NSLayoutConstraint activateConstraints:@[
        [_digit.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_digit.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}
- (void)layout {
    [super layout];
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    CGFloat size = MAX(64, round(side * 0.36));
    NSFont *font = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    NSFontDescriptor *rounded = [font.fontDescriptor
        fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    NSFont *roundedFont = rounded ? [NSFont fontWithDescriptor:rounded size:size] : nil;
    self.digit.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold];
    if (roundedFont) { self.digit.font = roundedFont; }
}
- (void)showNumber:(NSInteger)number {
    self.digit.stringValue = [NSString stringWithFormat:@"%ld", (long)number];
    [self layoutSubtreeIfNeeded];
    CALayer *layer = self.digit.layer;
    if (!layer) { return; }
    // Scale around the digit's centre: a small pop on each second.
    CGRect bounds = layer.bounds;
    layer.anchorPoint = CGPointMake(0.5, 0.5);
    layer.position = CGPointMake(NSMidX(self.digit.frame), NSMidY(self.digit.frame));
    (void) bounds;
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1.35;
    scale.toValue = @1.0;
    scale.duration = 0.35;
    scale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.toValue = @1.0;
    fade.duration = 0.2;
    [layer addAnimation:scale forKey:@"pop"];
    [layer addAnimation:fade forKey:@"fade"];
}
@end

@interface LANADBActionButton : NSButton
@property(nonatomic) BOOL actionActive;
@property(nonatomic, strong) NSColor *activeColor;
@property(nonatomic) BOOL pointerInside;
@property(nonatomic, strong) NSTrackingArea *hoverTrackingArea;
- (void)refreshAppearance;
@end

@implementation LANADBActionButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea) { [self removeTrackingArea:self.hoverTrackingArea]; }
    self.hoverTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                     NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    (void) event;
    self.pointerInside = YES;
    [self refreshAppearance];
}
- (void)mouseExited:(NSEvent *)event {
    (void) event;
    self.pointerInside = NO;
    [self refreshAppearance];
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self refreshAppearance];
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    [self refreshAppearance];
}
- (void)refreshAppearance {
    NSColor *accent = self.activeColor ?: NSColor.systemIndigoColor;
    NSColor *color = !self.enabled ? NSColor.tertiaryLabelColor :
                     self.actionActive ? accent : NSColor.labelColor;
    self.contentTintColor = color;
    NSColor *background = self.actionActive && self.enabled ?
        [accent colorWithAlphaComponent:0.16] :
        self.pointerInside && self.enabled ?
        [NSColor.labelColor colorWithAlphaComponent:0.08] : NSColor.clearColor;
    self.layer.backgroundColor = background.CGColor;
}
@end

@interface LANADBTitlebarController : NSTitlebarAccessoryViewController
@property(nonatomic, copy) NSString *serial;
@property(nonatomic, copy) NSString *adbPath;
@property(nonatomic, copy) NSString *sessionToken;
@property(nonatomic, weak) NSWindow *targetWindow;
@property(nonatomic) BOOL pinned;
@property(nonatomic) BOOL recording;
@property(nonatomic) BOOL recordPending;
@property(nonatomic, copy) NSString *captureKind;
@property(nonatomic) NSInteger countdown;
@property(nonatomic, strong) NSDate *recordStartedAt;
@property(nonatomic, strong) NSTimer *captureTimer;
@property(nonatomic, strong) LANADBStatusPill *statusPill;
@property(nonatomic, strong) LANADBToastView *toast;
@property(nonatomic, copy) NSString *pillText;
@property(nonatomic, copy) NSString *pillCompactText;
@property(nonatomic, strong) LANADBCountdownView *countdownView;
@property(nonatomic, strong) NSTitlebarAccessoryViewController *navigationAccessory;
@property(nonatomic) BOOL screenshotSaving;
@property(nonatomic, strong) NSPopover *feedbackPopover;
@property(nonatomic) BOOL shadeExpanded;
@property(nonatomic) BOOL musicMuted;
@property(nonatomic) BOOL musicKnown;
@property(nonatomic) BOOL audioAvailable;
@property(nonatomic) BOOL screenAwake;
@property(nonatomic) BOOL screenKnown;
@property(nonatomic) BOOL displayOff;
@property(nonatomic) NSInteger sdkLevel;
// LANADB: a single app on its own virtual display. Device-wide controls
// (capture, volume, power) stay in the device's main mirror window.
@property(nonatomic) BOOL appWindow;
// The app shows its first page: Back asks for confirmation before closing.
@property(nonatomic) BOOL appAtRoot;
@property(nonatomic, strong) NSDate *rootBackAt;
@property(nonatomic, strong) LANADBLaunchView *launchView;
@property(nonatomic, strong) NSTimer *launchTimer;
@property(nonatomic) NSInteger launchChecks;
@property(nonatomic, strong) id keyMonitor;
@property(nonatomic) NSUInteger stateRevision;
@property(nonatomic) BOOL temporarilyLoweredForFinder;
@property(nonatomic, strong) dispatch_queue_t actionQueue;
@property(nonatomic, strong) dispatch_queue_t statusQueue;
- (instancetype)initWithWindow:(NSWindow *)window
                        serial:(NSString *)serial
                       adbPath:(NSString *)adbPath;
@end

@implementation LANADBTitlebarController {
    NSButton *_buttons[SC_BUTTON_COUNT];
}

- (instancetype)initWithWindow:(NSWindow *)window
                        serial:(NSString *)serial
                       adbPath:(NSString *)adbPath {
    self = [super init];
    if (!self) {
        return nil;
    }
    _targetWindow = window;
    _serial = [serial copy];
    _adbPath = [adbPath copy];
    const char *token = getenv("LANADB_SESSION_TOKEN");
    _sessionToken = token ? [NSString stringWithUTF8String:token] : @"";
    _recording = getenv("LANADB_RECORDING") && !strcmp(getenv("LANADB_RECORDING"), "1");
    _pinned = window.level > NSNormalWindowLevel;
    _screenAwake = YES;
    _musicKnown = YES;
    _audioAvailable = !getenv("LANADB_AUDIO_ENABLED") ||
        strcmp(getenv("LANADB_AUDIO_ENABLED"), "0") != 0;
    _musicMuted = sc_audio_player_is_muted();
    _appWindow = getenv("LANADB_APP_WINDOW") && !strcmp(getenv("LANADB_APP_WINDOW"), "1");
    _actionQueue = dispatch_queue_create("lanadb.scrcpy.titlebar.actions", DISPATCH_QUEUE_SERIAL);
    _statusQueue = dispatch_queue_create("lanadb.scrcpy.titlebar.status", DISPATCH_QUEUE_SERIAL);
    self.layoutAttribute = NSLayoutAttributeBottom;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)];
    for (NSInteger index = 0; index < SC_BUTTON_COUNT; ++index) {
        LANADBActionButton *button = [[LANADBActionButton alloc]
            initWithFrame:NSMakeRect(0, 0, 27, 26)];
        button.tag = index;
        button.target = self;
        button.action = @selector(pressButton:);
        button.bordered = NO;
        button.imagePosition = NSImageOnly;
        button.imageScaling = NSImageScaleProportionallyDown;
        button.wantsLayer = YES;
        button.layer.cornerRadius = 6;
        button.accessibilityRole = NSAccessibilityButtonRole;
        [container addSubview:button];
        _buttons[index] = button;
    }
    NSView *navigation = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 87, 26)];
    for (NSInteger index = SC_BUTTON_BACK; index <= SC_BUTTON_RECENTS; ++index) {
        if (_appWindow && index == SC_BUTTON_BACK) {
            continue;
        }
        [_buttons[index] removeFromSuperview];
        _buttons[index].frame = NSMakeRect((index - SC_BUTTON_BACK) * 29, 0, 27, 26);
        [navigation addSubview:_buttons[index]];
    }
    _navigationAccessory = [[NSTitlebarAccessoryViewController alloc] init];
    _navigationAccessory.view = navigation;
    _navigationAccessory.layoutAttribute = NSLayoutAttributeRight;
    _statusPill = [[LANADBStatusPill alloc] initWithFrame:NSMakeRect(0, 0, 120, 28)];
    _statusPill.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    __weak LANADBTitlebarController *pillOwner = self;
    _statusPill.onClick = ^{ [pillOwner stopRecordingFromPill]; };
    self.view = container;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidResize:)
                                                 name:NSWindowDidResizeNotification object:window];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidBecomeKey:)
                                                 name:NSWindowDidBecomeKeyNotification object:window];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(mirrorStateChanged:)
        name:@"uk.agpt.lanadbmanager.mirror.state" object:nil];
    if (_appWindow) {
        // Home and Recents would open the launcher on the virtual display, so
        // they are left out; Back moves to the front of the button row. The
        // editing shortcuts use `adb shell input`, which only reaches the main
        // display, so scrcpy's own input path handles those keys here.
        _buttons[SC_BUTTON_HOME].hidden = YES;
        _buttons[SC_BUTTON_RECENTS].hidden = YES;
        [self updateLayout];
        [self updateButtons];
        [self refreshDeviceState];
        [self showLaunchOverlay];
        return self;
    }
    [self updateLayout];
    [self updateButtons];
    [self refreshDeviceState];
    [self installEditingShortcuts];
    return self;
}

// ⌘A ⌘C ⌘X ⌘Z ⇧⌘Z: sent the way a hardware keyboard sends them (Ctrl held
// around the key) through `input keycombination`. A key that only carries a
// Ctrl meta state is swallowed by many input methods on the phone.
- (void)installEditingShortcuts {
    dispatch_async(self.statusQueue, ^{
        NSString *sdk = [self runADB:@[@"getprop", @"ro.build.version.sdk"] timeout:5];
        NSInteger level = [[sdk stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{ self.sdkLevel = level; });
    });
    __weak LANADBTitlebarController *weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
            NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *event) {
        LANADBTitlebarController *strongSelf = weakSelf;
        // keycombination exists from Android 13; older devices keep scrcpy's path.
        if (!strongSelf || event.window != strongSelf.targetWindow || strongSelf.sdkLevel < 33) {
            return event;
        }
        NSEventModifierFlags flags = event.modifierFlags &
            NSEventModifierFlagDeviceIndependentFlagsMask;
        if (!(flags & NSEventModifierFlagCommand) ||
                (flags & (NSEventModifierFlagControl | NSEventModifierFlagOption))) {
            return event;
        }
        BOOL shift = (flags & NSEventModifierFlagShift) != 0;
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        NSArray<NSString *> *combo = nil;
        if ([key isEqualToString:@"a"] && !shift) {
            combo = @[@"KEYCODE_CTRL_LEFT", @"KEYCODE_A"];
        } else if ([key isEqualToString:@"c"] && !shift) {
            combo = @[@"KEYCODE_CTRL_LEFT", @"KEYCODE_C"];
        } else if ([key isEqualToString:@"x"] && !shift) {
            combo = @[@"KEYCODE_CTRL_LEFT", @"KEYCODE_X"];
        } else if ([key isEqualToString:@"z"]) {
            combo = shift ? @[@"KEYCODE_CTRL_LEFT", @"KEYCODE_SHIFT_LEFT", @"KEYCODE_Z"] :
                            @[@"KEYCODE_CTRL_LEFT", @"KEYCODE_Z"];
        }
        if (!combo) {
            return event;
        }
        if (event.type == NSEventTypeKeyDown && !event.isARepeat) {
            sc_lanadb_flush_pending();
            NSArray *arguments = [@[@"input", @"keycombination"] arrayByAddingObjectsFromArray:combo];
            dispatch_async(strongSelf.actionQueue, ^{
                [strongSelf runADB:arguments timeout:5];
            });
        }
        return nil;
    }];
}

- (void)dealloc {
    if (self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor]; }
    [self.captureTimer invalidate];
    [self.launchTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

- (void)flashScreenshot {
    // Shutter: a short white flash the moment the capture is taken.
    NSView *content = self.targetWindow.contentView;
    if (!content) { return; }
    LANADBFlashView *flash = [[LANADBFlashView alloc] initWithFrame:content.bounds];
    flash.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    flash.wantsLayer = YES;
    flash.layer.backgroundColor = NSColor.whiteColor.CGColor;
    flash.alphaValue = 0;
    [content addSubview:flash positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.06;
        flash.animator.alphaValue = 0.85;
    } completionHandler:^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.32;
            context.timingFunction =
                [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            flash.animator.alphaValue = 0;
        } completionHandler:^{ [flash removeFromSuperview]; }];
    }];
}

- (void)showScreenshotThumbnail:(NSString *)path {
    [self showCaptureThumbnail:path file:path];
}

- (void)showCaptureThumbnail:(NSString *)thumb file:(NSString *)path {
    // The saved image shrinks from full screen into the lower-right corner,
    // rests there briefly and slides away, like a phone's own screenshot.
    NSView *content = self.targetWindow.contentView;
    NSImage *image = thumb.length ? [[NSImage alloc] initWithContentsOfFile:thumb] : nil;
    if (!content || !image || image.size.width <= 0 || image.size.height <= 0) { return; }
    NSRect bounds = content.bounds;
    CGFloat aspect = image.size.width / image.size.height;
    NSRect full = bounds;
    if (bounds.size.width / bounds.size.height > aspect) {
        full.size.width = bounds.size.height * aspect;
        full.origin.x = NSMidX(bounds) - full.size.width / 2;
    } else {
        full.size.height = bounds.size.width / aspect;
        full.origin.y = NSMidY(bounds) - full.size.height / 2;
    }
    CGFloat margin = 14;
    CGFloat width = MAX(72, round(bounds.size.width * 0.3));
    CGFloat height = round(width / aspect);
    NSRect corner = NSMakeRect(NSMaxX(bounds) - width - margin, NSMinY(bounds) + margin,
                               width, height);

    LANADBThumbnailView *card = [[LANADBThumbnailView alloc] initWithFrame:full];
    card.toolTip = @"在访达中显示截图";
    __weak LANADBTitlebarController *weakSelf = self;
    __weak LANADBThumbnailView *weakCard = card;
    card.onClick = ^{
        [weakSelf postAction:@"reveal" path:path];
        [weakCard removeFromSuperview];
    };
    card.wantsLayer = YES;
    card.layer.shadowColor = NSColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.35;
    card.layer.shadowRadius = 10;
    card.layer.shadowOffset = CGSizeMake(0, -3);
    NSImageView *picture = [NSImageView imageViewWithImage:image];
    picture.frame = card.bounds;
    picture.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    picture.imageScaling = NSImageScaleAxesIndependently;
    picture.wantsLayer = YES;
    picture.layer.cornerRadius = 4;
    picture.layer.masksToBounds = YES;
    picture.layer.borderColor = NSColor.whiteColor.CGColor;
    picture.layer.borderWidth = 0;
    [card addSubview:picture];
    [content addSubview:card positioned:NSWindowAbove relativeTo:nil];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.42;
        context.allowsImplicitAnimation = YES;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.8 :0.2 :1];
        card.animator.frame = corner;
        picture.layer.cornerRadius = 10;
        picture.layer.borderWidth = 2.5;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!card.superview) { return; }
            NSRect away = corner;
            away.origin.x = NSMaxX(content.bounds) + 8;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.3;
                context.timingFunction =
                    [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
                card.animator.frame = away;
                card.animator.alphaValue = 0;
            } completionHandler:^{ [card removeFromSuperview]; }];
        });
    }];
}

- (void)showLaunchOverlay {
    NSView *content = self.targetWindow.contentView;
    if (!content || self.launchView) { return; }
    const char *label = getenv("LANADB_APP_LABEL");
    const char *iconPath = getenv("LANADB_APP_ICON");
    NSImage *icon = iconPath && iconPath[0] ?
        [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:iconPath]] : nil;
    LANADBLaunchView *view = [[LANADBLaunchView alloc]
        initWithFrame:content.bounds
                label:label ? [NSString stringWithUTF8String:label] : @""
                 icon:icon];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:view positioned:NSWindowAbove relativeTo:nil];
    self.launchView = view;
    self.launchChecks = 0;
    __weak LANADBTitlebarController *weakSelf = self;
    self.launchTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES
                                                          block:^(NSTimer *timer) {
        LANADBTitlebarController *strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        strongSelf.launchChecks += 1;
        // Give up after 12 s so a dark app is never hidden for good.
        if ([strongSelf frameHasContent] || strongSelf.launchChecks > 80) {
            [timer invalidate];
            [strongSelf hideLaunchOverlay];
        }
    }];
}

- (void)hideLaunchOverlay {
    LANADBLaunchView *view = self.launchView;
    self.launchView = nil;
    [self.launchTimer invalidate];
    self.launchTimer = nil;
    if (!view) { return; }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        view.animator.alphaValue = 0;
    } completionHandler:^{ [view removeFromSuperview]; }];
}

// True once the shown frame is not an empty (all black) display.
- (BOOL)frameHasContent {
    CVPixelBufferRef hardware = (CVPixelBufferRef) sc_lanadb_snapshot_buffer();
    if (hardware) {
        CIImage *image = [CIImage imageWithCVPixelBuffer:hardware];
        CIFilter *average = [CIFilter filterWithName:@"CIAreaMaximum"];
        [average setValue:image forKey:kCIInputImageKey];
        [average setValue:[CIVector vectorWithCGRect:image.extent] forKey:kCIInputExtentKey];
        uint8_t pixel[4] = {0};
        static CIContext *context;
        if (!context) { context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: [NSNull null]}]; }
        [context render:average.outputImage toBitmap:pixel rowBytes:4
                 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:nil];
        CVPixelBufferRelease(hardware);
        return MAX(pixel[0], MAX(pixel[1], pixel[2])) > 24;
    }
    uint8_t *rgba = NULL;
    int width = 0, height = 0;
    if (!sc_lanadb_snapshot(&rgba, &width, &height)) {
        return NO;
    }
    BOOL found = NO;
    size_t total = (size_t) width * height;
    for (size_t index = 0; index < total && !found; index += 97) {
        uint8_t *p = rgba + index * 4;
        found = MAX(p[0], MAX(p[1], p[2])) > 24;
    }
    free(rgba);
    return found;
}

- (void)showCountdownOverlay {
    NSView *content = self.targetWindow.contentView;
    if (!content) { return; }
    if (!self.countdownView) {
        LANADBCountdownView *view = [[LANADBCountdownView alloc] initWithFrame:content.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.alphaValue = 0;
        [content addSubview:view positioned:NSWindowAbove relativeTo:nil];
        self.countdownView = view;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.2;
            view.animator.alphaValue = 1;
        } completionHandler:nil];
    }
    [self.countdownView showNumber:self.countdown];
}

- (void)hideCountdownOverlayThen:(void (^)(void))completion {
    LANADBCountdownView *view = self.countdownView;
    self.countdownView = nil;
    if (!view) {
        if (completion) { completion(); }
        return;
    }
    // The picture brightens back before the recording starts.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.28;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        view.animator.alphaValue = 0;
    } completionHandler:^{
        [view removeFromSuperview];
        if (completion) { completion(); }
    }];
}

- (void)updateCaptureTime {
    // The countdown itself is shown large over the picture.
    if (self.recordStartedAt && self.countdown == 0) {
        NSInteger elapsed = MAX(0, (NSInteger)-[self.recordStartedAt timeIntervalSinceNow]);
        NSString *time = [NSString stringWithFormat:@"%02ld:%02ld",
                          (long)(elapsed / 60), (long)(elapsed % 60)];
        NSString *kind = [self.captureKind isEqualToString:@"gif"] ? @"GIF" : @"录屏";
        self.pillText = [NSString stringWithFormat:@"%@ %@", kind, time];
        self.pillCompactText = time;
        [self.statusPill showText:self.pillText busy:NO];
    } else if (!self.recordPending) {
        self.statusPill.hidden = YES;
    }
    [self updateLayout];
}

/// Keeps the pill centred at the top of the picture, above other overlays.
- (void)placeStatusPill {
    NSView *content = self.targetWindow.contentView;
    if (!content || self.statusPill.hidden) { return; }
    if (self.statusPill.superview != content) {
        [content addSubview:self.statusPill positioned:NSWindowAbove relativeTo:nil];
    }
    CGFloat pillWidth = [self.statusPill preferredWidth];
    self.statusPill.frame = NSMakeRect(round(NSMidX(content.bounds) - pillWidth / 2),
                                       NSMaxY(content.bounds) - 28 - 12, pillWidth, 28);
}

/// "已复制到剪贴板" where the recording clock was, then fades away.
// LANADB: after a capture is saved: "已复制到剪贴板" when it went to the
// clipboard, otherwise "已保存".
- (void)showSavedNotice:(BOOL)copied {
    [self showNotice:copied ? @"已复制到剪贴板" : @"已保存" symbol:@"checkmark.circle.fill"
               color:NSColor.systemGreenColor duration:1.6];
}

/// A short message in the recording clock's place (not while recording).
- (void)showNotice:(NSString *)text symbol:(NSString *)symbol color:(NSColor *)color
          duration:(NSTimeInterval)duration {
    if (self.recording || self.countdown > 0) { return; }
    [self.statusPill showNotice:text symbol:symbol color:color];
    [self placeStatusPill];
    LANADBStatusPill *pill = self.statusPill;
    NSString *shown = pill.label.stringValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // A newer notice replaced this one.
        if (!pill.notice || ![pill.label.stringValue isEqualToString:shown]) { return; }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.3;
            pill.animator.alphaValue = 0;
        } completionHandler:^{
            if (pill.notice) {
                pill.hidden = YES;
                pill.notice = NO;
                pill.alphaValue = 1;
            }
        }];
    });
}

- (void)showPillBusy:(NSString *)text compact:(NSString *)compact {
    self.pillText = text;
    self.pillCompactText = compact;
    [self.statusPill showText:text busy:YES];
    [self updateLayout];
}

- (void)stopRecordingFromPill {
    if (!self.recording || self.recordPending || !self.captureKind) { return; }
    [self pressButton:_buttons[[self.captureKind isEqualToString:@"gif"] ? SC_BUTTON_GIF : SC_BUTTON_RECORD]];
}

- (void)startCountdownForKind:(NSString *)kind {
    self.captureKind = kind;
    self.countdown = 3;
    [self.captureTimer invalidate];
    [self updateCaptureTime];
    [self updateButtons];
    [self showCountdownOverlay];
    __weak LANADBTitlebarController *weakSelf = self;
    self.captureTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        LANADBTitlebarController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.targetWindow) { [timer invalidate]; return; }
        --strongSelf.countdown;
        if (strongSelf.countdown == 0) {
            [timer invalidate];
            strongSelf.captureTimer = nil;
            strongSelf.recordPending = YES;
            [strongSelf hideCountdownOverlayThen:^{
                LANADBTitlebarController *again = weakSelf;
                if (again && again.recordPending && [again.captureKind isEqualToString:kind]) {
                    [again postAction:kind];
                }
            }];
        } else {
            [strongSelf showCountdownOverlay];
        }
        [strongSelf updateCaptureTime];
        [strongSelf updateButtons];
    }];
}

- (void)startCaptureClock {
    self.recordStartedAt = [NSDate date];
    [self.captureTimer invalidate];
    [self updateCaptureTime];
    __weak LANADBTitlebarController *weakSelf = self;
    self.captureTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        LANADBTitlebarController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.targetWindow) { [timer invalidate]; return; }
        [strongSelf updateCaptureTime];
    }];
}

- (void)endCaptureClock {
    [self.captureTimer invalidate];
    self.captureTimer = nil;
    [self hideCountdownOverlayThen:nil];
    self.recordStartedAt = nil;
    self.countdown = 0;
    [self updateCaptureTime];
}

- (void)showFeedback:(NSString *)message nearButton:(NSInteger)index {
    (void) index;
    NSView *content = self.targetWindow.contentView;
    if (!content || !message.length) { return; }
    [self.toast removeFromSuperview];
    LANADBToastView *toast = [[LANADBToastView alloc]
        initWithMessage:message symbol:@"exclamationmark.triangle.fill"];
    NSRect frame = toast.frame;
    frame.origin.x = round(NSMidX(content.bounds) - frame.size.width / 2);
    frame.origin.y = NSMaxY(content.bounds) - frame.size.height - 14 -
        (self.statusPill.hidden ? 0 : 28 + 8);
    toast.frame = NSOffsetRect(frame, 0, 10);
    toast.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    toast.alphaValue = 0;
    [content addSubview:toast positioned:NSWindowAbove relativeTo:nil];
    self.toast = toast;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        toast.animator.alphaValue = 1;
        toast.animator.frame = frame;
    } completionHandler:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.toast != toast) { return; }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            toast.animator.alphaValue = 0;
        } completionHandler:^{
            [toast removeFromSuperview];
            if (self.toast == toast) { self.toast = nil; }
        }];
    });
}

- (void)mirrorStateChanged:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    if (![info[@"token"] isEqualToString:self.sessionToken]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *kind = info[@"kind"];
        NSString *message = info[@"message"] ?: @"";
        BOOL success = [info[@"success"] boolValue];
        if ([kind isEqualToString:@"appRoot"]) {
            self.appAtRoot = [info[@"root"] boolValue];
            if (!self.appAtRoot) { self.rootBackAt = nil; }
            return;
        }
        if ([kind isEqualToString:@"reveal"]) {
            if (self.pinned) {
                self.temporarilyLoweredForFinder = YES;
                self.targetWindow.level = NSNormalWindowLevel;
                [self.targetWindow orderBack:nil];
            }
            return;
        }
        if ([kind isEqualToString:@"screenshot"]) {
            if ([message hasPrefix:@"正在"]) {
                return;
            }
            self.screenshotSaving = NO;
            [self updateButtons];
            if (success) {
                [self showScreenshotThumbnail:info[@"path"]];
                [self showSavedNotice:[info[@"copied"] boolValue]];
            } else {
                [self showFeedback:message nearButton:SC_BUTTON_SCREENSHOT];
            }
        } else if ([kind isEqualToString:@"record"] || [kind isEqualToString:@"gif"]) {
            BOOL converting = [message hasPrefix:@"正在生成"];
            self.recordPending = converting;
            BOOL active = [info[@"recording"] boolValue];
            if (active && !converting && self.appWindow && [info[@"recordTo"] length]) {
                NSString *target = info[@"recordTo"];
                int format = [target.pathExtension.lowercaseString
                    isEqualToString:@"mkv"] ? LANADB_FORMAT_MKV : LANADB_FORMAT_MP4;
                BOOL recordAudio = [info[@"recordAudio"] boolValue];
                if (!lanadb_record_start(target.fileSystemRepresentation, format, recordAudio)) {
                    [self postAction:kind path:nil extra:@{@"finished": @"0", @"failed": @"1"}];
                    self.recordPending = NO;
                    [self endCaptureClock];
                    self.captureKind = nil;
                    self.recording = NO;
                    [self updateButtons];
                    [self showFeedback:@"无法开始录制" nearButton:
                        [kind isEqualToString:@"gif"] ? SC_BUTTON_GIF : SC_BUTTON_RECORD];
                    return;
                }
            }
            if (active && !converting) {
                self.captureKind = kind;
                [self startCaptureClock];
            } else if (converting) {
                [self.captureTimer invalidate];
                self.captureTimer = nil;
                [self showPillBusy:@"正在生成 GIF…" compact:@"生成中"];
            } else if (!active) {
                self.recordPending = NO;
                [self endCaptureClock];
                self.captureKind = nil;
                if (success && [info[@"path"] length]) {
                    [self showCaptureThumbnail:info[@"thumb"] ?: info[@"path"] file:info[@"path"]];
                }
                if (success) {
                    BOOL copied = [info[@"copied"] boolValue];
                    // After `recording` is cleared below.
                    dispatch_async(dispatch_get_main_queue(), ^{ [self showSavedNotice:copied]; });
                }
            }
            self.recording = active;
            [self updateButtons];
            if (!success) { [self showFeedback:message nearButton:
                [kind isEqualToString:@"gif"] ? SC_BUTTON_GIF : SC_BUTTON_RECORD]; }
        }
    });
}

- (void)windowDidResize:(NSNotification *)notification {
    (void) notification;
    [self updateLayout];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void) notification;
    if (self.temporarilyLoweredForFinder) {
        self.temporarilyLoweredForFinder = NO;
        self.targetWindow.level = self.pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    }
}

- (void)updateLayout {
    // Navigation stays on the title line; the remaining controls use one row.
    // Keep the timer slot reserved so starting a capture never moves buttons.
    CGFloat width = self.targetWindow.frame.size.width;
    if (width < 350) {
        NSRect frame = self.targetWindow.frame;
        frame.size.width = 350;
        [self.targetWindow setFrame:frame display:YES];
        width = 350;
    }
    CGFloat start = 3;
    NSButton *closeButton = [self.targetWindow standardWindowButton:NSWindowCloseButton];
    if (closeButton && self.view.window) {
        NSPoint closeCenter = [closeButton convertPoint:
            NSMakePoint(NSMidX(closeButton.bounds), NSMidY(closeButton.bounds)) toView:nil];
        start = [self.view convertPoint:closeCenter fromView:nil].x - 13.5;
    }
    static const NSInteger mirrorOrder[] = {
        SC_BUTTON_PIN, SC_BUTTON_SHADE, SC_BUTTON_VOLUME_DOWN,
        SC_BUTTON_VOLUME_UP, SC_BUTTON_MUTE, SC_BUTTON_POWER, SC_BUTTON_SCREEN_OFF,
        SC_BUTTON_SCREENSHOT, SC_BUTTON_RECORD, SC_BUTTON_GIF,
    };
    static const NSInteger appOrder[] = {
        SC_BUTTON_BACK, SC_BUTTON_PIN, SC_BUTTON_SHADE, SC_BUTTON_VOLUME_DOWN,
        SC_BUTTON_VOLUME_UP, SC_BUTTON_MUTE, SC_BUTTON_POWER, SC_BUTTON_SCREEN_OFF,
        SC_BUTTON_SCREENSHOT, SC_BUTTON_RECORD, SC_BUTTON_GIF,
    };
    const NSInteger *order = self.appWindow ? appOrder : mirrorOrder;
    const NSInteger count = self.appWindow ? (NSInteger) (sizeof(appOrder) / sizeof(appOrder[0]))
                                           : (NSInteger) (sizeof(mirrorOrder) / sizeof(mirrorOrder[0]));
    // A 27-point button with a 4–5-point gap halves the previous 8–9-point gap.
    CGFloat step = MIN(31.5, floor((width - start - 10 - 27) / (count - 1)));
    step = MAX(27, step);
    self.view.frame = NSMakeRect(0, 0, width, 27);
    for (NSInteger position = 0; position < count; ++position) {
        CGFloat x = start + position * step;
        _buttons[order[position]].frame = NSMakeRect(round(x), 1, 27, 26);
    }
    [self placeStatusPill];
}

- (NSImage *)gifSymbol {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image = [[NSImage alloc] initWithSize:NSMakeSize(24, 24)];
        [image lockFocus];
        NSDictionary *attributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.blackColor,
        };
        NSSize glyphSize = [@"GIF" sizeWithAttributes:attributes];
        [@"GIF" drawAtPoint:NSMakePoint(round((24 - glyphSize.width) / 2),
                                       round((24 - glyphSize.height) / 2))
            withAttributes:attributes];
        [image unlockFocus];
        image.template = YES;
    });
    return image;
}

- (void)setButton:(NSInteger)index
          symbol:(NSString *)symbol
           title:(NSString *)title
          active:(BOOL)active
           color:(NSColor *)color {
    NSButton *button = _buttons[index];
    button.title = @"";
    button.imagePosition = NSImageOnly;
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    button.image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium]];
    if (index == SC_BUTTON_GIF) {
        NSImage *stop = [NSImage imageWithSystemSymbolName:@"stop.circle.fill"
            accessibilityDescription:title];
        NSImage *pending = [NSImage imageWithSystemSymbolName:@"hourglass"
            accessibilityDescription:title];
        button.image = self.recordPending && [self.captureKind isEqualToString:@"gif"] ?
            [pending imageWithSymbolConfiguration:
                [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium]] :
            active ? [stop imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium]] :
            [self gifSymbol];
    }
    button.toolTip = title;
    button.accessibilityLabel = title;
    LANADBActionButton *actionButton = (LANADBActionButton *)button;
    actionButton.activeColor = color;
    actionButton.actionActive = active;
    [actionButton refreshAppearance];
}

- (void)updateButtons {
    BOOL recordingSelected = [self.captureKind isEqualToString:@"record"];
    BOOL gifSelected = [self.captureKind isEqualToString:@"gif"];
    [self setButton:SC_BUTTON_PIN symbol:self.pinned ? @"pin.fill" : @"pin"
              title:self.pinned ? @"已置顶，点击取消" : @"置顶窗口"
             active:self.pinned color:NSColor.systemIndigoColor];
    [self setButton:SC_BUTTON_BACK symbol:@"arrow.uturn.backward" title:@"后退" active:NO color:nil];
    [self setButton:SC_BUTTON_HOME symbol:@"house" title:@"首页" active:NO color:nil];
    [self setButton:SC_BUTTON_RECENTS symbol:@"square.on.square" title:@"最近任务" active:NO color:nil];
    [self setButton:SC_BUTTON_MUTE
             symbol:!self.audioAvailable || (self.musicMuted && self.musicKnown) ?
                    @"speaker.slash" : @"speaker.wave.2.fill"
              title:!self.audioAvailable ? @"未播放设备声音，请在设置中开启" :
                    (self.musicMuted ? @"投屏已静音，点击恢复声音" : @"点击静音投屏声音")
             active:self.audioAvailable && !self.musicMuted && self.musicKnown
              color:NSColor.systemIndigoColor];
    _buttons[SC_BUTTON_MUTE].enabled = self.audioAvailable;
    [self setButton:SC_BUTTON_SHADE
             symbol:self.shadeExpanded ? @"chevron.up" : @"chevron.down"
              title:self.shadeExpanded ? @"通知栏已展开，点击收起" : @"下拉通知栏"
             active:self.shadeExpanded color:NSColor.systemIndigoColor];
    [self setButton:SC_BUTTON_VOLUME_DOWN symbol:@"speaker.minus" title:@"降低音量" active:NO color:nil];
    [self setButton:SC_BUTTON_VOLUME_UP symbol:@"speaker.plus" title:@"提高音量" active:NO color:nil];
    [self setButton:SC_BUTTON_POWER
             symbol:self.screenKnown && !self.screenAwake ? @"lock.fill" : @"lock"
              title:!self.screenKnown ? @"锁屏或唤醒设备" :
                    (self.screenAwake ? @"锁屏（设备休眠，投屏画面会暂停）" : @"设备已锁屏，点击唤醒")
             active:self.screenKnown && !self.screenAwake color:NSColor.systemIndigoColor];
    [self setButton:SC_BUTTON_SCREEN_OFF symbol:@"iphone.slash"
              title:self.displayOff ? @"设备屏幕已关闭，点击重新点亮" :
                                      @"关闭设备屏幕（投屏和操作继续）"
             active:self.displayOff color:NSColor.systemIndigoColor];
    [self setButton:SC_BUTTON_SCREENSHOT
             symbol:self.screenshotSaving ? @"hourglass" : @"camera"
              title:self.screenshotSaving ? @"正在保存截图" : @"保存截图"
             active:NO color:nil];
    _buttons[SC_BUTTON_SCREENSHOT].enabled = !self.screenshotSaving;
    [self setButton:SC_BUTTON_RECORD
             symbol:self.recordPending && recordingSelected ? @"hourglass" :
                    (self.recording && recordingSelected ? @"stop.circle.fill" : @"record.circle")
              title:self.recordPending && recordingSelected ? @"正在处理录屏" :
                    (self.countdown && recordingSelected ? @"取消录屏倒计时" :
                    (self.recording && recordingSelected ? @"停止录屏" : @"开始录屏"))
             active:recordingSelected && !self.recordPending color:NSColor.systemRedColor];
    [self setButton:SC_BUTTON_GIF symbol:@"" title:
              self.recordPending && gifSelected ? @"正在处理 GIF" :
              (self.countdown && gifSelected ? @"取消 GIF 倒计时" :
              (self.recording && gifSelected ? @"停止录制 GIF" : @"录制 GIF"))
             active:gifSelected && !self.recordPending color:NSColor.systemRedColor];
    _buttons[SC_BUTTON_RECORD].enabled = !self.recordPending && (!self.captureKind || recordingSelected);
    _buttons[SC_BUTTON_GIF].enabled = !self.recordPending && (!self.captureKind || gifSelected);
}

- (void)postAction:(NSString *)action {
    [self postAction:action path:nil];
}

- (void)postAction:(NSString *)action path:(NSString *)path {
    [self postAction:action path:path extra:nil];
}

- (void)postAction:(NSString *)action path:(NSString *)path extra:(NSDictionary *)extra {
    if (!self.sessionToken.length) {
        return;
    }
    NSMutableDictionary *info = [@{@"token": self.sessionToken, @"action": action} mutableCopy];
    if (path.length) { info[@"path"] = path; }
    if (extra) { [info addEntriesFromDictionary:extra]; }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"uk.agpt.lanadbmanager.mirror.action"
                    object:nil
                  userInfo:info
        deliverImmediately:YES];
}

- (NSString *)runADB:(NSArray<NSString *> *)arguments timeout:(NSTimeInterval)timeout {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.adbPath];
    task.arguments = [@[@"-s", self.serial, @"shell"] arrayByAddingObjectsFromArray:arguments];
    NSPipe *output = [NSPipe pipe];
    NSFileHandle *reader = output.fileHandleForReading;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *ignored) {
        (void) ignored;
        dispatch_semaphore_signal(finished);
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return nil;
    }
    __block NSData *bytes = nil;
    dispatch_semaphore_t readDone = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        bytes = [reader readDataToEndOfFile];
        dispatch_semaphore_signal(readDone);
    });
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(finished, deadline) != 0) {
        if (task.running) {
            [task terminate];
        }
        [reader closeFile];
        return nil;
    }
    dispatch_semaphore_wait(readDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    if (task.terminationStatus != 0 || !bytes) {
        return nil;
    }
    return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

- (void)refreshDeviceState {
    NSUInteger revision = self.stateRevision;
    dispatch_async(self.statusQueue, ^{
        @autoreleasepool {
            // adb shell joins argument tokens before dispatching to the remote
            // shell. Passing "sh -c" as separate tokens loses the script quote
            // and runs an unfiltered dumpsys instead of the intended command.
            NSString *power = [self runADB:@[
                @"dumpsys power | grep -m 1 'mWakefulness='"] timeout:8];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (revision != self.stateRevision || !self.targetWindow) {
                    return;
                }
                if ([power containsString:@"mWakefulness=Awake"]) {
                    self.screenKnown = YES;
                    self.screenAwake = YES;
                } else if ([power containsString:@"mWakefulness=Asleep"] ||
                           [power containsString:@"mWakefulness=Dozing"]) {
                    self.screenKnown = YES;
                    self.screenAwake = NO;
                }
                [self updateButtons];
            });
        }
    });
}

- (void)pressButton:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index == SC_BUTTON_PIN) {
        self.pinned = !self.pinned;
        self.targetWindow.level = self.pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
        [self updateButtons];
        return;
    }
    if (index == SC_BUTTON_SCREEN_OFF) {
        // Only the physical panel goes dark; the device stays awake, so the
        // mirror keeps streaming and accepting input.
        BOOL off = !self.displayOff;
        if (sc_lanadb_set_display_power(!off)) {
            self.displayOff = off;
        } else {
            [self showFeedback:@"操作失败，请检查设备连接" nearButton:SC_BUTTON_SCREEN_OFF];
        }
        [self updateButtons];
        return;
    }
    if (index == SC_BUTTON_MUTE) {
        if (!self.audioAvailable) { return; }
        self.musicMuted = !self.musicMuted;
        sc_audio_player_set_muted(self.musicMuted);
        [self updateButtons];
        return;
    }
    if (index == SC_BUTTON_SCREENSHOT) {
        if (self.screenshotSaving) { return; }
        self.screenshotSaving = YES;
        [self updateButtons];
        [self flashScreenshot];
        // The frame on screen is kept as a fallback for devices whose own
        // screencap is blocked; the app prefers the device's full-size capture.
        uint8_t *rgba = NULL;
        int width = 0, height = 0;
        CVPixelBufferRef hardware = (CVPixelBufferRef) sc_lanadb_snapshot_buffer();
        if (hardware) {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"lanadb-snapshot-%@.png", NSUUID.UUID.UUIDString]];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                CIImage *image = [CIImage imageWithCVPixelBuffer:hardware];
                CIContext *context = [CIContext contextWithOptions:nil];
                CGImageRef picture = [context createCGImage:image fromRect:image.extent];
                CVPixelBufferRelease(hardware);
                BOOL saved = NO;
                if (picture) {
                    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:picture];
                    CGImageRelease(picture);
                    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    saved = [png writeToFile:path atomically:YES];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self postAction:@"screenshot" path:saved ? path : nil];
                });
            });
        } else if (sc_lanadb_snapshot(&rgba, &width, &height)) {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"lanadb-snapshot-%@.png", NSUUID.UUID.UUIDString]];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
                memcpy(rep.bitmapData, rgba, (size_t) width * height * 4);
                free(rgba);
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                BOOL saved = [png writeToFile:path atomically:YES];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self postAction:@"screenshot" path:saved ? path : nil];
                });
            });
        } else {
            [self postAction:@"screenshot"];
        }
        return;
    }
    if (index == SC_BUTTON_RECORD || index == SC_BUTTON_GIF) {
        NSString *kind = index == SC_BUTTON_GIF ? @"gif" : @"record";
        if (self.countdown > 0 && [self.captureKind isEqualToString:kind]) {
            [self endCaptureClock];
            self.captureKind = nil;
            [self updateButtons];
            return;
        }
        if (self.recordPending || (self.captureKind && ![self.captureKind isEqualToString:kind])) {
            return;
        }
        if (!self.recording) {
            [self startCountdownForKind:kind];
        } else {
            self.recordPending = YES;
            [self.captureTimer invalidate];
            self.captureTimer = nil;
            [self showPillBusy:@"正在保存…" compact:@"保存中"];
            [self updateButtons];
            if (self.appWindow) {
                // This window recorded its own stream; finish the file, then
                // let the app save (or convert) it.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    bool ok = lanadb_record_stop();
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self postAction:kind path:nil extra:@{@"finished": ok ? @"1" : @"0"}];
                    });
                });
            } else {
                [self postAction:kind];
            }
        }
        return;
    }
    if (self.appWindow && index == SC_BUTTON_BACK) {
        if (self.appAtRoot) {
            // On the app's first page Back would leave the app: ask once more.
            if (self.rootBackAt && -[self.rootBackAt timeIntervalSinceNow] < 2.0) {
                self.rootBackAt = nil;
                sc_lanadb_press_key(4);
                NSWindow *window = self.targetWindow;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [window performClose:nil]; });
            } else {
                self.rootBackAt = [NSDate date];
                [self showNotice:@"再按一次返回关闭窗口" symbol:@"arrow.uturn.backward.circle.fill"
                           color:NSColor.whiteColor duration:2.0];
            }
            return;
        }
        sc_lanadb_press_key(4); // AKEYCODE_BACK, on this window's display
        return;
    }
    NSArray<NSString *> *command;
    switch (index) {
        case SC_BUTTON_BACK: command = @[@"input", @"keyevent", @"4"]; break;
        case SC_BUTTON_HOME: command = @[@"input", @"keyevent", @"3"]; break;
        case SC_BUTTON_RECENTS: command = @[@"input", @"keyevent", @"187"]; break;
        case SC_BUTTON_SHADE:
            command = @[@"cmd", @"statusbar", self.shadeExpanded ? @"collapse" : @"expand-notifications"];
            break;
        case SC_BUTTON_VOLUME_DOWN: command = @[@"input", @"keyevent", @"25"]; break;
        case SC_BUTTON_VOLUME_UP: command = @[@"input", @"keyevent", @"24"]; break;
        case SC_BUTTON_POWER: command = @[@"input", @"keyevent", @"26"]; break;
        default: return;
    }
    sender.enabled = NO;
    dispatch_async(self.actionQueue, ^{
        @autoreleasepool {
            BOOL success = [self runADB:command timeout:5] != nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                sender.enabled = YES;
                if (!success) {
                    [self updateButtons];
                    [self showFeedback:@"操作失败，请检查设备连接" nearButton:index];
                    return;
                }
                ++self.stateRevision;
                if (index == SC_BUTTON_SHADE) {
                    self.shadeExpanded = !self.shadeExpanded;
                } else if (index == SC_BUTTON_POWER) {
                    self.screenKnown = YES;
                    self.screenAwake = !self.screenAwake;
                    self.displayOff = NO;
                }
                [self updateButtons];
                if (index == SC_BUTTON_POWER ||
                    index == SC_BUTTON_VOLUME_DOWN || index == SC_BUTTON_VOLUME_UP) {
                    [self refreshDeviceState];
                }
            });
        }
    });
}

@end

// LANADB: SDL leaves the Metal layer without a colour space, so the picture
// was shown unmanaged (stretched to the Mac's wide-gamut panel). Tag it with
// the device's own display gamut so colours match the phone.
static void
lanadb_apply_gamut(NSWindow *window) {
    const char *gamut = getenv("LANADB_GAMUT");
    CFStringRef name = gamut && !strcmp(gamut, "p3") ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(name);
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:window.contentView];
    while (views.count) {
        NSView *view = views.firstObject;
        [views removeObjectAtIndex:0];
        NSMutableArray<CALayer *> *layers = view.layer ? [NSMutableArray arrayWithObject:view.layer] :
                                                         [NSMutableArray array];
        while (layers.count) {
            CALayer *layer = layers.firstObject;
            [layers removeObjectAtIndex:0];
            if ([layer isKindOfClass:[CAMetalLayer class]]) {
                ((CAMetalLayer *) layer).colorspace = space;
            }
            [layers addObjectsFromArray:layer.sublayers ?: @[]];
        }
        [views addObjectsFromArray:view.subviews];
    }
    CGColorSpaceRelease(space);
}

void
sc_macos_titlebar_install(SDL_Window *window) {
    const char *serial = getenv("LANADB_SERIAL");
    const char *adb = getenv("LANADB_ADB");
    if (!serial || !serial[0] || !adb || !adb[0]) {
        return;
    }
    NSWindow *nativeWindow = (__bridge NSWindow *) SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!nativeWindow) {
        return;
    }
    SDL_SetWindowMinimumSize(window, 350, 250);
    nativeWindow.minSize = NSMakeSize(350, 250);
    LANADBTitlebarController *controller = [[LANADBTitlebarController alloc]
        initWithWindow:nativeWindow
              serial:[NSString stringWithUTF8String:serial]
             adbPath:[NSString stringWithUTF8String:adb]];
    [nativeWindow addTitlebarAccessoryViewController:controller];
    if (!controller.appWindow) {
        [nativeWindow addTitlebarAccessoryViewController:controller.navigationAccessory];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller updateLayout];
        // The mirror comes to the front the moment it is ready.
        if (@available(macOS 14.0, *)) {
            [NSApp activate];
        } else {
            [NSApp activateIgnoringOtherApps:YES];
        }
        [nativeWindow makeKeyAndOrderFront:nil];
        [controller postAction:@"ready"];
        lanadb_apply_gamut(nativeWindow);
        // The renderer may (re)create its layer after the first frame.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ lanadb_apply_gamut(nativeWindow); });
        // ⌘H is the device Home shortcut; the app menu's "Hide" must not
        // also take it, or the mirror window disappears on every Home.
        for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
            for (NSMenuItem *item in top.submenu.itemArray) {
                if (item.action == @selector(hide:) ||
                        item.action == @selector(hideOtherApplications:)) {
                    item.keyEquivalent = @"";
                    item.keyEquivalentModifierMask = 0;
                }
            }
        }
    });
}
