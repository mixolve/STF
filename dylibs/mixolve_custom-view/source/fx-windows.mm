// mixolve_custom-view — native macOS window chrome controller.
// Removes visible window chrome while preserving REAPER FX editor layout.
// Main REAPER window and floating Track/Take/Input/Monitoring FX.
// FX Chain windows are explicitly excluded from all titlebar changes.
// Movement is exclusively user-initiated via the Move action.
// Focus persists for borderless FX windows (including Monitoring FX).
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <ApplicationServices/ApplicationServices.h>
#include "fx-windows.hpp"
#include "objc-hooks.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

// Layout matches REAPER's custom_action_register_t (section, unique ID, description).
struct MXCustomAction { int section; const char *id; const char *name; };
// Preserve the existing action IDs so REAPER shortcuts remain assigned.
static MXCustomAction kToggle = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_TOGGLE", "mixolve_custom-view: toggle titlebar + native resize (reaper + fx)"};
static MXCustomAction kMove = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_MOVE", "mixolve_custom-view: move"};
static MXCustomAction kFocusedToggle = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_FOCUSED_TOGGLE", "mixolve_custom-view: toggle titlebar + native resize focused"};
static MXCustomAction kPresetToggle = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_PRESET_FOCUSED_TOGGLE", "mixolve_custom-view: toggle preset panel focused"};
static MXCustomAction kPresetAllToggle = {0, "MIXOLVE_CUSTOMVIEW_WINDOWS_PRESET_ALL_TOGGLE", "mixolve_custom-view: toggle preset panels (fx)"};
static MXCustomAction kArrangeScrollbarsToggle = {
    0, "MIXOLVE_CUSTOMVIEW_ARRANGE_SCROLLBARS_TOGGLE", "mixolve_custom-view: toggle arrange scrollbars"
};

struct MXAPI {
    void *(*mainHwnd)() = nullptr;
    signed char (*showScrollBar)(void *, int, signed char) = nullptr;
    int (*focused)(int *, int *, int *) = nullptr;
    // Modern REAPER API: indices differ from deprecated GetFocusedFX2().
    bool (*touchedOrFocused)(int, int *, int *, int *, int *, int *) = nullptr;
    void *(*project)(int, char *, int) = nullptr;
    int (*trackCount)(void *) = nullptr;
    void *(*track)(void *, int) = nullptr;
    void *(*master)(void *) = nullptr;
    int (*trackFXCount)(void *) = nullptr;
    int (*trackRecFXCount)(void *) = nullptr;  // On master this counts Monitoring FX.
    void *(*trackFloating)(void *, int) = nullptr;
    int (*trackItemCount)(void *) = nullptr;
    void *(*trackItem)(void *, int) = nullptr;
    int (*takeCount)(void *) = nullptr;
    void *(*take)(void *, int) = nullptr;
    int (*takeFXCount)(void *) = nullptr;
    void *(*takeFloating)(void *, int) = nullptr;
    void (*refreshToolbar)(int, int) = nullptr;
    const char *(*getExtState)(const char *, const char *) = nullptr;
    void (*setExtState)(const char *, const char *, const char *, bool) = nullptr;
    const void *(*trackFXGUID)(void *, int) = nullptr;
    const void *(*takeFXGUID)(void *, int) = nullptr;
};
static MXAPI api;
static int (*regWindow)(const char *, void *) = nullptr;
static int toggleID = 0, moveID = 0, focusedToggleID = 0, presetToggleID = 0, presetAllToggleID = 0;
static bool hook1 = false, hook2 = false, toggleHookInstalled = false, automaticHide = true;
static bool automaticPresetHide = false;
static int arrangeScrollbarsToggleID = 0;
static bool arrangeScrollbarsHidden = false;
static __weak NSView *arrangeScrollbarView = nil;
static bool applyingArrangeScrollbars = false;
static unsigned long long presetGeneration = 0;
static const char *kSettingsSection = "mixolve_custom-view";
static const char *kArrangeScrollbarsKey = "arrange_scrollbars_hidden_v1";
static const char *kPresetAllKey = "preset_all_hidden_v1";
static const char *kPresetGenerationKey = "preset_override_generation_v1";
static __weak NSWindow *movingWindow = nil;
static NSPoint movingCursorOffset = NSZeroPoint;
static NSTimer *movingTimer = nil;
static id movingLocalMonitor = nil, movingGlobalMonitor = nil;
static bool movingClickArmed = false;
static __weak NSWindow *mainWindow = nil;
static __weak NSWindow *lastFX = nil;
// True only for user/API focus or explicit action choice, not enumeration.
static bool lastFXChosen = false;
// Applying a style mask can cause macOS to make REAPER's main window key.
// Retain the last explicitly focused FX until the user actually clicks main.
static bool mainExplicitlySelected = false;
static id focusMouseObserver = nil;
static NSMutableArray *savedWindows = nil;
// Weak keys ensure closed/replaced FX windows are not retained. A per-window
// override is essential: otherwise the automatic global hide pass immediately
// hides a window that the user just showed using Focused Toggle.
static NSMapTable<NSWindow *, NSNumber *> *chromeOverrides = nil;
static NSHashTable<NSWindow *> *knownFXWindows = nil;
static NSHashTable<NSButton *> *hiddenFXPins = nil;
static NSMutableArray *savedPresetPanels = nil;
// Weak keys avoid retaining REAPER FX windows after they are closed.
static NSMapTable<NSWindow *, NSNumber *> *presetOverrides = nil;
// Stable FX GUIDs are used to restore focused per-FX overrides after restart.
static NSMapTable<NSWindow *, NSString *> *presetWindowKeys = nil;
static id keyObserver = nil, closeObserver = nil, resizeObserver = nil, updateObserver = nil, terminateObserver = nil;
static bool applicationTerminating = false;
static CFAbsoluteTime nextUpdate = 0;
static CFAbsoluteTime nextFullFXScan = 0;
static uint64_t lastWindowSignature = 0;

@interface MXWindowSnapshot : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic) NSWindowStyleMask style;
@property (nonatomic) NSSize minSize;
@property (nonatomic) NSSize contentMinSize;
@property (nonatomic) NSWindowTitleVisibility titleVisibility;
@property (nonatomic) BOOL transparentTitle;
@property (nonatomic) NSTitlebarSeparatorStyle titlebarSeparator;
@property (nonatomic) NSUInteger hiddenTitlebarButtons;
@property (nonatomic) BOOL shadow;
@property (nonatomic) BOOL toolbarVisible;
@property (nonatomic, strong) NSToolbar *toolbar;
@end
@implementation MXWindowSnapshot @end

// Keeps only views belonging to a verified REAPER floating FX window.
// Never changes the plug-in's own NSView hierarchy.
// The original REAPER/SWELL contentView MUST remain the NSWindow contentView.
// Reparenting it (v20-v22) changes the identity seen by host code and may
// invalidate its assumptions about the view hierarchy and event delivery.
// Crop the host top row by temporarily increasing the existing content view's
// height relative to the visible NSWindow content rect, without reparenting.
@interface MXPresetPanelSnapshot : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, strong) NSView *contentRoot;
@property (nonatomic) NSUInteger originalAutoresizingMask;
@property (nonatomic) NSSize previousContentMinSize;
@property (nonatomic) CGFloat removedHeight;
// The frame may refuse the requested shrink (e.g. during host re-layout).
// Restore only the height that NSWindow actually lost.
@property (nonatomic) CGFloat appliedWindowCrop;
@end
@implementation MXPresetPanelSnapshot @end

