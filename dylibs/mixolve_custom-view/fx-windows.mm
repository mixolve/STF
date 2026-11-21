// mixolve_custom-view — native macOS window chrome controller.
// Hides ACTUAL NSWindow titlebars, not merely their title text.
// Main REAPER window and verified floating Track/Take FX windows only.
// Movement is exclusively user-initiated via the Move action.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <ApplicationServices/ApplicationServices.h>
#include "fx-windows.hpp"
#include <algorithm>
#include <cmath>

// Layout matches REAPER's custom_action_register_t (section, unique ID, description).
struct MXCustomAction { int section; const char *id; const char *name; };
static MXCustomAction kToggle = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_TOGGLE", "mixolve: Windows - Toggle native titlebars (REAPER + FX)"};
static MXCustomAction kMove = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_MOVE", "mixolve: Windows - Move focused window until click"};

struct MXAPI {
    void *(*mainHwnd)() = nullptr;
    int (*focused)(int *, int *, int *) = nullptr;
    void *(*project)(int, char *, int) = nullptr;
    int (*trackCount)(void *) = nullptr;
    void *(*track)(void *, int) = nullptr;
    void *(*master)(void *) = nullptr;
    int (*trackFXCount)(void *) = nullptr;
    void *(*trackFloating)(void *, int) = nullptr;
    int (*trackItemCount)(void *) = nullptr;
    void *(*trackItem)(void *, int) = nullptr;
    int (*takeCount)(void *) = nullptr;
    void *(*take)(void *, int) = nullptr;
    int (*takeFXCount)(void *) = nullptr;
    void *(*takeFloating)(void *, int) = nullptr;
    void (*log)(const char *) = nullptr;
    void (*refreshToolbar)(int, int) = nullptr;
};
static MXAPI api;
static int (*regWindow)(const char *, void *) = nullptr;
static int toggleID = 0, moveID = 0;
static bool hook1 = false, hook2 = false, toggleHookInstalled = false, automaticHide = true;
static __weak NSWindow *movingWindow = nil;
static NSPoint movingCursorOffset = NSZeroPoint;
static NSTimer *movingTimer = nil;
static id movingLocalMonitor = nil, movingGlobalMonitor = nil;
static bool movingClickArmed = false;
static __weak NSWindow *mainWindow = nil;
static __weak NSWindow *lastFX = nil;
static NSMutableArray *savedWindows = nil;
static id keyObserver = nil, closeObserver = nil, updateObserver = nil;
static CFAbsoluteTime nextUpdate = 0;

@interface MXWindowSnapshot : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic) NSWindowStyleMask style;
@property (nonatomic) NSRect frame;
@property (nonatomic) NSSize minSize;
@property (nonatomic) NSSize contentMinSize;
@property (nonatomic) NSWindowTitleVisibility titleVisibility;
@property (nonatomic) BOOL transparentTitle;
@property (nonatomic) BOOL shadow;
@property (nonatomic) BOOL toolbarVisible;
@property (nonatomic, strong) NSToolbar *toolbar;
@end
@implementation MXWindowSnapshot @end

