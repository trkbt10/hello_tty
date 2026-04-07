// macOS platform adapter using AppKit (Cocoa).
//
// Implements the platform FFI functions for:
//   - Window creation and management via NSWindow
//   - Event handling (keyboard, mouse, resize, focus)
//   - Clipboard via NSPasteboard
//   - DPI scale via NSScreen.backingScaleFactor
//   - Vulkan surface via MoltenVK (VK_EXT_metal_surface)
//
// This file is Objective-C (.m) and must be compiled with -framework Cocoa.
//
// IMPORTANT: This file is compiled as part of the MoonBit native-stub,
// but requires macOS frameworks that moon build cannot link automatically.
// Set HELLO_TTY_PLATFORM_MACOS=1 when building via the adapters/macos Makefile.
// When building directly via moon build, the stub implementations from
// platform_stub.c are used instead (guarded by !__APPLE__ or this flag).

#if defined(__APPLE__) && defined(HELLO_TTY_PLATFORM_MACOS)

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>  // For kVK_ key codes
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdint.h>
#include <string.h>

// ---------- Forward declarations ----------

@class HTTYWindow;
@class HTTYView;
@class HTTYAppDelegate;

// ---------- Internal state ----------

typedef struct {
    NSApplication *app;
    HTTYAppDelegate *delegate;
    int initialized;
} PlatformState;

static PlatformState g_platform = {0};

// Maximum number of windows (for simplicity, terminal typically uses 1)
#define MAX_WINDOWS 16

typedef struct {
    HTTYWindow *window;
    HTTYView *view;
    int alive;
    // Event queue (ring buffer)
    int event_types[256];
    int event_data[256][4]; // up to 4 ints per event
    int event_head;
    int event_tail;
} WindowSlot;

static WindowSlot g_windows[MAX_WINDOWS] = {0};

static void push_event(int slot, int type, int d0, int d1, int d2, int d3) {
    int next = (g_windows[slot].event_tail + 1) % 256;
    if (next == g_windows[slot].event_head) return; // Queue full
    g_windows[slot].event_types[g_windows[slot].event_tail] = type;
    g_windows[slot].event_data[g_windows[slot].event_tail][0] = d0;
    g_windows[slot].event_data[g_windows[slot].event_tail][1] = d1;
    g_windows[slot].event_data[g_windows[slot].event_tail][2] = d2;
    g_windows[slot].event_data[g_windows[slot].event_tail][3] = d3;
    g_windows[slot].event_tail = next;
}

static int pop_event(int slot, int *type, int data[4]) {
    if (g_windows[slot].event_head == g_windows[slot].event_tail) return 0;
    *type = g_windows[slot].event_types[g_windows[slot].event_head];
    memcpy(data, g_windows[slot].event_data[g_windows[slot].event_head], sizeof(int) * 4);
    g_windows[slot].event_head = (g_windows[slot].event_head + 1) % 256;
    return 1;
}

// ---------- Map macOS key codes to our virtual key codes ----------

// Our key codes use NSEvent function key Unicode values (0xF700+)
// for special keys, and ASCII for normal keys.
static int translate_key_code(NSEvent *event) {
    NSString *chars = [event charactersIgnoringModifiers];
    if (chars.length == 0) return 0;

    unichar ch = [chars characterAtIndex:0];
    // Function keys and special keys are already in the 0xF700+ range
    if (ch >= 0xF700) return (int)ch;
    // Normal keys: return lowercase ASCII
    if (ch >= 'A' && ch <= 'Z') ch = ch - 'A' + 'a';
    return (int)ch;
}

static int translate_modifiers(NSEvent *event) {
    NSEventModifierFlags flags = [event modifierFlags];
    int mods = 0;
    if (flags & NSEventModifierFlagShift)   mods |= 1; // mod_shift
    if (flags & NSEventModifierFlagControl) mods |= 2; // mod_ctrl
    if (flags & NSEventModifierFlagOption)  mods |= 4; // mod_alt
    if (flags & NSEventModifierFlagCommand) mods |= 8; // mod_super
    return mods;
}

// ---------- NSView subclass ----------

@interface HTTYView : NSView
@property (nonatomic, assign) int slotIndex;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@end

@implementation HTTYView