namespace {
// Forward declarations must share the anonymous namespace with their definitions.
static bool isHostFXChainWindow(NSWindow *w);
static bool isFloatingFXWindow(NSWindow *candidate);
static bool isMonitoringFXEditor(NSWindow *w);
static bool validFocusedFX(NSWindow *w);
static NSWindow *focusedFXTarget();
static NSWindow *focusedFXTargetForHostControls();
static void applyPreset(NSWindow *w);
static NSString *presetKeyForWindow(NSWindow *w);
static NSNumber *getPresetOverride(NSWindow *w);
static CGFloat presetCropHeight(NSWindow *w);
static MXPresetPanelSnapshot *findPresetSnapshot(NSWindow *w);
static void reconcileMonitoringHeightBeforeChrome(NSWindow *w);
static void rememberMonitoringHeightFromUserResize(NSWindow *w);

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
static NSView *resolveArrangeView() {
    void *main = api.mainHwnd ? api.mainHwnd() : nullptr;
    auto swell = mx::findSwellAPI();
    using GetDlgItem = void *(*)(void *, int);
    auto getDlgItem = swell ? reinterpret_cast<GetDlgItem>(swell("GetDlgItem")) : nullptr;
    if (!main || !getDlgItem) return nil;

    constexpr int arrangeControlID = 1000;
    id control = (__bridge id)getDlgItem(main, arrangeControlID);
    return [control isKindOfClass:NSView.class] && [(NSView *)control window] == resolveMain()
        ? control : nil;
}
static bool setArrangeScrollbarsVisible(NSView *view, bool visible) {
    constexpr int bothScrollbars = 3; // SB_BOTH
    applyingArrangeScrollbars = true;
    const bool changed = api.showScrollBar((__bridge void *)view, bothScrollbars, visible) != 0;
    applyingArrangeScrollbars = false;
    if (changed) [view setNeedsDisplay:YES];
    return changed;
}
static bool arrangeScrollbarsHaveInsets(NSView *view) {
    struct SwellRect { int left, top, right, bottom; };
    using GetRect = void (*)(void *, SwellRect *);
    auto swell = mx::findSwellAPI();
    if (!swell) return false;
    auto getClient = reinterpret_cast<GetRect>(swell("GetClientRect"));
    auto getContent = reinterpret_cast<GetRect>(swell("GetWindowContentViewRect"));
    if (!getClient || !getContent) return false;
    SwellRect client{}, content{};
    void *hwnd = (__bridge void *)view;
    getClient(hwnd, &client);
    getContent(hwnd, &content);
    return std::abs(client.right - client.left) < std::abs(content.right - content.left) ||
           std::abs(client.bottom - client.top) < std::abs(content.bottom - content.top);
}
static void applyArrangeScrollbarSetting() {
    if (!arrangeScrollbarsToggleID || !arrangeScrollbarsHidden || applyingArrangeScrollbars) return;
    NSView *view = resolveArrangeView();
    if (view && (view != arrangeScrollbarView || arrangeScrollbarsHaveInsets(view)) &&
        setArrangeScrollbarsVisible(view, false))
        arrangeScrollbarView = view;
}
static void toggleArrangeScrollbars() {
    NSView *view = resolveArrangeView();
    if (!view || !setArrangeScrollbarsVisible(view, arrangeScrollbarsHidden)) return;
    arrangeScrollbarsHidden = !arrangeScrollbarsHidden;
    arrangeScrollbarView = arrangeScrollbarsHidden ? view : nil;
    if (api.setExtState)
        api.setExtState(kSettingsSection, kArrangeScrollbarsKey,
                        arrangeScrollbarsHidden ? "1" : "0", true);
    if (api.refreshToolbar) api.refreshToolbar(0, arrangeScrollbarsToggleID);
}
static MXWindowSnapshot *findSnapshot(NSWindow *w) {
    for (MXWindowSnapshot *s in savedWindows) if (s.window == w) return s;
    return nil;
}
static constexpr NSWindowButton titlebarButtons[] = {
    NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton
};
static MXWindowSnapshot *remember(NSWindow *w) {
    if (!w) return nil;
    MXWindowSnapshot *s = findSnapshot(w);
    if (s) return s;
    s = [MXWindowSnapshot new];
    s.window = w;
    s.style = w.styleMask;
    s.minSize = w.minSize;
    s.contentMinSize = w.contentMinSize;
    s.titleVisibility = w.titleVisibility;
    s.transparentTitle = w.titlebarAppearsTransparent;
    s.titlebarSeparator = w.titlebarSeparatorStyle;
    for (NSUInteger i = 0; i < sizeof(titlebarButtons) / sizeof(titlebarButtons[0]); ++i) {
        if ([w standardWindowButton:titlebarButtons[i]].isHidden)
            s.hiddenTitlebarButtons |= NSUInteger(1) << i;
    }
    s.shadow = w.hasShadow;
    s.toolbar = w.toolbar;
    s.toolbarVisible = w.toolbar.isVisible;
    [savedWindows addObject:s];
    return s;
}
static void hideTitlebar(NSWindow *w) {
    if (!w || !w.isVisible || w.isMiniaturized || w.attachedSheet || w == NSApp.modalWindow) return;
    if (!(w.styleMask & NSWindowStyleMaskTitled) || findSnapshot(w)) return;
    if (w.styleMask & NSWindowStyleMaskFullScreen) return;
    remember(w);
    NSRect frame = w.frame;
    NSRect content = [w contentRectForFrameRect:frame];
    @try {
        if (w == resolveMain()) {
            w.styleMask &= ~(NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView |
                             NSWindowStyleMaskResizable);
            if (!NSEqualRects(w.frame, frame)) [w setFrame:frame display:YES animate:NO];
            return;
        }

        // SWELL can move a VST editor outside its host when the titled bit
        // changes. Draw content through a transparent titlebar instead.
        w.titlebarAppearsTransparent = YES;
        w.titleVisibility = NSWindowTitleHidden;
        w.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
        w.styleMask = (w.styleMask | NSWindowStyleMaskFullSizeContentView) &
                      ~NSWindowStyleMaskResizable;
        for (NSWindowButton button : titlebarButtons)
            [w standardWindowButton:button].hidden = YES;
        NSRect target = [w frameRectForContentRect:content];
        if (!NSEqualRects(w.frame, target)) [w setFrame:target display:YES animate:NO];
    } @catch (__unused NSException *exception) {}
}
static void restoreOne(MXWindowSnapshot *s) {
    NSWindow *w = s.window;
    if (!w) return;
    @try {
        NSRect frame = w.frame;
        NSRect content = [w contentRectForFrameRect:frame];
        const bool isMain = w == resolveMain();
        w.styleMask = s.style;
        w.titleVisibility = s.titleVisibility;
        w.titlebarAppearsTransparent = s.transparentTitle;
        w.titlebarSeparatorStyle = s.titlebarSeparator;
        w.hasShadow = s.shadow;
        for (NSUInteger i = 0; i < sizeof(titlebarButtons) / sizeof(titlebarButtons[0]); ++i)
            [w standardWindowButton:titlebarButtons[i]].hidden = (s.hiddenTitlebarButtons >> i) & 1;
        if (isMain) {
            w.minSize = s.minSize;
            w.contentMinSize = s.contentMinSize;
        }
        if (s.toolbar && w.toolbar == s.toolbar) w.toolbar.visible = s.toolbarVisible;
        // With the preset row hidden, AppKit can use the oversized root
        // to size the new frame. Keep the visible editor viewport instead.
        NSRect target = isMain ? frame : [w frameRectForContentRect:content];
        if (!NSEqualRects(w.frame, target)) [w setFrame:target display:YES animate:NO];
    } @catch (__unused NSException *exception) {}
}
// Restoring a single focused window must not restore its initial screen
// coordinates: Move Until Click and manual positioning must be preserved.
static void restoreTitlebarOnly(NSWindow *w) {
    MXWindowSnapshot *snapshot = findSnapshot(w);
    if (!snapshot) return;
    restoreOne(snapshot);
    [savedWindows removeObject:snapshot];
}
static bool shouldHideChrome(NSWindow *w) {
    NSNumber *value = [chromeOverrides objectForKey:w];
    return value ? value.boolValue : automaticHide;
}
static void applyChrome(NSWindow *w) {
    if (!w) return;
    if (shouldHideChrome(w)) hideTitlebar(w);
    else restoreTitlebarOnly(w);
}
static void showAll() {
    automaticHide = false;
    [chromeOverrides removeAllObjects];
    for (MXWindowSnapshot *s in [savedWindows reverseObjectEnumerator]) restoreOne(s);
    [savedWindows removeAllObjects];
}
// Each REAPER FX instance has a stable 16-byte GUID, unlike its NSWindow pointer.
// Storing keys by GUID makes focused overrides survive FX window reconstruction.
static NSString *keyForFXGUID(const void *guid) {
    if (!guid) return nil;
    const unsigned char *bytes = reinterpret_cast<const unsigned char *>(guid);
    static const char hex[] = "0123456789abcdef";
    char key[3 + 32 + 1];
    key[0] = 'f'; key[1] = 'x'; key[2] = '_';
    for (int i = 0; i < 16; ++i) {
        key[3 + i * 2] = hex[bytes[i] >> 4];
        key[4 + i * 2] = hex[bytes[i] & 15];
    }
    key[35] = 0;
    return [NSString stringWithUTF8String:key];
}
static void registerPresetGUID(NSWindow *window, const void *guid) {
    if (!window || !guid || !presetWindowKeys) return;
    NSString *key = keyForFXGUID(guid);
    if (key.length) {
        NSString *oldKey = [presetWindowKeys objectForKey:window];
        if (oldKey && ![oldKey isEqualToString:key])
            [presetOverrides removeObjectForKey:window];
        [presetWindowKeys setObject:key forKey:window];
    }
}
static NSString *presetKeyForWindow(NSWindow *w) {
    if (!w) return nil;
    NSString *key = [presetWindowKeys objectForKey:w];
    if (key) return key;
    // Monitoring editors may not be enumerated by TrackFX_GetFloatingWindow
    // on some SWELL versions; their title is the only available stable key.
    if (!isMonitoringFXEditor(w)) return nil;
    NSString *name = [[w.title lowercaseString] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return nil;
    const char *utf8 = name.UTF8String;
    uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(utf8); *p; ++p) {
        hash ^= *p;
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"monitoring_%016llx", (unsigned long long)hash];
}
static void loadPresetSettings() {
    automaticPresetHide = false;
    presetGeneration = 0;
    if (!api.getExtState) return;
    const char *all = api.getExtState(kSettingsSection, kPresetAllKey);
    automaticPresetHide = all && std::strcmp(all, "1") == 0;
    const char *generation = api.getExtState(kSettingsSection, kPresetGenerationKey);
    if (generation && *generation) {
        char *end = nullptr;
        unsigned long long value = std::strtoull(generation, &end, 10);
        if (end && *end == 0) presetGeneration = value;
    }
}
static void persistGlobalPresetState() {
    if (!api.setExtState) return;
    api.setExtState(kSettingsSection, kPresetAllKey, automaticPresetHide ? "1" : "0", true);
    NSString *epoch = [NSString stringWithFormat:@"%llu", presetGeneration];
    api.setExtState(kSettingsSection, kPresetGenerationKey, epoch.UTF8String, true);
}
static NSNumber *getPresetOverride(NSWindow *w) {
    NSNumber *cached = [presetOverrides objectForKey:w];
    if (cached) return cached;
    if (!api.getExtState) return nil;
    NSString *key = presetKeyForWindow(w);
    if (!key.length) return nil;
    const char *saved = api.getExtState(kSettingsSection, key.UTF8String);
    if (!saved || !*saved) return nil;
    NSString *value = [NSString stringWithUTF8String:saved];
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@":"];
    if (parts.count != 2) return nil;
    NSString *epoch = [NSString stringWithFormat:@"%llu", presetGeneration];
    if (![parts[0] isEqualToString:epoch] ||
        !([parts[1] isEqualToString:@"0"] || [parts[1] isEqualToString:@"1"])) return nil;
    cached = @([parts[1] isEqualToString:@"1"]);
    [presetOverrides setObject:cached forKey:w];
    return cached;
}
static void saveFocusedPresetState(NSWindow *w, BOOL hidden) {
    [presetOverrides setObject:@(hidden) forKey:w];
    NSString *key = presetKeyForWindow(w);
    if (api.setExtState && key.length) {
        NSString *stored = [NSString stringWithFormat:@"%llu:%d", presetGeneration, hidden ? 1 : 0];
        api.setExtState(kSettingsSection, key.UTF8String, stored.UTF8String, true);
    }
}
// Monitoring FX geometry guard. Some SWELL builds persist an additional
// title/preset row as if it belonged to the plug-in editor each time the FX
// window is reconstructed. Preserve the unmodified TITLED frame dimensions
// across reconstruction and correct *only* integral row-sized drift. Never
// modify a borderless live window here, and never touch the plug-in NSViews.
// This is deliberately limited to Monitoring FX rather than all floating FX.
static NSString *monitoringGeometryKey(NSWindow *w) {
    if (!isMonitoringFXEditor(w)) return nil;
    NSString *title = [[w.title lowercaseString] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const char *bytes = title.UTF8String;
    if (!bytes || !*bytes) return nil;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(bytes); *p; ++p) {
        hash ^= *p;
        hash *= UINT64_C(1099511628211);
    }
    return [NSString stringWithFormat:@"monitor_geometry_v1_%016llx", (unsigned long long)hash];
}
static bool loadMonitoringGeometry(NSWindow *w, CGFloat *width, CGFloat *height) {
    if (!api.getExtState || !width || !height) return false;
    NSString *key = monitoringGeometryKey(w);
    if (!key) return false;
    const char *stored = api.getExtState(kSettingsSection, key.UTF8String);
    NSString *value = stored ? [NSString stringWithUTF8String:stored] : nil;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@","];
    if (parts.count != 2) return false;
    double a = [parts[0] doubleValue], b = [parts[1] doubleValue];
    if (!std::isfinite(a) || !std::isfinite(b) || a < 180.0 || b < 110.0 ||
        a > 10000.0 || b > 10000.0) return false;
    *width = a;
    *height = b;
    return true;
}
static void saveMonitoringGeometry(NSWindow *w, CGFloat width, CGFloat height) {
    if (!api.setExtState || width < 180.0 || height < 110.0 ||
        !std::isfinite(width) || !std::isfinite(height)) return;
    NSString *key = monitoringGeometryKey(w);
    if (!key) return;
    NSString *value = [NSString stringWithFormat:@"%.3f,%.3f", (double)width, (double)height];
    api.setExtState(kSettingsSection, key.UTF8String, value.UTF8String, true);
}
// Accept a one-to-several row drift, but do not override arbitrary geometry:
// a different plug-in layout or an intentionally different size wins.
static bool matchesRepeatedHostRow(CGFloat extra, CGFloat row) {
    if (!std::isfinite(row) || row < 16.0 || row > 90.0 || extra < 14.0) return false;
    for (int count = 1; count <= 8; ++count) {
        CGFloat expected = count * row;
        if (std::fabs(extra - expected) <= std::max<CGFloat>(2.0, count * 0.75))
            return true;
    }
    return false;
}
static void reconcileMonitoringHeightBeforeChrome(NSWindow *w) {
    if (!w || !w.isVisible || w.isMiniaturized ||
        !(w.styleMask & NSWindowStyleMaskTitled) ||
        (w.styleMask & NSWindowStyleMaskFullScreen)) return;
    NSRect frame = w.frame;
    NSView *content = w.contentView;
    if (!content || NSWidth(frame) < 180.0 || NSHeight(frame) < 150.0 ||
        NSWidth(content.bounds) < 160.0 || NSHeight(content.bounds) < 100.0)
        return; // Wait for a proper SWELL FX view; never calibrate a placeholder.

    CGFloat savedWidth = 0, savedHeight = 0;
    if (!loadMonitoringGeometry(w, &savedWidth, &savedHeight)) {
        // Calibrate once from the untouched host frame. User-initiated editor
        // resizes below can subsequently update this reference explicitly.
        saveMonitoringGeometry(w, NSWidth(frame), NSHeight(frame));
        return;
    }
    if (std::fabs(savedWidth - NSWidth(frame)) > 2.0) return;
    CGFloat extra = NSHeight(frame) - savedHeight;
    if (extra < 14.0) return;
    NSRect contentRect = [w contentRectForFrameRect:frame];
    CGFloat titleHeight = NSHeight(frame) - NSHeight(contentRect);
    CGFloat stripHeight = presetCropHeight(w);
    if (!matchesRepeatedHostRow(extra, titleHeight) &&
        !matchesRepeatedHostRow(extra, stripHeight)) return;
    // Resize BEFORE changing NSWindow.styleMask. Never run the v33 path that
    // resized a borderless window after SWELL had already relaid out its editor.
    NSRect corrected = frame;
    corrected.size.height = savedHeight;
    @try { [w setFrame:corrected display:YES animate:NO]; }
    @catch (__unused NSException *exception) {}
}
static void rememberMonitoringHeightFromUserResize(NSWindow *w) {
    if (!isMonitoringFXEditor(w) || !w.isVisible) return;
    NSEvent *event = NSApp.currentEvent;
    if (!event || event.type != NSEventTypeLeftMouseDragged || event.window != w)
        return; // Host/layout/project changes must never become the new baseline.
    MXPresetPanelSnapshot *preset = findPresetSnapshot(w);
    CGFloat originalTitledHeight = NSHeight(w.frame);
    if (preset) originalTitledHeight += preset.appliedWindowCrop;
    saveMonitoringGeometry(w, NSWidth(w.frame), originalTitledHeight);
}