namespace {
static void logMessage(const char *s) { if (api.log) api.log(s); }

// SWELL HWND is an Objective-C window/view on macOS. Do not treat it as an
// opaque NSWindow pointer; first ask the host object for its actual window.
static NSWindow *fromSwellHandle(void *handle) {
    if (!handle) return nil;
    id object = (__bridge id)handle;
    NSWindow *window = nil;
    if ([object isKindOfClass:[NSWindow class]]) window = (NSWindow *)object;
    else if ([object isKindOfClass:[NSView class]]) window = ((NSView *)object).window;
    else if ([object respondsToSelector:@selector(window)]) window = [object window];
    if (![window isKindOfClass:[NSWindow class]]) return nil;
    // Accept only the actual application's windows (never a foreign plug-in process).
    return [NSApp.windows containsObject:window] ? window : nil;
}
static NSWindow *resolveMain() {
    NSWindow *w = mainWindow;
    if (!w && api.mainHwnd) w = fromSwellHandle(api.mainHwnd());
    if (w) mainWindow = w;
    return w;
}
static MXWindowSnapshot *findSnapshot(NSWindow *w) {
    for (MXWindowSnapshot *s in savedWindows) if (s.window == w) return s;
    return nil;
}
static MXWindowSnapshot *remember(NSWindow *w) {
    if (!w) return nil;
    MXWindowSnapshot *s = findSnapshot(w);
    if (s) return s;
    s = [MXWindowSnapshot new];
    s.window = w;
    s.style = w.styleMask;
    s.frame = w.frame;
    s.minSize = w.minSize;
    s.contentMinSize = w.contentMinSize;
    s.titleVisibility = w.titleVisibility;
    s.transparentTitle = w.titlebarAppearsTransparent;
    s.shadow = w.hasShadow;
    s.toolbar = w.toolbar;
    s.toolbarVisible = w.toolbar.isVisible;
    [savedWindows addObject:s];
    return s;
}
static void hideTitlebar(NSWindow *w) {
    if (!w || !w.isVisible || w.isMiniaturized || w.attachedSheet || w == NSApp.modalWindow) return;
    if (!(w.styleMask & NSWindowStyleMaskTitled)) return;
    if (w.styleMask & NSWindowStyleMaskFullScreen) return; // do not interfere with macOS fullscreen
    remember(w);
    NSRect frame = w.frame;
    @try {
        // v7 only hid the title text. Removing the Titled style removes the
        // native macOS titlebar/traffic-light region itself.
        w.styleMask = (w.styleMask & ~(NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView));
        [w setFrame:frame display:YES animate:NO];
    } @catch (NSException *exception) {
        logMessage("mixolve custom-view: AppKit refused to hide a window titlebar.\n");
        (void)exception;
    }
}
static void restoreOne(MXWindowSnapshot *s, bool restorePosition) {
    NSWindow *w = s.window;
    if (!w) return;
    @try {
        NSRect currentFrame = w.frame;
        w.styleMask = s.style;
        w.titleVisibility = s.titleVisibility;
        w.titlebarAppearsTransparent = s.transparentTitle;
        w.hasShadow = s.shadow;
        w.minSize = s.minSize;
        w.contentMinSize = s.contentMinSize;
        if (s.toolbar && w.toolbar == s.toolbar) w.toolbar.visible = s.toolbarVisible;
        [w setFrame:(restorePosition ? s.frame : currentFrame) display:YES animate:NO];
    } @catch (NSException *exception) {
        logMessage("mixolve custom-view: AppKit refused to restore a window.\n");
        (void)exception;
    }
}
static void showAll() {
    automaticHide = false;
    for (MXWindowSnapshot *s in [savedWindows reverseObjectEnumerator]) restoreOne(s, false);
    [savedWindows removeAllObjects];
}
static void trackWindow(NSWindow *w, bool focused) {
    if (!w || w == resolveMain()) return;
    // Enumeration is not focus order; don't let the scan overwrite the last
    // actually focused FX window with an arbitrary open FX.
    if (focused || w == NSApp.keyWindow) lastFX = w;
    if (automaticHide) hideTitlebar(w);
}
static void checkFocusedFX() {
    if (!api.focused || !api.project || !api.track || !api.master) return;
    int trackNum = -1, itemNum = -1, fxNum = -1;
    int type = api.focused(&trackNum, &itemNum, &fxNum);
    if (!type || fxNum < 0 || trackNum < 0) return;
    void *project = api.project(-1, nullptr, 0);
    if (!project) return;
    void *track = trackNum == 0 ? api.master(project) : api.track(project, trackNum - 1);
    if (!track) return;
    void *hwnd = nullptr;
    if ((type & 1) && api.trackFloating) hwnd = api.trackFloating(track, fxNum);
    else if ((type & 2) && api.trackItem && api.take && api.takeFloating && itemNum >= 0) {
        void *item = api.trackItem(track, itemNum);
        void *take = item ? api.take(item, fxNum >> 16) : nullptr;
        if (take) hwnd = api.takeFloating(take, fxNum & 0xffff);
    }
    NSWindow *w = fromSwellHandle(hwnd);
    if (w && w != resolveMain()) trackWindow(w, true);
}
static void scanAllFloatingFX() {
    if (!api.project || !api.track || !api.trackCount || !api.trackFXCount || !api.trackFloating) return;
    void *project = api.project(-1, nullptr, 0);
    if (!project) return;
    int count = std::max(0, api.trackCount(project));
    for (int ti = -1; ti < count; ++ti) {
        void *track = ti == -1 ? (api.master ? api.master(project) : nullptr) : api.track(project, ti);
        if (!track) continue;
        int numFX = std::min(2048, std::max(0, api.trackFXCount(track)));
        for (int fx = 0; fx < numFX; ++fx) {
            NSWindow *w = fromSwellHandle(api.trackFloating(track, fx));
            if (w && w != resolveMain()) trackWindow(w, false);
        }
        if (!api.trackItemCount || !api.trackItem || !api.takeCount || !api.take || !api.takeFXCount || !api.takeFloating) continue;
        int nItems = std::max(0, api.trackItemCount(track));
        for (int itemIndex = 0; itemIndex < nItems; ++itemIndex) {
            void *item = api.trackItem(track, itemIndex);
            if (!item) continue;
            int nTakes = std::min(128, std::max(0, api.takeCount(item)));
            for (int takeIndex = 0; takeIndex < nTakes; ++takeIndex) {
                void *take = api.take(item, takeIndex);
                if (!take) continue;
                int nFX = std::min(2048, std::max(0, api.takeFXCount(take)));
                for (int fx = 0; fx < nFX; ++fx) {
                    NSWindow *w = fromSwellHandle(api.takeFloating(take, fx));
                    if (w && w != resolveMain()) trackWindow(w, false);
                }
            }
        }
    }
}
static void hideAll() {
    automaticHide = true;
    NSWindow *main = resolveMain();
    if (main) hideTitlebar(main);
    scanAllFloatingFX();
    checkFocusedFX();
}
// The window follows the cursor at 60 Hz even when pointer events are sent
// to another application. The next mouse click finishes placement. We use
// both local and global monitors: local events aren't delivered to a global
// monitor, and vice versa. Polling button state is an additional fallback.
static void stopMoving() {
    // Invalidate the timer before touching the monitor state.
    if (movingTimer) { [movingTimer invalidate]; movingTimer = nil; }
    if (movingLocalMonitor) { [NSEvent removeMonitor:movingLocalMonitor]; movingLocalMonitor = nil; }
    if (movingGlobalMonitor) { [NSEvent removeMonitor:movingGlobalMonitor]; movingGlobalMonitor = nil; }
    movingWindow = nil;
    movingClickArmed = false;
}
static bool mouseDownNow() {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
           CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight);
}
static bool isMoveCandidate(NSWindow *w) {
    if (!w || !w.isVisible || w.isMiniaturized || w.attachedSheet || w == NSApp.modalWindow) return false;
    if (w.styleMask & NSWindowStyleMaskFullScreen) return false;
    // Only move the REAPER main window or a previously identified Track/Take FX window.
    return w == resolveMain() || w == lastFX || findSnapshot(w) != nil;
}
static NSWindow *focusedMoveTarget() {
    // The foreground window must win over a previously focused FX window.
    NSWindow *key = NSApp.keyWindow;
    if (isMoveCandidate(key)) return key;
    // The action list can steal focus; retain the last verified floating FX.
    if (isMoveCandidate(lastFX)) return lastFX;
    NSWindow *main = resolveMain();
    if (isMoveCandidate(main)) return main;
    return nil;
}
// Magnetic placement is active only while Move Until Click is running.
// Snap each axis independently to screen edges or a nearby REAPER/FX window.
// All coordinates use AppKit's global bottom-left screen coordinate system.
static constexpr CGFloat kWindowSnapDistance = 14.0;