- (instancetype)initWithFrame:(NSRect)frame slotIndex:(int)slot {
    self = [super initWithFrame:frame];
    if (self) {
        _slotIndex = slot;
        self.wantsLayer = YES;

        // Create a CAMetalLayer for Vulkan/MoltenVK rendering
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = MTLCreateSystemDefaultDevice();
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        _metalLayer.framebufferOnly = YES;
        _metalLayer.frame = self.bounds;
        _metalLayer.contentsScale = self.window.backingScaleFactor;
        self.layer = _metalLayer;
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return YES;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (_metalLayer) {
        _metalLayer.drawableSize = [self convertSizeToBacking:newSize];
    }
    // Push resize event (in backing pixels)
    NSSize backing = [self convertSizeToBacking:newSize];
    push_event(_slotIndex, 2, (int)backing.width, (int)backing.height, 0, 0);
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (_metalLayer) {
        _metalLayer.contentsScale = self.window.backingScaleFactor;
    }
}

- (void)keyDown:(NSEvent *)event {
    int key = translate_key_code(event);
    int mods = translate_modifiers(event);
    push_event(_slotIndex, 1, key, mods, 0, 0);
    // Also handle text input for IME/composed characters
    [self interpretKeyEvents:@[event]];
}

- (void)insertText:(id)string replacementRange:(NSRange)range {
    (void)range;
    NSString *str = nil;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        str = [(NSAttributedString *)string string];
    } else {
        str = (NSString *)string;
    }
    // For composed multi-character input, push individual key events
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar ch = [str characterAtIndex:i];
        push_event(_slotIndex, 1, (int)ch, 0, 0, 0);
    }
}

- (void)doCommandBySelector:(SEL)selector {
    // Suppress system beep for unhandled keys
    (void)selector;
}

- (void)flagsChanged:(NSEvent *)event {
    // Modifier key changes — could track if needed
    (void)event;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    int mods = translate_modifiers(event);
    push_event(_slotIndex, 6, (int)loc.x, (int)(self.frame.size.height - loc.y),
               (int)[event buttonNumber], mods);
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    push_event(_slotIndex, 6, (int)loc.x, (int)(self.frame.size.height - loc.y),
               (int)[event buttonNumber] | 0x100, 0); // 0x100 = release flag
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    push_event(_slotIndex, 6, (int)loc.x, (int)(self.frame.size.height - loc.y),
               -1, 0); // -1 = no button (motion)
}

- (void)mouseDragged:(NSEvent *)event {
    [self mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    int delta = (int)([event scrollingDeltaY] * 3.0);
    push_event(_slotIndex, 6, (int)loc.x, (int)(self.frame.size.height - loc.y),
               -2, delta); // -2 = scroll, data[3] = delta
}

// NSTextInputClient protocol stubs for insertText: to work
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(0, 0); }
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)string; (void)selectedRange; (void)replacementRange;
}
- (void)unmarkText {}
- (BOOL)hasMarkedText { return NO; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange; return nil;
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange;
    return NSMakeRect(0, 0, 0, 0);
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point; return NSNotFound;
}

@end

// ---------- NSWindow subclass ----------

@interface HTTYWindow : NSWindow
@property (nonatomic, assign) int slotIndex;
@end

@implementation HTTYWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

@end

// ---------- NSWindowDelegate ----------

@interface HTTYWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, assign) int slotIndex;
@end

@implementation HTTYWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    push_event(_slotIndex, 3, 0, 0, 0, 0); // CloseRequested
    return NO; // Let the app handle shutdown
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    push_event(_slotIndex, 4, 0, 0, 0, 0); // FocusGained
}

- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    push_event(_slotIndex, 5, 0, 0, 0, 0); // FocusLost
}

- (void)windowDidResize:(NSNotification *)notification {
    NSWindow *window = [notification object];
    NSSize size = [[window contentView] frame].size;
    NSSize backing = [[window contentView] convertSizeToBacking:size];
    push_event(_slotIndex, 2, (int)backing.width, (int)backing.height, 0, 0);
}

@end

// ---------- Application delegate ----------

@interface HTTYAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation HTTYAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

// ---------- Public C API ----------

int hello_tty_platform_init(void) {
    if (g_platform.initialized) return 0;

    @autoreleasepool {
        [NSApplication sharedApplication];

        g_platform.delegate = [[HTTYAppDelegate alloc] init];
        [NSApp setDelegate:g_platform.delegate];

        // Create a basic menu bar
        NSMenu *menubar = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
        [NSApp setMainMenu:menubar];

        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"Quit hello_tty"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        // Finish launching
        [NSApp finishLaunching];
    }

    g_platform.initialized = 1;
    return 0;
}