static void hideFXPinInSuperview(NSView *parent, Class pinCellClass) {
    for (NSView *view in parent.subviews) {
        if (![view isKindOfClass:NSButton.class] || view.isHidden) continue;
        NSButton *button = (NSButton *)view;
        if (![button.cell isKindOfClass:pinCellClass]) continue;
        [hiddenFXPins addObject:button];
        button.hidden = YES;
    }
}

static void hideFXPin(NSWindow *w) {
    Class pinCellClass = NSClassFromString(@"SWELL_TopmostButton");
    if (!pinCellClass || !w.isVisible) return;

    // SWELL attaches the pin beside the close button, or beside the
    // content view when the window has no native close button.
    NSView *titlebar = [w standardWindowButton:NSWindowCloseButton].superview;
    NSView *frame = w.contentView.superview;
    hideFXPinInSuperview(titlebar, pinCellClass);
    if (frame != titlebar) hideFXPinInSuperview(frame, pinCellClass);
}

static void trackWindow(NSWindow *w, bool focused) {
    if (!w || w == resolveMain() || isHostFXChainWindow(w)) return;
    bool newlyDiscovered = ![knownFXWindows containsObject:w];
    // Normalize a new Monitoring FX editor while it still has its ORIGINAL
    // titled host frame. Once chrome is removed its content coordinate system
    // has changed; a late setFrame can collapse SWELL's editor (v33).
    if (newlyDiscovered && isMonitoringFXEditor(w))
        reconcileMonitoringHeightBeforeChrome(w);
    [knownFXWindows addObject:w];
    // Scanning FX is NOT a focus change. In particular, do not replace the
    // user's selected Monitoring FX with a random Track FX just because the
    // host reorders its floating windows during a titlebar/preset toggle.
    // Removing NSWindowStyleMaskTitled also makes many SWELL windows lose
    // their key-window capability, so preserve the last selected NSWindow.
    NSWindow *remembered = lastFX;
    const bool rememberedAlive = remembered && remembered.isVisible &&
                                 [knownFXWindows containsObject:remembered];
    if (focused || w == NSApp.keyWindow) {
        lastFX = w;
        lastFXChosen = true;
        mainExplicitlySelected = false;
    } else if (!rememberedAlive && newlyDiscovered && w.isVisible) {
        lastFX = w;
        lastFXChosen = false;
    }
    applyChrome(w);
    applyPreset(w);
    hideFXPin(w);
}
// Resolve an FX window from REAPER's current *or most recent* focused FX.
// For input/Monitoring FX the 0x1000000 FX flag must be left intact.
// GetTouchedOrFocusedFX uses zero-based tracks and -1 for Master; the older
// GetFocusedFX2 uses 1-based tracks and 0 for Master.
static void checkFocusedFX() {
    if (!api.project || !api.track || !api.master) return;
    int trackIndex = -999, itemIndex = -1, takeIndex = -1, fxIndex = -1;
    bool takeFX = false, activelyFocused = false, valid = false;
    bool modern = api.touchedOrFocused != nullptr;
    if (modern) {
        int parameter = 0;
        if (api.touchedOrFocused(1, &trackIndex, &itemIndex, &takeIndex, &fxIndex, &parameter)) {
            valid = fxIndex >= 0 && trackIndex >= -1;
            takeFX = itemIndex >= 0;
            activelyFocused = !(parameter & 1);
        }
    }
    if (!valid && api.focused) {
        int oldTrack = -1, oldItem = -1, oldFX = -1;
        int type = api.focused(&oldTrack, &oldItem, &oldFX);
        if ((type & 3) && oldFX >= 0 && oldTrack >= 0) {
            valid = true;
            trackIndex = oldTrack - 1;
            itemIndex = oldItem;
            takeFX = (type & 2) != 0;
            activelyFocused = !(type & 4);
            fxIndex = takeFX ? (oldFX & 0xffff) : oldFX;
            takeIndex = takeFX ? ((oldFX >> 16) & 0xffff) : -1;
        }
    }
    if (!valid) return;
    void *project = api.project(-1, nullptr, 0);
    if (!project) return;
    void *track = trackIndex == -1 ? api.master(project) : api.track(project, trackIndex);
    if (!track) return;
    void *handle = nullptr;
    if (!takeFX && api.trackFloating) {
        handle = api.trackFloating(track, fxIndex);
    } else if (takeFX && api.trackItem && api.take && api.takeFloating &&
               itemIndex >= 0 && takeIndex >= 0) {
        void *item = api.trackItem(track, itemIndex);
        void *take = item ? api.take(item, takeIndex) : nullptr;
        if (take) handle = api.takeFloating(take, fxIndex);
    }
    NSWindow *window = fromSwellHandle(handle);
    if (window && window != resolveMain()) {
        // A reported open-but-not-focused FX is still useful to discover,
        // but must not overwrite the user's most recently chosen window.
        if (takeFX && api.takeFXGUID && api.trackItem && api.take &&
            itemIndex >= 0 && takeIndex >= 0) {
            void *item = api.trackItem(track, itemIndex);
            void *take = item ? api.take(item, takeIndex) : nullptr;
            if (take) registerPresetGUID(window, api.takeFXGUID(take, fxIndex));
        } else if (!takeFX && api.trackFXGUID) {
            registerPresetGUID(window, api.trackFXGUID(track, fxIndex));
        }
        trackWindow(window, activelyFocused && window == NSApp.keyWindow);
        // REAPER can report the most recent floating FX after AppKit has
        // already returned key status to the main window (e.g. action hotkey).
        // API focus can be stale after an action or after switching to
        // borderless NSWindow. Never displace a still-open user-selected FX.
        if (activelyFocused && !mainExplicitlySelected &&
            (!lastFX || !lastFX.isVisible ||
             ![knownFXWindows containsObject:lastFX])) {
            lastFX = window;
            lastFXChosen = true;
        }
    }
}
static void scanAllFloatingFX() {
    // Recognize floating Monitoring FX independently from REAPER's FX API.
    // Its handle is not consistently enumerated on every REAPER/SWELL build.
    for (NSWindow *candidate in NSApp.windows) {
        if (isMonitoringFXEditor(candidate)) trackWindow(candidate, false);
    }
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
            if (w && w != resolveMain()) {
                if (api.trackFXGUID) registerPresetGUID(w, api.trackFXGUID(track, fx));
                trackWindow(w, false);
            }
        }
        // Record-input FX on normal tracks, Monitoring FX on the master.
        // REAPER requires adding 0x1000000 to these FX indices. These are
        // intentionally not included in TrackFX_GetCount().
        if (api.trackRecFXCount) {
            int nRecFX = std::min(2048, std::max(0, api.trackRecFXCount(track)));
            for (int fx = 0; fx < nRecFX; ++fx) {
                NSWindow *w = fromSwellHandle(api.trackFloating(track, 0x1000000 + fx));
                if (w && w != resolveMain()) {
                    if (api.trackFXGUID) registerPresetGUID(w, api.trackFXGUID(track, 0x1000000 + fx));
                    trackWindow(w, false);
                }
            }
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
                    if (w && w != resolveMain()) {
                        if (api.takeFXGUID) registerPresetGUID(w, api.takeFXGUID(take, fx));
                        trackWindow(w, false);
                    }
                }
            }
        }
    }
}
// FX Chain windows are not floating plug-in editors. Never remove their
// macOS titlebar, even when the global REAPER + FX toggle is active.
// Monitoring FX CHAIN titles begin with "FX:", whereas a floating monitoring
// plug-in is usually titled "<plug-in name> - Monitoring".
static bool isHostFXChainWindow(NSWindow *w) {
    if (!w || w == resolveMain()) return false;
    NSString *title = [w.title stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!title.length) return false;
    return [title hasPrefix:@"FX:"] ||
           [title hasPrefix:@"FX Chain:"] ||
           [title hasPrefix:@"Track FX:"] ||
           [title hasPrefix:@"Take FX:"];
}
// A floating Monitoring FX editor can exist without being returned by
// TrackFX_GetFloatingWindow() (for instance while REAPER is creating it).
// Distinguish it from the Monitoring FX CHAIN, titled "FX: Monitoring".
static bool isMonitoringFXEditor(NSWindow *w) {
    if (!w || w == resolveMain() || isHostFXChainWindow(w) || !w.isVisible)
        return false;
    NSString *title = [[w.title stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    // REAPER/plug-in builds vary the suffix; never include the FX Chain.
    if (([title hasSuffix:@" - monitoring"] && title.length > [@" - monitoring" length]) ||
        ([title hasSuffix:@" - monitoring fx"] && title.length > [@" - monitoring fx" length]) ||
        ([title hasSuffix:@" [monitoring]"] && title.length > [@" [monitoring]" length])) return true;
    NSRange marker = [title rangeOfString:@" - monitoring ["];
    return marker.location != NSNotFound && marker.location > 0 &&
           [title hasSuffix:@"]"];
}
// This signature is inexpensive even in projects with many media items.
// Scan tracks/takes when AppKit's set of visible windows changes, rather
// than on EVERY UI update. Hash the title as well for reused FX-chain windows.
static uint64_t visibleWindowSignature() {
    uint64_t hash = 1469598103934665603ULL;
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible) continue;
        hash ^= (uint64_t)(uintptr_t)(__bridge void *)w;
        hash *= 1099511628211ULL;
        hash ^= (uint64_t)w.title.hash;
        hash *= 1099511628211ULL;
    }
    return hash;
}
static void scanKnownFXNow() {
    scanAllFloatingFX();
    checkFocusedFX();
    lastWindowSignature = visibleWindowSignature();
}
static void hideAll() {
    automaticHide = true;
    [chromeOverrides removeAllObjects];
    NSWindow *main = resolveMain();
    if (main) applyChrome(main);
    scanKnownFXNow();
    nextFullFXScan = CFAbsoluteTimeGetCurrent() + 6.0;
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
    // Floating Monitoring FX must work even when they have never been clicked.
    // Do not depend on having a titlebar snapshot or on w == lastFX.
    return w == resolveMain() || isHostFXChainWindow(w) ||
           [knownFXWindows containsObject:w] || isFloatingFXWindow(w);
}
static NSWindow *fxUnderCursor() {
    NSPoint cursor = [NSEvent mouseLocation];
    // A borderless FX may never become key again. The pointer still gives a
    // reliable explicit target without a click, including Monitoring FX.
    for (NSWindow *w in [NSApp orderedWindows]) {
        if (!w.isVisible || !NSPointInRect(cursor, w.frame)) continue;
        if (validFocusedFX(w)) return w;
        // A different foreground REAPER window blocks hit-testing behind it.
        if (w == resolveMain() || isHostFXChainWindow(w)) break;
    }
    return nil;
}
static NSWindow *focusedMoveTarget() {
    NSWindow *key = NSApp.keyWindow;
    NSWindow *main = resolveMain();
    NSWindow *underPointer = fxUnderCursor();
    if (underPointer) {
        lastFX = underPointer;
        lastFXChosen = true;
        mainExplicitlySelected = false;
        return underPointer;
    }
    if (key && key != main && isMoveCandidate(key)) return key;
    // Intentional main-window clicks still allow moving REAPER itself.
    if (key == main && mainExplicitlySelected &&
        NSPointInRect([NSEvent mouseLocation], main.frame)) return main;
    NSWindow *fx = focusedFXTargetForHostControls();
    if (fx && isMoveCandidate(fx)) return fx;
    if (key == main && mainExplicitlySelected) return main;
    if (isMoveCandidate(key)) return key;
    return isMoveCandidate(main) ? main : nil;
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
    // Capture newly opened FX without waiting for a mouse click, including
    // Monitoring FX windows omitted from the normal TrackFX enumeration.
    scanAllFloatingFX();
    checkFocusedFX();
    NSWindow *w = focusedMoveTarget();
    if (!w) {
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
// Validate a NEW floating FX window without changing any other window.
// Unlike scanAllFloatingFX(), this function has no titlebar side effects.
static bool isFloatingFXWindow(NSWindow *candidate) {
    if (isMonitoringFXEditor(candidate)) return true;
    if (!candidate || !api.project || !api.track || !api.trackCount ||
        !api.trackFXCount || !api.trackFloating) return false;
    void *project = api.project(-1, nullptr, 0);
    if (!project) return false;
    int nTracks = std::max(0, api.trackCount(project));
    for (int ti = -1; ti < nTracks; ++ti) {
        void *track = ti == -1 ? (api.master ? api.master(project) : nullptr) : api.track(project, ti);
        if (!track) continue;
        int nFX = std::min(2048, std::max(0, api.trackFXCount(track)));
        for (int fx = 0; fx < nFX; ++fx) {
            if (fromSwellHandle(api.trackFloating(track, fx)) == candidate) {
                if (api.trackFXGUID) registerPresetGUID(candidate, api.trackFXGUID(track, fx));
                return true;
            }
        }
        if (api.trackRecFXCount) {
            int nRecFX = std::min(2048, std::max(0, api.trackRecFXCount(track)));
            for (int fx = 0; fx < nRecFX; ++fx) {
                if (fromSwellHandle(api.trackFloating(track, 0x1000000 + fx)) == candidate) {
                    if (api.trackFXGUID) registerPresetGUID(candidate, api.trackFXGUID(track, 0x1000000 + fx));
                    return true;
                }
            }
        }
        if (!api.trackItemCount || !api.trackItem || !api.takeCount ||
            !api.take || !api.takeFXCount || !api.takeFloating) continue;
        int nItems = std::max(0, api.trackItemCount(track));
        for (int i = 0; i < nItems; ++i) {
            void *item = api.trackItem(track, i);
            if (!item) continue;
            int nTakes = std::min(128, std::max(0, api.takeCount(item)));
            for (int takeIndex = 0; takeIndex < nTakes; ++takeIndex) {
                void *take = api.take(item, takeIndex);
                if (!take) continue;
                int nTakeFX = std::min(2048, std::max(0, api.takeFXCount(take)));
                for (int fx = 0; fx < nTakeFX; ++fx) {
                    if (fromSwellHandle(api.takeFloating(take, fx)) == candidate) {
                        if (api.takeFXGUID) registerPresetGUID(candidate, api.takeFXGUID(take, fx));
                        return true;
                    }
                }
            }
        }
    }
    return false;
}
// Focused actions share a sticky FX target, because invoking a REAPER
// action can itself transfer the macOS key status back to REAPER/Actions.
// We update it on a genuine FX focus, and reset it when the user clicks main.
static bool validFocusedFX(NSWindow *w) {
    return w && w.isVisible && !w.isMiniaturized && !w.attachedSheet &&
           w != NSApp.modalWindow && !(w.styleMask & NSWindowStyleMaskFullScreen) &&
           w != resolveMain() && !isHostFXChainWindow(w) &&
           ([knownFXWindows containsObject:w] || isFloatingFXWindow(w));
}
// The frontmost verified editor is a fallback for FX windows that open while
// a keyboard shortcut / custom Action immediately returns focus to REAPER.
// Enumeration order of tracks is NOT z-order; AppKit's orderedWindows is.
static NSWindow *frontmostFXEditor() {
    for (NSWindow *candidate in [NSApp orderedWindows]) {
        if (validFocusedFX(candidate)) return candidate;
    }
    return nil;
}
// Keep the original focused-titlebar selection untouched: it already works.
static NSWindow *focusedFXTarget() {
    NSWindow *key = NSApp.keyWindow;
    if (validFocusedFX(key)) {
        [knownFXWindows addObject:key];
        lastFX = key;
        lastFXChosen = true;
        mainExplicitlySelected = false;
        return key;
    }
    checkFocusedFX();
    NSWindow *prior = lastFX;
    if (validFocusedFX(prior) &&
        !(key == resolveMain() && mainExplicitlySelected)) return prior;
    return nil;
}
// Preset and Move need a more resilient target than the titlebar action:
// a plugin may be visible and frontmost without ever delivering a click.
static NSWindow *focusedFXTargetForHostControls() {
    NSWindow *key = NSApp.keyWindow;
    if (validFocusedFX(key)) {
        lastFX = key;
        lastFXChosen = true;
        mainExplicitlySelected = false;
        return key;
    }
    // Crucial: a hidden-titlebar plug-in often CANNOT become NSApp.keyWindow.
    // Keep the exact window through repeat preset/resize/move actions instead
    // of unconditionally choosing frontmostFXEditor() after each invocation.
    NSWindow *remembered = lastFX;
    if (lastFXChosen && validFocusedFX(remembered)) return remembered;
    // No real user selection yet: enumerate by window z-order, not by
    // REAPER track index (which can start with an unrelated Monitoring FX).
    NSWindow *front = frontmostFXEditor();
    if (front) {
        lastFX = front;
        lastFXChosen = true;
        return front;
    }
    if (validFocusedFX(remembered)) {
        lastFXChosen = true;
        return remembered;
    }
    checkFocusedFX();
    remembered = lastFX;
    if (validFocusedFX(remembered)) {
        lastFXChosen = true;
        return remembered;
    }
    return nil;
}
static NSWindow *focusedChromeTarget() {
    NSWindow *fx = focusedFXTarget();
    if (fx) return fx;
    // Preserve previous titlebar behavior for explicitly selected main UI.
    NSWindow *main = resolveMain();
    return NSApp.keyWindow == main ? main : nil;
}
// Toggle the REAPER HOST's preset/parameter panel, not plug-in-provided controls.
// REAPER/SWELL does not provide a documented preset-panel toggle API. We
// identify the host row by its *two* expected controls (Param and UI) in the
// uppermost area. If this cannot be established, do nothing rather than
// accidentally hiding a plug-in's user interface.
static NSString *presetControlText(NSView *v) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([v isKindOfClass:[NSButton class]]) {
        NSString *label = [(NSButton *)v title];
        if (label.length) [parts addObject:label];
    } else if ([v isKindOfClass:[NSTextField class]]) {
        NSString *label = [(NSTextField *)v stringValue];
        if (label.length) [parts addObject:label];
    } else if ([v isKindOfClass:[NSPopUpButton class]]) {
        NSString *label = [(NSPopUpButton *)v titleOfSelectedItem];
        if (label.length) [parts addObject:label];
    }
    // Some SWELL controls use accessibility properties rather than native
    // NSButton/NSPopUpButton subclasses.
    @try {
        id label = [v accessibilityLabel];
        if ([label isKindOfClass:[NSString class]] && [label length]) [parts addObject:label];
    } @catch (__unused NSException *e) {}
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}
struct MXPresetMarker {
    NSView *view;
    bool param;
    bool ui;
};
static void findPresetMarkers(NSView *root, NSView *view,
                              std::vector<MXPresetMarker> &out, int depth) {
    if (!view || depth > 12 || out.size() >= 256) return;
    if (view != root) {
        NSString *label = [presetControlText(view) stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSRect rect = [view convertRect:view.bounds toView:root];
        const BOOL flipped = root.isFlipped;
        CGFloat topDistance = flipped ? NSMinY(rect) - NSMinY(root.bounds)
                                      : NSMaxY(root.bounds) - NSMaxY(rect);
        CGFloat bottomDistance = flipped ? NSMaxY(rect) - NSMinY(root.bounds)
                                         : NSMaxY(root.bounds) - NSMinY(rect);
        if (label.length && topDistance >= -6.0 && topDistance < 100.0 &&
            bottomDistance < 125.0) {
            bool isParam = [label isEqualToString:@"param"] ||
                           [label hasPrefix:@"param "] ||
                           [label containsString:@"parameter"];
            bool isUI = [label isEqualToString:@"ui"] ||
                        [label hasPrefix:@"ui "] ||
                        [label hasSuffix:@" ui"];
            if (isParam || isUI) out.push_back({view, isParam, isUI});
        }
    }
    for (NSView *child in view.subviews) findPresetMarkers(root, child, out, depth + 1);
}
static bool isAncestor(NSView *ancestor, NSView *v) {
    while (v) {
        if (v == ancestor) return true;
        v = v.superview;
    }
    return false;
}
// SWELL on macOS often uses custom NSView subclasses for host controls.
// "Param" and "UI" therefore may have no NSButton title or accessibility
// label. In that case identify the REAPER host strip by layout: a narrow,
// nearly full-width top row followed by a *separate* large FX editor view.
// We deliberately require both pieces of geometry; otherwise a plug-in's
// own header could be mistaken for the host preset strip.
struct MXViewBounds {
    NSView *view;
    NSRect rect;
    CGFloat top;
};
static void collectVisibleViewBounds(NSView *root, NSView *v,
                                     std::vector<MXViewBounds> &out, int depth) {
    if (!v || depth > 14 || out.size() > 1024 || v.isHidden) return;
    if (v != root) {
        NSRect r = [v convertRect:v.bounds toView:root];
        CGFloat top = root.isFlipped ? NSMinY(r) - NSMinY(root.bounds)
                   : NSMaxY(root.bounds) - NSMaxY(r);
        if (NSWidth(r) >= 1 && NSHeight(r) >= 1)
            out.push_back({v, r, top});
    }
    for (NSView *child in v.subviews)
        collectVisibleViewBounds(root, child, out, depth + 1);
}
static NSView *discoverPresetPanelByGeometry(NSView *root) {
    if (!root || NSWidth(root.bounds) < 180 || NSHeight(root.bounds) < 130) return nil;
    std::vector<MXViewBounds> entries;
    collectVisibleViewBounds(root, root, entries, 0);
    NSView *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    const CGFloat rootWidth = NSWidth(root.bounds);
    for (const auto &top : entries) {
        CGFloat h = NSHeight(top.rect), width = NSWidth(top.rect);
        if (top.top < -5 || top.top > 54 || h < 18 || h > 60 ||
            width < rootWidth * 0.74) continue;
        // The adjacent editor must be distinct from the candidate strip and
        // must occupy the large lower portion of the FX window.
        bool editorBelow = false;
        CGFloat bandBottom = top.top + h;
        for (const auto &editor : entries) {
            if (editor.view == top.view ||
                isAncestor(top.view, editor.view) ||
                isAncestor(editor.view, top.view)) continue;
            if (NSWidth(editor.rect) < rootWidth * 0.64 ||
                NSHeight(editor.rect) < 90 ||
                editor.top < bandBottom - 7) continue;
            editorBelow = true;
            break;
        }
        if (!editorBelow) continue;
        // Prefer the topmost full-width strip closest to a usual host row.
        CGFloat score = std::fabs(h - 30.0) + top.top * 2.0 +
                        (rootWidth - width) * 0.04;
        if (score < bestScore) { bestScore = score; best = top.view; }
    }
    return best;
}
static NSView *discoverPresetPanel(NSWindow *w) {
    NSView *root = w.contentView;
    if (!root || NSHeight(root.bounds) < 140.0) return nil;
    std::vector<MXPresetMarker> marks;
    findPresetMarkers(root, root, marks, 0);
    NSView *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (const MXPresetMarker &param : marks) {
        if (!param.param) continue;
        for (const MXPresetMarker &ui : marks) {
            if (!ui.ui) continue;
            for (NSView *ancestor = param.view.superview;
                 ancestor && ancestor != root; ancestor = ancestor.superview) {
                if (!isAncestor(ancestor, ui.view)) continue;
                if (ancestor.isHidden) continue;
                NSRect boundsInRoot = [ancestor convertRect:ancestor.bounds toView:root];
                CGFloat height = NSHeight(boundsInRoot);
                CGFloat width = NSWidth(boundsInRoot);
                CGFloat upperGap = root.isFlipped ? NSMinY(boundsInRoot) - NSMinY(root.bounds)
                                                  : NSMaxY(root.bounds) - NSMaxY(boundsInRoot);
                // Don't hide an entire FX editor / window content view.
                if (height < 16.0 || height > 92.0 || width < 150.0 ||
                    width < NSWidth(root.bounds) * 0.60 ||
                    upperGap < -5.0 || upperGap > 60.0) continue;
                CGFloat area = width * height;
                if (area < bestArea) { best = ancestor; bestArea = area; }
            }
        }
    }
    // Prefer the confirmed Param + UI group; fall back to the host's actual
    // layout for SWELL controls which do not expose standard Cocoa labels.
    return best ? best : discoverPresetPanelByGeometry(root);
}
// Some SWELL versions lay out the individual host controls as direct
// children, without one dedicated strip NSView. Accept a small group of
// top-row controls only if a large, separate plug-in editor exists below.
static NSArray<NSView *> *discoverLoosePresetControls(NSWindow *w,
                                                      NSView **editorOut,
                                                      CGFloat *heightOut) {
    NSView *root = w.contentView;
    if (!root || NSWidth(root.bounds) < 180 || NSHeight(root.bounds) < 100)
        return nil;
    std::vector<MXViewBounds> nodes;
    collectVisibleViewBounds(root, root, nodes, 0);
    const CGFloat width = NSWidth(root.bounds);
    std::vector<MXViewBounds> controls;
    for (const auto &e : nodes) {
        CGFloat h = NSHeight(e.rect), ww = NSWidth(e.rect);
        if (e.top < -3 || e.top > 44 || h < 8 || h > 35 ||
            ww < 8 || ww > width * 0.84) continue;
        // Limit this fallback to leaf controls. Parent views are handled by
        // discoverPresetPanelByGeometry(), and must never be hidden here.
        if (e.view.subviews.count != 0) continue;
        controls.push_back(e);
    }
    NSView *editor = nil;
    CGFloat largestArea = 0;
    for (const auto &candidate : nodes) {
        CGFloat w0 = NSWidth(candidate.rect), h0 = NSHeight(candidate.rect);
        if (candidate.top < 26 || w0 < width * 0.66 || h0 < 65) continue;
        bool containsControls = false;
        for (const auto &control : controls) {
            if (isAncestor(candidate.view, control.view)) { containsControls = true; break; }
        }
        if (containsControls) continue;
        CGFloat area = w0 * h0;
        if (area > largestArea) { largestArea = area; editor = candidate.view; }
    }
    if (!editor || controls.size() < 3) return nil;
    // Keep only one horizontal cluster, near the top of the host window.
    CGFloat bestSpan = 0, bestHeight = 0;
    NSMutableArray<NSView *> *selected = nil;
    for (const auto &seed : controls) {
        CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, bottom = 0;
        NSMutableArray<NSView *> *group = [NSMutableArray array];
        for (const auto &candidate : controls) {
            if (std::fabs(candidate.top - seed.top) > 12.0) continue;
            [group addObject:candidate.view];
            minX = std::min(minX, NSMinX(candidate.rect));
            maxX = std::max(maxX, NSMaxX(candidate.rect));
            bottom = std::max(bottom, candidate.top + NSHeight(candidate.rect));
        }
        CGFloat span = maxX - minX;
        if (group.count >= 3 && minX < width * 0.25 &&
            maxX > width * 0.70 && span > bestSpan) {
            selected = group;
            bestSpan = span;
            bestHeight = bottom;
        }
    }
    if (!selected) return nil;
    if (editorOut) *editorOut = editor;
    if (heightOut) *heightOut = std::max(18.0, std::min(60.0, bestHeight));
    return selected;
}
static MXPresetPanelSnapshot *findPresetSnapshot(NSWindow *w) {
    for (MXPresetPanelSnapshot *entry in savedPresetPanels) {
        if (entry.window == w) return entry;
    }
    return nil;
}
static NSView *findPresetEditorSibling(NSWindow *w, NSView *strip) {
    if (!w || !strip) return nil;
    NSView *parent = strip.superview;
    if (!parent) return nil;
    NSView *best = nil;
    CGFloat area = 0;
    NSRect sr = strip.frame;
    for (NSView *child in parent.subviews) {
        if (child == strip || child.isHidden) continue;
        NSRect r = child.frame;
        // Only crop when a separate plug-in editor occupies the area below
        // the host strip; no reparenting or resizing of plug-in subviews.
        bool belowStrip = parent.isFlipped ? NSMinY(r) >= NSMaxY(sr) - 4.0
                                            : NSMaxY(r) <= NSMinY(sr) + 4.0;
        if (NSWidth(r) < 0.75 * NSWidth(parent.bounds) ||
            NSHeight(r) < 90 || !belowStrip) continue;
        CGFloat a = NSWidth(r) * NSHeight(r);
        if (a > area) { area = a; best = child; }
    }
    return best;
}
// Content view coordinates, not the FX editor frame, determine the *actual*
// amount of unused host space. REAPER may draw a 30px control row in a much
// taller parent view, especially for instrument/monitoring plug-ins.
// Some SWELL builds nest the FX editor one or two levels below the host
// pane. Prefer a LARGE, distinct editor below the identified preset strip.
static NSView *discoverNestedEditorBelowStrip(NSWindow *w, NSView *strip) {
    NSView *root = w.contentView;
    if (!root || !strip) return nil;
    std::vector<MXViewBounds> nodes;
    collectVisibleViewBounds(root, root, nodes, 0);
    NSRect stripRect = [strip convertRect:strip.bounds toView:root];
    CGFloat stripTop = root.isFlipped ? NSMinY(stripRect) - NSMinY(root.bounds)
                                       : NSMaxY(root.bounds) - NSMaxY(stripRect);
    CGFloat stripBottom = stripTop + NSHeight(stripRect);
    CGFloat largestArea = 0;
    NSView *best = nil;
    for (const auto &node : nodes) {
        if (node.view == strip || isAncestor(node.view, strip) ||
            isAncestor(strip, node.view)) continue;
        if (node.top < stripBottom - 5.0 ||
            NSWidth(node.rect) < NSWidth(root.bounds) * 0.65 ||
            NSHeight(node.rect) < 90.0) continue;
        // Avoid targeting an inner button/knob: require a large root-level
        // plug-in editor, rather than a small control inside its UI.
        CGFloat area = NSWidth(node.rect) * NSHeight(node.rect);
        if (area > largestArea) { best = node.view; largestArea = area; }
    }
    return best;
}
// The window itself clips the enlarged REAPER content view. Never replace its
// contentView, create a host wrapper, or reparent any SWELL / plug-in NSViews.
// Reapply the geometry only when the host has resized or relaid out the root.
static void updatePresetViewport(MXPresetPanelSnapshot *snap) {
    NSWindow *w = snap.window;
    NSView *root = snap.contentRoot;
    if (!w || !root || w.contentView != root) return;
    NSRect visible = [w contentRectForFrameRect:w.frame];
    NSRect target = NSMakeRect(0.0, 0.0, NSWidth(visible),
                               NSHeight(visible) + snap.removedHeight);
    NSRect current = root.frame;
    if (std::fabs(NSWidth(current) - NSWidth(target)) > 0.5 ||
        std::fabs(NSHeight(current) - NSHeight(target)) > 0.5 ||
        std::fabs(NSMinX(current)) > 0.5 ||
        std::fabs(NSMinY(current)) > 0.5)
        [root setFrame:target];
}
static void restorePresetPanel(MXPresetPanelSnapshot *snap) {
    NSWindow *w = snap.window;
    NSView *root = snap.contentRoot;
    if (!w || !root || w.contentView != root) return;
    @try {
        // Restore the frame BEFORE its original minimum constraints. Restoring
        // a larger minSize first can grow the compact window automatically;
        // adding the crop afterward would then increase it a second time.
        NSRect frame = w.frame;
        // Do not accumulate height if the host rejected or partially applied
        // the original shrink. This also respects a plug-in's later resize.
        frame.size.height += snap.appliedWindowCrop;
        [w setFrame:frame display:YES animate:NO];
        w.contentMinSize = snap.previousContentMinSize;
        root.autoresizingMask = (NSAutoresizingMaskOptions)snap.originalAutoresizingMask;
        NSRect visible = [w contentRectForFrameRect:w.frame];
        [root setFrame:NSMakeRect(0.0, 0.0, NSWidth(visible), NSHeight(visible))];
        [root setNeedsDisplay:YES];
    } @catch (__unused NSException *exception) {}
}
// When REAPER closes an FX window, its host may still be collecting the
// current editor geometry. Restoring the full window height at WillClose adds
// the hidden preset strip to the saved editor height, causing a one-strip
// increase every time that Monitoring FX is recreated/reopened.
// Discard only the temporary oversized viewport; never enlarge a closing window.
static void releaseClosingPresetViewport(MXPresetPanelSnapshot *snap) {
    NSWindow *w = snap.window;
    NSView *root = snap.contentRoot;
    if (!w || !root || w.contentView != root) return;
    @try {
        root.autoresizingMask = (NSAutoresizingMaskOptions)snap.originalAutoresizingMask;
        NSRect visible = [w contentRectForFrameRect:w.frame];
        if (NSWidth(visible) > 0.0 && NSHeight(visible) > 0.0) {
            NSRect target = NSMakeRect(0.0, 0.0, NSWidth(visible), NSHeight(visible));
            NSRect current = root.frame;
            if (std::fabs(NSHeight(current) - NSHeight(target)) > 0.5 ||
                std::fabs(NSWidth(current) - NSWidth(target)) > 0.5 ||
                std::fabs(NSMinX(current)) > 0.5 || std::fabs(NSMinY(current)) > 0.5)
                [root setFrame:target];
        }
        // minSize/contentMinSize stay untouched: restoring the old minimum
        // may itself grow the closing window. The NSWindow is being destroyed.
    } @catch (__unused NSException *exception) {}
}
static void releaseAllClosingPresetViewports() {
    for (MXPresetPanelSnapshot *snap in [savedPresetPanels reverseObjectEnumerator])
        releaseClosingPresetViewport(snap);
    [savedPresetPanels removeAllObjects];
}
static void restoreAllPresetPanels() {
    for (MXPresetPanelSnapshot *snap in [savedPresetPanels reverseObjectEnumerator])
        restorePresetPanel(snap);
    [savedPresetPanels removeAllObjects];
}
static NSWindow *focusedPresetTarget() {
    return focusedFXTargetForHostControls();
}
// The REAPER preset strip is normally about 30 pt tall, but SWELL may
// expose the host row as a separate NSView or draw it inside a custom view.
// Use geometry where available. Never hide the plug-in's own NSViews.
static CGFloat presetCropHeight(NSWindow *w) {
    NSView *root = w.contentView;
    NSView *strip = discoverPresetPanel(w);
    NSView *editor = strip ? findPresetEditorSibling(w, strip) : nil;
    if (!editor && strip) editor = discoverNestedEditorBelowStrip(w, strip);
    NSView *looseEditor = nil;
    CGFloat looseHeight = 0.0;
    if (!editor) (void)discoverLoosePresetControls(w, &looseEditor, &looseHeight);
    if (!editor) editor = looseEditor;
    CGFloat crop = 0.0;
    if (editor && root && isAncestor(root, editor)) {
        NSRect rect = [editor convertRect:editor.bounds toView:root];
        CGFloat gap = root.isFlipped ? NSMinY(rect) - NSMinY(root.bounds)
                                      : NSMaxY(root.bounds) - NSMaxY(rect);
        if (gap >= 18.0 && gap <= 90.0) crop = std::ceil(gap);
    }
    if (crop < 16.0 && strip) {
        NSRect band = [strip convertRect:strip.bounds toView:root];
        CGFloat top = root.isFlipped ? NSMinY(band) - NSMinY(root.bounds)
                                    : NSMaxY(root.bounds) - NSMaxY(band);
        CGFloat bottom = top + NSHeight(band);
        if (top >= -5.0 && top < 40.0 && bottom >= 18.0 && bottom <= 90.0)
            crop = std::ceil(bottom);
    }
    if (crop < 16.0 && looseHeight >= 18.0 && looseHeight <= 70.0)
        crop = std::ceil(looseHeight);
    // A blind 30-pt crop can cut off a plug-in's own controls when REAPER
    // exposes no identifiable host row. Do not modify unverified layouts.
    if (crop < 16.0) return 0.0;
    return std::min(90.0, std::max(18.0, crop));
}
static bool hidePresetPanel(NSWindow *w) {
    if (!w || !w.isVisible || w.isMiniaturized || w.attachedSheet ||
        (w.styleMask & NSWindowStyleMaskFullScreen) ||
        isHostFXChainWindow(w) || w == resolveMain()) return false;
    if (findPresetSnapshot(w)) return true;
    NSView *root = w.contentView;
    if (!root || NSWidth(root.bounds) < 130.0 || NSHeight(root.bounds) < 110.0)
        return false;
    CGFloat crop = presetCropHeight(w);
    if (crop < 16.0) return false;
    NSRect previous = w.frame;
    if (NSHeight(previous) < crop + 110.0) return false;

    MXPresetPanelSnapshot *snap = [MXPresetPanelSnapshot new];
    snap.window = w;
    snap.contentRoot = root;  // preserve the exact SWELL root throughout the toggle
    snap.originalAutoresizingMask = root.autoresizingMask;
    snap.previousContentMinSize = w.contentMinSize;
    snap.removedHeight = crop;
    snap.appliedWindowCrop = 0.0;
    [savedPresetPanels addObject:snap];
    @try {
        // A genuine SWELL HWND is often the contentView itself. AppKit's
        // setContentView: would replace its root and can interfere with
        // REAPER event routing, focus, and plug-in editor layout.
        root.autoresizingMask = NSViewNotSizable;

        // AppKit derives minSize from contentMinSize and the current chrome.
        NSSize minimum = w.contentMinSize;
        minimum.height = std::max(0.0, minimum.height - crop);
        w.contentMinSize = minimum;
        NSRect compact = previous;
        compact.size.height -= crop; // keep the bottom edge in place
        [w setFrame:compact display:YES animate:NO];
        // Track actual shrink before any further host/view layout takes place.
        snap.appliedWindowCrop = std::max<CGFloat>(0.0, NSHeight(previous) - NSHeight(w.frame));
        updatePresetViewport(snap);

        NSRect visible = [w contentRectForFrameRect:w.frame];
        if (std::fabs(NSHeight(w.frame) - NSHeight(compact)) > 1.5 ||
            w.contentView != root ||
            std::fabs(NSHeight(root.frame) - NSHeight(visible) - crop) > 1.5) {
            restorePresetPanel(snap);
            [savedPresetPanels removeObject:snap];
            return false;
        }
    } @catch (__unused NSException *exception) {
        restorePresetPanel(snap);
        [savedPresetPanels removeObject:snap];
        return false;
    }
    return true;
}
static bool shouldHidePreset(NSWindow *w) {
    NSNumber *override = getPresetOverride(w);
    return override ? override.boolValue : automaticPresetHide;
}
static void applyPreset(NSWindow *w) {
    if (!w || w == resolveMain() || isHostFXChainWindow(w)) return;
    MXPresetPanelSnapshot *snapshot = findPresetSnapshot(w);
    if (shouldHidePreset(w)) {
        if (!snapshot) hidePresetPanel(w);
    } else if (snapshot) {
        restorePresetPanel(snapshot);
        [savedPresetPanels removeObject:snapshot];
    }
}
static void toggleFocusedPresetPanel() {
    // Unlike titlebar toggles, this previously depended on lastFX already
    // being populated by a click. Discover newly opened floating editors now.
    scanAllFloatingFX();
    NSWindow *w = focusedPresetTarget();
    if (!w) return;
    const bool wasDesiredHidden = shouldHidePreset(w);
    saveFocusedPresetState(w, !wasDesiredHidden);
    applyPreset(w);
    // A newly opened SWELL editor may not have laid out its host controls
    // until the next AppKit event-loop turn. Retry once on the exact window
    // selected by this action, rather than depending on the user to click it.
    if (!wasDesiredHidden && !findPresetSnapshot(w)) {
        __weak NSWindow *pending = w;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *target = pending;
            if (!target || !target.isVisible) return;
            NSNumber *desired = [presetOverrides objectForKey:target];
            if (!desired || !desired.boolValue || findPresetSnapshot(target)) return;
            @try { [target.contentView layoutSubtreeIfNeeded]; }
            @catch (__unused NSException *exception) {}
            applyPreset(target);
            // Do not erase a user's persistent preference when one plug-in
            // has a host layout that cannot be cropped safely.
        });
    }
    if (api.refreshToolbar && presetToggleID > 0)
        api.refreshToolbar(0, presetToggleID);
}
static void toggleAllPresetPanels() {
    automaticPresetHide = !automaticPresetHide;
    ++presetGeneration; // Invalidates persisted overrides without enumerating ExtState keys.
    persistGlobalPresetState();
    [presetOverrides removeAllObjects]; // Global toggle overrides local changes.
    if (automaticPresetHide) {
        // Track/Take/Input/Monitoring FX, including already open windows.
        scanKnownFXNow();
        for (NSWindow *w in [knownFXWindows allObjects]) applyPreset(w);
    } else {
        restoreAllPresetPanels();
    }
    if (api.refreshToolbar && presetAllToggleID > 0)
        api.refreshToolbar(0, presetAllToggleID);
    if (api.refreshToolbar && presetToggleID > 0)
        api.refreshToolbar(0, presetToggleID);
}
static void toggleFocusedChrome() {
    NSWindow *w = focusedChromeTarget();
    if (!w) {
        return;
    }
    MXWindowSnapshot *snapshot = findSnapshot(w);
    // If the window was already borderless before we touched it, never add
    // a titlebar that did not exist in the host/plugin's original layout.
    if (!(w.styleMask & NSWindowStyleMaskTitled) && !snapshot) {
        return;
    }
    if (snapshot) {
        // Local Show even if global automatic hiding remains ON.
        [chromeOverrides setObject:@NO forKey:w];
        restoreTitlebarOnly(w);
    } else {
        // Local Hide even if the global action has shown all titlebars.
        [chromeOverrides setObject:@YES forKey:w];
        hideTitlebar(w);
    }
    if (api.refreshToolbar && focusedToggleID > 0) api.refreshToolbar(0, focusedToggleID);
}
static void toggleChrome() {
    if (automaticHide) showAll();
    else hideAll();
    if (api.refreshToolbar && toggleID > 0) api.refreshToolbar(0, toggleID);
    if (api.refreshToolbar && focusedToggleID > 0) api.refreshToolbar(0, focusedToggleID);
}
static int toggleState(int command) {
    if (arrangeScrollbarsToggleID && command == arrangeScrollbarsToggleID)
        return arrangeScrollbarsHidden ? 1 : 0;
    if (command == toggleID) return automaticHide ? 1 : 0;
    if (command == presetAllToggleID) return automaticPresetHide ? 1 : 0;
    if (command == presetToggleID) {
        NSWindow *w = lastFX;
        return validFocusedFX(w) ? (findPresetSnapshot(w) != nil ? 1 : 0) : -1;
    }
    if (command == focusedToggleID) {
        NSWindow *w = NSApp.keyWindow;
        if (!w || isHostFXChainWindow(w) || !(w == resolveMain() || [knownFXWindows containsObject:w])) return -1;
        return findSnapshot(w) ? 1 : 0;
    }
    return -1;
}
static void runCommand(int command) {
    if (command == toggleID) toggleChrome();
    else if (command == moveID) toggleMoving();
    else if (command == focusedToggleID) toggleFocusedChrome();
    else if (command == presetToggleID) toggleFocusedPresetPanel();
    else if (command == presetAllToggleID) toggleAllPresetPanels();
    else if (command == arrangeScrollbarsToggleID) toggleArrangeScrollbars();
}
// REAPER can expose multiple command-hook paths. If both report the *same*
// user action, executing a toggle twice immediately cancels the first call.
// Deduplicate only callbacks occurring less than 75ms apart; keep both hooks
// registered for other REAPER action invocation paths.
static int previousCommand = -1;
static CFAbsoluteTime previousCommandTime = 0.0;
static void runWindowCommandOnce(int command) {
    if (!regWindow) return;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // REAPER may invoke both command hooks for a single user action.
    if (previousCommand == command &&
        now - previousCommandTime >= 0.0 &&
        now - previousCommandTime < 0.075) return;
    previousCommand = command;
    previousCommandTime = now;
    runCommand(command);
}
static bool dispatchCommand(int command) {
    if (!regWindow || command <= 0 || (command != arrangeScrollbarsToggleID && command != toggleID && command != moveID && command != focusedToggleID && command != presetToggleID && command != presetAllToggleID)) return false;
    if ([NSThread isMainThread]) {
        @autoreleasepool { runWindowCommandOnce(command); }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { runWindowCommandOnce(command); }
        });
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
    if (resizeObserver) { [center removeObserver:resizeObserver]; resizeObserver = nil; }
    if (focusMouseObserver) { [NSEvent removeMonitor:focusMouseObserver]; focusMouseObserver = nil; }
    if (terminateObserver) { [center removeObserver:terminateObserver]; terminateObserver = nil; }
}
} // namespace