static bool overlapWithTolerance(CGFloat a0, CGFloat a1, CGFloat b0, CGFloat b1) {
    return std::min(a1, b1) >= std::max(a0, b0) - kWindowSnapDistance;
}

static void offerSnap(CGFloat proposed, CGFloat candidate, CGFloat &bestDelta, CGFloat &result) {
    CGFloat delta = std::fabs(candidate - proposed);
    if (delta <= kWindowSnapDistance && delta < bestDelta) {
        bestDelta = delta;
        result = candidate;
    }
}

static NSPoint snapWindowOrigin(NSWindow *moving, NSPoint proposed) {
    if (!moving) return proposed;
    NSRect r = NSMakeRect(proposed.x, proposed.y, moving.frame.size.width, moving.frame.size.height);
    CGFloat x = proposed.x, y = proposed.y;
    CGFloat dx = kWindowSnapDistance + 1, dy = kWindowSnapDistance + 1;

    // Screen.visibleFrame excludes the macOS menu bar and Dock.
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect visible = screen.visibleFrame;
        if (overlapWithTolerance(NSMinY(r), NSMaxY(r), NSMinY(visible), NSMaxY(visible))) {
            offerSnap(proposed.x, NSMinX(visible), dx, x);
            offerSnap(proposed.x, NSMaxX(visible) - NSWidth(r), dx, x);
        }
        if (overlapWithTolerance(NSMinX(r), NSMaxX(r), NSMinX(visible), NSMaxX(visible))) {
            offerSnap(proposed.y, NSMinY(visible), dy, y);
            offerSnap(proposed.y, NSMaxY(visible) - NSHeight(r), dy, y);
        }
    }

    // Only align with windows REAPER has confirmed as its own main/FX windows.
    // Check perpendicular overlap so distant windows do not attract the target.
    for (NSWindow *other in NSApp.windows) {
        if (other == moving || !isMoveCandidate(other) || !other.isVisible || other.isMiniaturized) continue;
        NSRect b = other.frame;
        if (overlapWithTolerance(NSMinY(r), NSMaxY(r), NSMinY(b), NSMaxY(b))) {
            offerSnap(proposed.x, NSMinX(b) - NSWidth(r), dx, x); // right to left
            offerSnap(proposed.x, NSMaxX(b), dx, x);               // left to right
            offerSnap(proposed.x, NSMinX(b), dx, x);               // align left
            offerSnap(proposed.x, NSMaxX(b) - NSWidth(r), dx, x);  // align right
        }
        if (overlapWithTolerance(NSMinX(r), NSMaxX(r), NSMinX(b), NSMaxX(b))) {
            offerSnap(proposed.y, NSMinY(b) - NSHeight(r), dy, y); // top to bottom
            offerSnap(proposed.y, NSMaxY(b), dy, y);                // bottom to top
            offerSnap(proposed.y, NSMinY(b), dy, y);                // align bottom
            offerSnap(proposed.y, NSMaxY(b) - NSHeight(r), dy, y); // align top
        }
    }
    return NSMakePoint(x, y);
}