int hello_tty_platform_create_window(int width, int height) {
    if (!g_platform.initialized) return -1;

    // Find a free slot
    int slot = -1;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (!g_windows[i].alive) { slot = i; break; }
    }
    if (slot < 0) return -1;

    @autoreleasepool {
        NSRect frame = NSMakeRect(100, 100, width, height);

        HTTYWindow *window = [[HTTYWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];

        window.slotIndex = slot;
        [window setTitle:@"hello_tty"];
        [window setMinSize:NSMakeSize(200, 100)];

        // Set up window delegate
        HTTYWindowDelegate *wd = [[HTTYWindowDelegate alloc] init];
        wd.slotIndex = slot;
        [window setDelegate:wd];

        // Create custom view with Metal layer
        HTTYView *view = [[HTTYView alloc] initWithFrame:frame slotIndex:slot];
        [window setContentView:view];
        [window makeFirstResponder:view];

        // Accept mouse events
        [window setAcceptsMouseMovedEvents:YES];

        g_windows[slot].window = window;
        g_windows[slot].view = view;
        g_windows[slot].alive = 1;
        g_windows[slot].event_head = 0;
        g_windows[slot].event_tail = 0;

        [window makeKeyAndOrderFront:nil];
    }

    return slot + 1; // 1-based handle
}

void hello_tty_platform_set_title(
    const uint8_t *title, int title_len, int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_windows[slot].alive) return;

    @autoreleasepool {
        NSString *str = [[NSString alloc]
            initWithBytes:title
                   length:(NSUInteger)title_len
                 encoding:NSUTF8StringEncoding];
        if (str) {
            [g_windows[slot].window setTitle:str];
        }
    }
}

int hello_tty_platform_poll_event(int window, int32_t *event_buf) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_windows[slot].alive) return 0;

    @autoreleasepool {
        // Process pending NSEvents first
        while (true) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:nil
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (!event) break;
            [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
    }

    // Pop from our event queue
    int type = 0;
    int data[4] = {0};
    if (pop_event(slot, &type, data)) {
        event_buf[0] = data[0];
        event_buf[1] = data[1];
        event_buf[2] = data[2];
        event_buf[3] = data[3];
        return type;
    }

    return 0; // No event
}

void hello_tty_platform_request_redraw(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_windows[slot].alive) return;
    [g_windows[slot].view setNeedsDisplay:YES];
}

int hello_tty_platform_get_vulkan_surface(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_windows[slot].alive) return 0;

    // For MoltenVK: the Vulkan surface is created from the CAMetalLayer
    // by the Vulkan instance via vkCreateMetalSurfaceEXT.
    // We return a pointer to the CAMetalLayer as an opaque handle.
    // The GPU init code will use this to create VkSurfaceKHR.
    CAMetalLayer *layer = g_windows[slot].view.metalLayer;
    return (int)(uintptr_t)(__bridge void *)layer;
}

int hello_tty_platform_get_dpi_scale(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_windows[slot].alive) return 100;

    CGFloat scale = [g_windows[slot].window backingScaleFactor];
    return (int)(scale * 100.0);
}

void hello_tty_platform_destroy_window(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_windows[slot].alive) return;

    @autoreleasepool {
        [g_windows[slot].window close];
        g_windows[slot].window = nil;
        g_windows[slot].view = nil;
        g_windows[slot].alive = 0;
    }
}

void hello_tty_platform_shutdown(void) {
    if (!g_platform.initialized) return;

    // Close all windows
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_windows[i].alive) {
            hello_tty_platform_destroy_window(i + 1);
        }
    }

    g_platform.initialized = 0;
}

int hello_tty_platform_clipboard_set(const uint8_t *text, int len) {
    @autoreleasepool {
        NSString *str = [[NSString alloc]
            initWithBytes:text
                   length:(NSUInteger)len
                 encoding:NSUTF8StringEncoding];
        if (!str) return -1;

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:str forType:NSPasteboardTypeString];
        return 0;
    }
}

int hello_tty_platform_clipboard_get(uint8_t *buf, int max_len) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if (!str) return -1;

        const char *utf8 = [str UTF8String];
        int len = (int)strlen(utf8);
        if (len > max_len) len = max_len;
        memcpy(buf, utf8, (size_t)len);
        return len;
    }
}

#endif // __APPLE__ && HELLO_TTY_PLATFORM_MACOS