void MixolveRefreshArrangeScrollbarsAfterWheel() {
    applyArrangeScrollbarSetting();
}

extern "C" bool MixolveFXWindowsStart(ep::Info *info) {
    if (!info || !info->get || !info->reg) return false;
    if (regWindow) return true;
    api.mainHwnd = reinterpret_cast<decltype(api.mainHwnd)>(info->get("GetMainHwnd"));
    api.showScrollBar = reinterpret_cast<decltype(api.showScrollBar)>(info->get("CoolSB_ShowScrollBar"));
    api.focused = reinterpret_cast<decltype(api.focused)>(info->get("GetFocusedFX2"));
    api.touchedOrFocused = reinterpret_cast<decltype(api.touchedOrFocused)>(info->get("GetTouchedOrFocusedFX"));
    api.project = reinterpret_cast<decltype(api.project)>(info->get("EnumProjects"));
    api.trackCount = reinterpret_cast<decltype(api.trackCount)>(info->get("CountTracks"));
    api.track = reinterpret_cast<decltype(api.track)>(info->get("GetTrack"));
    api.master = reinterpret_cast<decltype(api.master)>(info->get("GetMasterTrack"));
    api.trackFXCount = reinterpret_cast<decltype(api.trackFXCount)>(info->get("TrackFX_GetCount"));
    api.trackRecFXCount = reinterpret_cast<decltype(api.trackRecFXCount)>(info->get("TrackFX_GetRecCount"));
    api.trackFloating = reinterpret_cast<decltype(api.trackFloating)>(info->get("TrackFX_GetFloatingWindow"));
    api.trackItemCount = reinterpret_cast<decltype(api.trackItemCount)>(info->get("CountTrackMediaItems"));
    api.trackItem = reinterpret_cast<decltype(api.trackItem)>(info->get("GetTrackMediaItem"));
    api.takeCount = reinterpret_cast<decltype(api.takeCount)>(info->get("CountTakes"));
    api.take = reinterpret_cast<decltype(api.take)>(info->get("GetTake"));
    api.takeFXCount = reinterpret_cast<decltype(api.takeFXCount)>(info->get("TakeFX_GetCount"));
    api.takeFloating = reinterpret_cast<decltype(api.takeFloating)>(info->get("TakeFX_GetFloatingWindow"));
    api.refreshToolbar = reinterpret_cast<decltype(api.refreshToolbar)>(info->get("RefreshToolbar2"));
    api.getExtState = reinterpret_cast<decltype(api.getExtState)>(info->get("GetExtState"));
    api.setExtState = reinterpret_cast<decltype(api.setExtState)>(info->get("SetExtState"));
    api.trackFXGUID = reinterpret_cast<decltype(api.trackFXGUID)>(info->get("TrackFX_GetFXGUID"));
    api.takeFXGUID = reinterpret_cast<decltype(api.takeFXGUID)>(info->get("TakeFX_GetFXGUID"));
    mainWindow = fromSwellHandle(info->main);
    regWindow = info->reg;
    toggleID = regWindow("custom_action", &kToggle);
    if (toggleID <= 0) goto fail;
    moveID = regWindow("custom_action", &kMove);
    if (moveID <= 0) goto fail;
    focusedToggleID = regWindow("custom_action", &kFocusedToggle);
    if (focusedToggleID <= 0) goto fail;
    presetToggleID = regWindow("custom_action", &kPresetToggle);
    if (presetToggleID <= 0) goto fail;
    presetAllToggleID = regWindow("custom_action", &kPresetAllToggle);
    if (presetAllToggleID <= 0) goto fail;
    if (api.showScrollBar)
        arrangeScrollbarsToggleID = std::max(0, regWindow("custom_action", &kArrangeScrollbarsToggle));
    hook2 = regWindow("hookcommand2", reinterpret_cast<void *>(onCommand2)) != 0;
    hook1 = regWindow("hookcommand", reinterpret_cast<void *>(onCommand)) != 0;
    if (!hook1 && !hook2) goto fail;
    toggleHookInstalled = regWindow("toggleaction", reinterpret_cast<void *>(toggleState)) != 0;
    savedWindows = [NSMutableArray new];
    chromeOverrides = [NSMapTable weakToStrongObjectsMapTable];
    knownFXWindows = [NSHashTable weakObjectsHashTable];
    hiddenFXPins = [NSHashTable weakObjectsHashTable];
    savedPresetPanels = [NSMutableArray new];
    presetOverrides = [NSMapTable weakToStrongObjectsMapTable];
    presetWindowKeys = [NSMapTable weakToStrongObjectsMapTable];
    mainExplicitlySelected = false;
    lastFXChosen = false;
    applicationTerminating = false;
    loadPresetSettings();
    if (arrangeScrollbarsToggleID && api.getExtState) {
        const char *value = api.getExtState(kSettingsSection, kArrangeScrollbarsKey);
        arrangeScrollbarsHidden = value && std::strcmp(value, "1") == 0;
    }
    @autoreleasepool {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        terminateObserver = [center addObserverForName:NSApplicationWillTerminateNotification object:NSApp queue:nil usingBlock:^(__unused NSNotification *note) {
            applicationTerminating = true;
        }];
        keyObserver = [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSWindow *w = note.object;
            if (w == resolveMain()) { applyChrome(w); }
            else if (isHostFXChainWindow(w)) hideFXPin(w);
            else if (w) {
                // Track actual floating FX windows when they become key,
                // before GetFocusedFX2 has necessarily updated its record.
                if (isFloatingFXWindow(w)) trackWindow(w, true);
                else checkFocusedFX();
            }
        }];
        // Preserve existing focus tracking only; all mouse events are passed
        // through unmodified to the original REAPER/SWELL and plug-in views.
        focusMouseObserver = [NSEvent addLocalMonitorForEventsMatchingMask:
            (NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown)
            handler:^NSEvent *(NSEvent *event) {
                NSWindow *w = event.window;
                if (w == resolveMain()) mainExplicitlySelected = true;
                else if (w && validFocusedFX(w)) {
                    mainExplicitlySelected = false;
                    lastFX = w;
                    lastFXChosen = true;
                    [knownFXWindows addObject:w];
                } else if (!w) {
                    NSWindow *hit = fxUnderCursor();
                    if (hit) {
                        lastFX = hit;
                        lastFXChosen = true;
                        mainExplicitlySelected = false;
                    }
                }
                return event;
            }];
        closeObserver = [center addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSWindow *w = note.object;
            if (w == movingWindow) stopMoving();
            if (w == lastFX) { lastFX = nil; lastFXChosen = false; }
            if (w == mainWindow) mainWindow = nil;
            MXPresetPanelSnapshot *preset = findPresetSnapshot(w);
            if (preset) {
                // REAPER can persist Monitoring FX sizing in WillClose.
                // Do not add the cropped host-row height back to that window.
                releaseClosingPresetViewport(preset);
                [savedPresetPanels removeObject:preset];
            }
            [presetOverrides removeObjectForKey:w];
            [presetWindowKeys removeObjectForKey:w];
            MXWindowSnapshot *s = findSnapshot(w);
            if (s) [savedWindows removeObject:s];
            [chromeOverrides removeObjectForKey:w];
            [knownFXWindows removeObject:w];
        }];
        resizeObserver = [center addObserverForName:NSWindowDidResizeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSWindow *w = note.object;
            MXPresetPanelSnapshot *preset = findPresetSnapshot(w);
            if (preset) updatePresetViewport(preset);
            rememberMonitoringHeightFromUserResize(w);
            if (arrangeScrollbarsHidden && w == resolveMain()) applyArrangeScrollbarSetting();
        }];
        updateObserver = [center addObserverForName:NSApplicationDidUpdateNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            // REAPER can restore the bars when it updates the scroll range.
            applyArrangeScrollbarSetting();
            // An FX window can receive NSWindowDidBecomeKey before REAPER updates
            // its own focused-FX record. Retry on normal UI updates, not a timer.
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now < nextUpdate) return;
            nextUpdate = now + 0.4;
            for (NSWindow *window in NSApp.windows) {
                if ([knownFXWindows containsObject:window] || isHostFXChainWindow(window))
                    hideFXPin(window);
            }
            // Keep the original REAPER contentView crop-height taller than
            // the visible window content rect. No replacement NSView or
            // plug-in-view reparenting is permitted.
            for (MXPresetPanelSnapshot *preset in [savedPresetPanels copy]) {
                NSWindow *window = preset.window;
                if (window && window.isVisible) updatePresetViewport(preset);
            }
            // Always inspect newly opened windows: otherwise an FX-specific
            // persisted override is never restored when both global toggles
            // happen to be disabled. The expensive scan runs on a changed
            // AppKit window signature or every six seconds, not every tick.
            NSWindow *main = resolveMain();
            if (main) applyChrome(main);
            uint64_t signature = visibleWindowSignature();
            if (signature != lastWindowSignature || now >= nextFullFXScan) {
                scanKnownFXNow();
                nextFullFXScan = now + 6.0;
            } else {
                checkFocusedFX();
            }
        }];
        hideAll(); // Main REAPER window now hides immediately on startup.
        applyArrangeScrollbarSetting();
    }
    return true;