static void updateMovingWindow() {
    NSWindow *w = movingWindow;
    if (!w || !w.isVisible || w.isMiniaturized) { stopMoving(); return; }
    if (mouseDownNow()) {
        if (movingClickArmed) { stopMoving(); return; }
    } else {
        movingClickArmed = true;
    }
    NSPoint cursor = [NSEvent mouseLocation]; // Global screen coordinates.
    NSPoint newOrigin = NSMakePoint(cursor.x - movingCursorOffset.x,
                                    cursor.y - movingCursorOffset.y);
    newOrigin = snapWindowOrigin(w, newOrigin);
    NSPoint oldOrigin = w.frame.origin;
    if (std::fabs(newOrigin.x - oldOrigin.x) > 0.1 || std::fabs(newOrigin.y - oldOrigin.y) > 0.1)
        [w setFrameOrigin:newOrigin];
}
static void toggleMoving() {
    // A second invocation cancels the placement mode at the current position.
    if (movingWindow) { stopMoving(); return; }
    // Refresh the last-known FX target when REAPER has just switched focus.
    checkFocusedFX();
    NSWindow *w = focusedMoveTarget();
    if (!w) {
        logMessage("mixolve custom-view: no focused REAPER/FX window to move.\n");
        return;
    }
    NSPoint cursor = [NSEvent mouseLocation];
    NSPoint origin = w.frame.origin;
    movingCursorOffset = NSMakePoint(cursor.x - origin.x, cursor.y - origin.y);
    movingWindow = w;
    movingClickArmed = !mouseDownNow();
    NSEventMask clickMask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    movingLocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:clickMask
        handler:^NSEvent *(NSEvent *event) {
            if (!movingWindow) return event;
            if (!movingClickArmed) return event; // Ignore the click that invoked the action.
            stopMoving();
            return nil; // Don't activate a REAPER control when placing the window.
        }];
    movingGlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:clickMask
        handler:^(__unused NSEvent *event) {
            if ([NSThread isMainThread]) stopMoving();
            else dispatch_async(dispatch_get_main_queue(), ^{ stopMoving(); });
        }];
    // Mouse coordinates are polled, so movement is smooth even outside the
    // REAPER window; no mouse-moved event delivery or mouse-down drag needed.
    movingTimer = [NSTimer timerWithTimeInterval:1.0/60.0 repeats:YES
        block:^(__unused NSTimer *timer) { updateMovingWindow(); }];
    // Continue ticking during standard menu / tracking run-loop modes.
    [[NSRunLoop mainRunLoop] addTimer:movingTimer forMode:NSRunLoopCommonModes];
}
static void toggleChrome() {
    if (automaticHide) showAll();
    else hideAll();
    if (api.refreshToolbar && toggleID > 0) api.refreshToolbar(0, toggleID);
}
static int toggleState(int command) {
    if (command == toggleID) return automaticHide ? 1 : 0;
    return -1;
}
static void runCommand(int command) {
    if (command == toggleID) toggleChrome();
    else if (command == moveID) toggleMoving();
}
static bool dispatchCommand(int command) {
    if (!regWindow || (command != toggleID && command != moveID)) return false;
    if ([NSThread isMainThread]) {
        @autoreleasepool { runCommand(command); }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { if (regWindow) runCommand(command); } });
    }
    return true;
}
static bool onCommand(int command, int flag) { (void)flag; return dispatchCommand(command); }
static bool onCommand2(void *section, int command, int val, int valhw, int relmode, void *hwnd) {
    (void)section; (void)val; (void)valhw; (void)relmode; (void)hwnd;
    return dispatchCommand(command);
}
static void clearObservers() {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (keyObserver) { [center removeObserver:keyObserver]; keyObserver = nil; }
    if (closeObserver) { [center removeObserver:closeObserver]; closeObserver = nil; }
    if (updateObserver) { [center removeObserver:updateObserver]; updateObserver = nil; }
}
} // namespace

extern "C" bool MixolveFXWindowsStart(ep::Info *info) {
    if (!info || !info->get || !info->reg) return false;
    if (regWindow) return true;
    api.mainHwnd = reinterpret_cast<decltype(api.mainHwnd)>(info->get("GetMainHwnd"));
    api.focused = reinterpret_cast<decltype(api.focused)>(info->get("GetFocusedFX2"));
    api.project = reinterpret_cast<decltype(api.project)>(info->get("EnumProjects"));
    api.trackCount = reinterpret_cast<decltype(api.trackCount)>(info->get("CountTracks"));
    api.track = reinterpret_cast<decltype(api.track)>(info->get("GetTrack"));
    api.master = reinterpret_cast<decltype(api.master)>(info->get("GetMasterTrack"));
    api.trackFXCount = reinterpret_cast<decltype(api.trackFXCount)>(info->get("TrackFX_GetCount"));
    api.trackFloating = reinterpret_cast<decltype(api.trackFloating)>(info->get("TrackFX_GetFloatingWindow"));
    api.trackItemCount = reinterpret_cast<decltype(api.trackItemCount)>(info->get("CountTrackMediaItems"));
    api.trackItem = reinterpret_cast<decltype(api.trackItem)>(info->get("GetTrackMediaItem"));
    api.takeCount = reinterpret_cast<decltype(api.takeCount)>(info->get("CountTakes"));
    api.take = reinterpret_cast<decltype(api.take)>(info->get("GetTake"));
    api.takeFXCount = reinterpret_cast<decltype(api.takeFXCount)>(info->get("TakeFX_GetCount"));
    api.takeFloating = reinterpret_cast<decltype(api.takeFloating)>(info->get("TakeFX_GetFloatingWindow"));
    api.log = reinterpret_cast<decltype(api.log)>(info->get("ShowConsoleMsg"));
    api.refreshToolbar = reinterpret_cast<decltype(api.refreshToolbar)>(info->get("RefreshToolbar2"));
    mainWindow = fromSwellHandle(info->main);
    regWindow = info->reg;
    toggleID = regWindow("custom_action", &kToggle);
    if (toggleID <= 0) goto fail;
    moveID = regWindow("custom_action", &kMove);
    if (moveID <= 0) goto fail;
    hook2 = regWindow("hookcommand2", reinterpret_cast<void *>(onCommand2)) != 0;
    hook1 = regWindow("hookcommand", reinterpret_cast<void *>(onCommand)) != 0;
    if (!hook1 && !hook2) goto fail;
    toggleHookInstalled = regWindow("toggleaction", reinterpret_cast<void *>(toggleState)) != 0;
    savedWindows = [NSMutableArray new];
    @autoreleasepool {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        keyObserver = [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSWindow *w = note.object;
            if (w == resolveMain()) { if (automaticHide) hideTitlebar(w); }
            else if (w) checkFocusedFX();
        }];
        closeObserver = [center addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSWindow *w = note.object;
            if (w == movingWindow) stopMoving();
            if (w == lastFX) lastFX = nil;
            if (w == mainWindow) mainWindow = nil;
            MXWindowSnapshot *s = findSnapshot(w);
            if (s) [savedWindows removeObject:s];
        }];
        updateObserver = [center addObserverForName:NSApplicationDidUpdateNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            // An FX window can receive NSWindowDidBecomeKey before REAPER updates
            // its own focused-FX record. Retry on normal UI updates, not a timer.
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now < nextUpdate) return;
            nextUpdate = now + 0.4;
            if (automaticHide) {
                NSWindow *main = resolveMain();
                if (main) hideTitlebar(main);
                checkFocusedFX();
            }
        }];
        hideAll(); // Main REAPER window now hides immediately on startup.
    }
    return true;