fail:
    stopMoving();
    if (toggleHookInstalled) regWindow("-toggleaction", reinterpret_cast<void *>(toggleState));
    if (hook1) regWindow("-hookcommand", reinterpret_cast<void *>(onCommand));
    if (hook2) regWindow("-hookcommand2", reinterpret_cast<void *>(onCommand2));
    if (arrangeScrollbarsToggleID > 0) regWindow("-custom_action", &kArrangeScrollbarsToggle);
    arrangeScrollbarsToggleID = 0;
    if (presetAllToggleID > 0) regWindow("-custom_action", &kPresetAllToggle);
    if (presetToggleID > 0) regWindow("-custom_action", &kPresetToggle);
    if (focusedToggleID > 0) regWindow("-custom_action", &kFocusedToggle);
    if (moveID > 0) regWindow("-custom_action", &kMove);
    if (toggleID > 0) regWindow("-custom_action", &kToggle);
    toggleID = moveID = focusedToggleID = presetToggleID = presetAllToggleID = 0; hook1 = hook2 = toggleHookInstalled = false;
    chromeOverrides = nil;
    knownFXWindows = nil;
    hiddenFXPins = nil;
    savedPresetPanels = nil;
    presetOverrides = nil;
    presetWindowKeys = nil;
    savedWindows = nil;
    regWindow = nullptr; api = MXAPI{};
    return false;
}
extern "C" void MixolveFXWindowsStop() {
    if (!regWindow) return;
    @autoreleasepool {
        stopMoving();
        const bool shuttingDown = applicationTerminating || (NSApp && !NSApp.isRunning);
        clearObservers();
        if (shuttingDown) {
            // Do not grow FX windows during REAPER's save/termination sequence.
            releaseAllClosingPresetViewports();
        } else {
            // Manual extension unload while REAPER is still running.
            restoreAllPresetPanels();
            if (NSView *view = arrangeScrollbarView) setArrangeScrollbarsVisible(view, true);
            showAll();
            for (NSButton *pin in hiddenFXPins) pin.hidden = NO;
        }
        arrangeScrollbarView = nil;
        arrangeScrollbarsHidden = false;
        savedWindows = nil;
        chromeOverrides = nil;
        knownFXWindows = nil;
        hiddenFXPins = nil;
        savedPresetPanels = nil;
        presetOverrides = nil;
        presetWindowKeys = nil;
        mainWindow = nil;
        lastFX = nil;
        lastFXChosen = false;
        mainExplicitlySelected = false;
    }
    if (toggleHookInstalled) regWindow("-toggleaction", reinterpret_cast<void *>(toggleState));
    if (hook1) regWindow("-hookcommand", reinterpret_cast<void *>(onCommand));
    if (hook2) regWindow("-hookcommand2", reinterpret_cast<void *>(onCommand2));
    if (arrangeScrollbarsToggleID > 0) regWindow("-custom_action", &kArrangeScrollbarsToggle);
    arrangeScrollbarsToggleID = 0;
    if (presetAllToggleID > 0) regWindow("-custom_action", &kPresetAllToggle);
    if (presetToggleID > 0) regWindow("-custom_action", &kPresetToggle);
    if (focusedToggleID > 0) regWindow("-custom_action", &kFocusedToggle);
    if (moveID > 0) regWindow("-custom_action", &kMove);
    if (toggleID > 0) regWindow("-custom_action", &kToggle);
    toggleID = moveID = focusedToggleID = presetToggleID = presetAllToggleID = 0; hook1 = hook2 = toggleHookInstalled = false;
    regWindow = nullptr; api = MXAPI{};
}