fail:
    stopMoving();
    if (toggleHookInstalled) regWindow("-toggleaction", reinterpret_cast<void *>(toggleState));
    if (hook1) regWindow("-hookcommand", reinterpret_cast<void *>(onCommand));
    if (hook2) regWindow("-hookcommand2", reinterpret_cast<void *>(onCommand2));
    if (moveID > 0) regWindow("-custom_action", &kMove);
    if (toggleID > 0) regWindow("-custom_action", &kToggle);
    toggleID = moveID = 0; hook1 = hook2 = toggleHookInstalled = false;
    regWindow = nullptr; api = MXAPI{};
    return false;
}
extern "C" void MixolveFXWindowsStop() {
    if (!regWindow) return;
    @autoreleasepool {
        stopMoving();
        clearObservers();
        showAll();
        savedWindows = nil;
        mainWindow = nil;
        lastFX = nil;
    }
    if (toggleHookInstalled) regWindow("-toggleaction", reinterpret_cast<void *>(toggleState));
    if (hook1) regWindow("-hookcommand", reinterpret_cast<void *>(onCommand));
    if (hook2) regWindow("-hookcommand2", reinterpret_cast<void *>(onCommand2));
    if (moveID > 0) regWindow("-custom_action", &kMove);
    if (toggleID > 0) regWindow("-custom_action", &kToggle);
    toggleID = moveID = 0; hook1 = hook2 = toggleHookInstalled = false;
    regWindow = nullptr; api = MXAPI{};
}
