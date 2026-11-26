// Reconstructed REAPER extension integration, not original source.
// The registration scheme, exposed CWB_Open API, dependencies and API names
// are all supported by the inspected arm64 Mach-O; implementation is new.
#import "RecoveredInterfaces.h"
#import "RecoveredReaperCallbacks.hpp"
#include "ReaperMinimal.hpp"
#include "CrashTrace.hpp"
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cstdio>
#import <objc/message.h>

static reaper_plugin_info_t *sPlugin = nullptr;
static BrowserController *sBrowser = nil;
static BrowserOscFeedback *sOsc = nil;
static int sOpenId = 0;
static custom_action_register_t sOpenAction = {0, "MIXOLVE_WEB_OSC_OPEN", "mixolve_web+osc: open", nullptr};

using MainOnCommand = void (*)(int, int);
using GetToggleState = int (*)(int, int);
using NamedCommandLookup = int (*)(const char *);
using ReverseNamedCommandLookup = const char *(*)(int);
using GetResourcePath = const char *(*)();
using DockAddEx = void (*)(HWND, const char *, const char *, bool);
using DockRemove = void (*)(HWND);
using DockActivate = void (*)(HWND);
using GetExtState = const char *(*)(const char *, const char *);
using SetExtState = void (*)(const char *, const char *, const char *, bool);

static MainOnCommand sRun = nullptr;
static GetToggleState sToggle = nullptr;
static NamedCommandLookup sNamed = nullptr;
static ReverseNamedCommandLookup sReverse = nullptr;
static GetResourcePath sResource = nullptr;
static DockAddEx sDockAdd = nullptr;
static DockRemove sDockRemove = nullptr;
static DockActivate sDockActivate = nullptr;
static GetExtState sGetExtState = nullptr;
static SetExtState sSetExtState = nullptr;

static void runAction(int id) { if (sRun) sRun(id, 0); }
static int toggleState(int id) { return sToggle ? sToggle(0, id) : -1; }
static int namedLookup(const char *name) { return sNamed ? sNamed(name) : 0; }
static const char *reverseLookup(int id) { return sReverse ? sReverse(id) : nullptr; }
static const char *resourcePath() { return sResource ? sResource() : nullptr; }
static const char *extGet(const char *section, const char *name) {
    return sGetExtState ? sGetExtState(section, name) : nullptr;
}
static void extSet(const char *section, const char *name, const char *value, bool persistent) {
    if (sSetExtState) sSetExtState(section, name, value, persistent);
}

// On macOS, a REAPER HWND is a SWELL window handle. It is NOT safe to
// substitute an arbitrary AppKit NSView. Resolve SWELL's own window creation
// and destruction functions from the REAPER app delegate at runtime. This
// avoids installing/downloading WDL while preserving the host's SWELL ABI.
// Reference: WDL/swell/swell.h, swell-functions.h, and SWELL_CreateDialog.
using SwellDialogProc = intptr_t (*)(HWND, unsigned int, uintptr_t, intptr_t);
using SwellCreateDialog = HWND (*)(void *, const char *, HWND, SwellDialogProc, intptr_t);
using SwellDestroyWindow = void (*)(HWND);
using SwellGetFunc = void *(*)(const char *);

static SwellCreateDialog sSwellCreateDialog = nullptr;
static SwellDestroyWindow sSwellDestroyWindow = nullptr;
static HWND sMainHWND = nullptr;

// This is a host-created SWELL handle; the empty callback deliberately
// forwards unhandled window messages to the SWELL implementation.
static intptr_t swellDockDialogProc(HWND, unsigned int, uintptr_t, intptr_t) {
    return 0;
}
static bool initSwellDockBackend() {
    if (sSwellCreateDialog && sSwellDestroyWindow) return true;
    id delegate = NSApp.delegate;
    SEL selector = @selector(swellGetAPPAPIFunc);
    if (!delegate || ![delegate respondsToSelector:selector]) {
        webOscTrace("dock: REAPER SWELL API provider unavailable");
        return false;
    }
    // objc_msgSend is called with a fully typed function signature.
    using GetProvider = void *(*)(id, SEL);
    auto provider = reinterpret_cast<SwellGetFunc>(
        reinterpret_cast<GetProvider>(objc_msgSend)(delegate, selector));
    if (!provider) {
        webOscTrace("dock: SWELL function provider is null");
        return false;
    }
    auto create = reinterpret_cast<SwellCreateDialog>(provider("SWELL_CreateDialog"));
    auto destroy = reinterpret_cast<SwellDestroyWindow>(provider("DestroyWindow"));
    if (!create || !destroy) {
        webOscTrace("dock: SWELL_CreateDialog/DestroyWindow missing");
        return false;
    }
    sSwellCreateDialog = create;
    sSwellDestroyWindow = destroy;
    webOscTrace("dock: REAPER SWELL functions resolved");
    return true;
}
static void *createDockHost() {
    if (![NSThread isMainThread]) {
        webOscTrace("dock: host creation attempted off main thread");
        return nullptr;
    }
    if (!sMainHWND) {
        webOscTrace("dock: REAPER main HWND unavailable");
        return nullptr;
    }
    if (!initSwellDockBackend()) return nullptr;
    // IMPORTANT: null resource ID is supported for a CHILD SWELL dialog,
    // but requires a valid parent HWND. The old code passed null as parent,
    // producing an invalid/empty host on macOS.
    // ReaperPluginEntry supplies rec->hwnd_main (a host-owned SWELL HWND).
    HWND hwnd = sSwellCreateDialog(nullptr, nullptr, sMainHWND, swellDockDialogProc, 0);
    if (!hwnd) {
        webOscTrace("dock: SWELL_CreateDialog returned null");
        return nullptr;
    }
    id object = (__bridge id)hwnd;
    // Cocoa NSView alone is not enough. SWELL-created HWNDs respond to its
    // message dispatcher. This guard avoids feeding a plain AppKit view to
    // DockWindowAddEx.
    if (![object isKindOfClass:[NSView class]] ||
        ![object respondsToSelector:@selector(onSwellMessage:p1:p2:)]) {
        webOscTrace("dock: host is not a SWELL HWND; destroying");
        sSwellDestroyWindow(hwnd);
        return nullptr;
    }
    NSView *view = (NSView *)object;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    char msg[160];
    std::snprintf(msg, sizeof(msg), "dock: genuine SWELL child HWND created: %p", hwnd);
    webOscTrace(msg);
    return hwnd;
}
static void destroyDockHost(void *handle) {
    if (handle && sSwellDestroyWindow) {
        sSwellDestroyWindow(reinterpret_cast<HWND>(handle));
        webOscTrace("dock: SWELL host destroyed");
    }
}
static void dockAdd(void *view, const char *name, const char *identifier, bool visible) {
    if (sDockAdd) sDockAdd(reinterpret_cast<HWND>(view), name, identifier, visible);
}
static void dockRemove(void *view) {
    if (sDockRemove) sDockRemove(reinterpret_cast<HWND>(view));
}
static void dockActivate(void *view) {
    if (sDockActivate) sDockActivate(reinterpret_cast<HWND>(view));
}

// Initialize OSC when the user first opens the browser.
static void startOscWhenReady() {
    if (sOsc || !sResource) return;
    const char *rawPath = resourcePath();
    if (!rawPath || !*rawPath) return;
    webOscTrace("OSC: initialize begin");
    NSString *directory = [NSString stringWithUTF8String:rawPath];
    if (!directory) return;
    NSString *config = [directory stringByAppendingPathComponent:@"browser-osc-feedback.json"];
    sOsc = [[BrowserOscFeedback alloc] initWithPath:config];
    __weak BrowserOscFeedback *weakOsc = sOsc;
    sOsc.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *) {
        [weakOsc tick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:sOsc.timer forMode:NSRunLoopCommonModes];
    webOscTrace("OSC: initialized / timer active");
}

extern "C" bool CWB_Open(const char *url) {
    webOscTrace("CWB_Open: requested");
    if (![NSThread isMainThread]) {
        webOscTrace("CWB_Open: rejected non-main thread");
        return false;
    }
    @autoreleasepool {
        @try {
            bool createdNow = false;
            if (!sBrowser) {
                webOscTrace("CWB_Open: browser construction begin");
                sBrowser = [BrowserController new];
                if (!sBrowser || !sBrowser.window) {
                    webOscTrace("CWB_Open: BrowserController did not create a window");
                    sBrowser = nil;
                    return false;
                }
                createdNow = true;
                webOscTrace("CWB_Open: browser construction complete");
                // Restore the stored preference on the first browser opening,
                // without rewriting it. Missing preference means floating mode.
                const char *savedDocked = extGet("CustomWebBrowser", "docked");
                if (savedDocked && std::strcmp(savedDocked, "1") == 0) {
                    webOscTrace("CWB_Open: restoring saved docked state");
                    if (![sBrowser applyDocked:YES persistState:NO])
                        webOscTrace("CWB_Open: saved docking could not be restored");
                }
            }
            if (url && *url) {
                NSString *address = [NSString stringWithUTF8String:url];
                if (address) [sBrowser showURL:address];
            } else if (createdNow) {
                // Only restore at the first opening. Reopening an already
                // visible browser must not reset its current page.
                [sBrowser restoreLastPage];
            }
            if (sBrowser.docked) {
                if (sBrowser.dockHost) dockActivate((__bridge void *)sBrowser.dockHost);
            } else {
                webOscTrace("CWB_Open: showing window");
                [sBrowser.window makeKeyAndOrderFront:nil];
                [sBrowser.window orderFrontRegardless];
                webOscTrace("CWB_Open: ordered front regardless");
            }
            // Failure to initialize OSC must not hide the native browser.
            @try { startOscWhenReady(); }
            @catch (NSException *exception) {
                webOscTraceObjCException("CWB_Open: OSC startup exception", exception);
            }
            webOscTrace("CWB_Open: complete");
            return true;
        } @catch (NSException *exception) {
            webOscTraceObjCException("CWB_Open: Objective-C exception", exception);
            NSLog(@"web+osc: opening browser failed: %@", exception);
            return false;
        }
    }
}

// Matches the native ReaScript vararg wrapper for a bool return value.
static void *CWB_Open_vararg(void **argv, int argc) {
    const char *url = argc > 0 && argv ? static_cast<const char *>(argv[0]) : "";
    return reinterpret_cast<void *>(static_cast<intptr_t>(CWB_Open(url)));
}
static const char kApiDescription[] =
    "bool\0const char*\0url\0Open the REAPER web browser; empty URL shows the existing page.\0";

static bool dispatchCustomAction(int command, const char *origin) {
    if (sOpenId <= 0 || command != sOpenId) return false;
    char line[160];
    std::snprintf(line, sizeof(line), "%s: command=%d open=%d",
                  origin, command, sOpenId);
    webOscTrace(line);
    return CWB_Open(nullptr);
}
// hookcommand2 covers keyboard/MIDI/OSC invocation. hookcommand also covers
// ordinary main-section actions (including invocation from Actions list).
static bool hookCommand(KbdSectionInfo *, int command, int, int, int, HWND) {
    return dispatchCustomAction(command, "hookcommand2");
}
static bool hookMainCommand(int command, int flag) {
    (void)flag;
    return dispatchCustomAction(command, "hookcommand");
}
static void unregisterPlugin() {
    webOscTrace("plugin: unloading");
    [sOsc stop]; sOsc = nil;
    if (sBrowser) { [sBrowser shutdown]; [sBrowser.window orderOut:nil]; sBrowser = nil; }
    if (sPlugin && sPlugin->Register) {
        sPlugin->Register("-hookcommand2", reinterpret_cast<void *>(hookCommand));
        sPlugin->Register("-hookcommand", reinterpret_cast<void *>(hookMainCommand));
        sPlugin->Register("-custom_action", &sOpenAction);
        sPlugin->Register("-API_CWB_Open", reinterpret_cast<void *>(CWB_Open));
        sPlugin->Register("-APIvararg_CWB_Open", reinterpret_cast<void *>(CWB_Open_vararg));
        sPlugin->Register("-APIdef_CWB_Open", const_cast<char *>(kApiDescription));
    }
    sPlugin = nullptr;
    sOpenId = 0;
    installRecoveredReaperCallbacks({});
    sRun = nullptr; sToggle = nullptr; sNamed = nullptr; sReverse = nullptr;
    sResource = nullptr;
    sDockAdd = nullptr; sDockRemove = nullptr; sDockActivate = nullptr;
    sSwellCreateDialog = nullptr; sSwellDestroyWindow = nullptr; sMainHWND = nullptr;
    sGetExtState = nullptr; sSetExtState = nullptr;
}

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(
    REAPER_PLUGIN_HINSTANCE, reaper_plugin_info_t *rec) {
    @autoreleasepool {
        webOscTrace("plugin: entry / build=webkit-swell-child-docking-v3");
        if (!rec) { unregisterPlugin(); return 0; }
        if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->Register || !rec->GetFunc)
            return 0;
        sPlugin = rec;
        sMainHWND = rec->hwnd_main;
        if (!sMainHWND) { webOscTrace("plugin: missing main HWND"); sPlugin = nullptr; return 0; }
        webOscTrace("plugin: version and pointers verified");
        auto get = rec->GetFunc;
        sRun = reinterpret_cast<MainOnCommand>(get("Main_OnCommand"));
        sToggle = reinterpret_cast<GetToggleState>(get("GetToggleCommandStateEx"));
        sNamed = reinterpret_cast<NamedCommandLookup>(get("NamedCommandLookup"));
        sReverse = reinterpret_cast<ReverseNamedCommandLookup>(get("ReverseNamedCommandLookup"));
        sResource = reinterpret_cast<GetResourcePath>(get("GetResourcePath"));
        sDockAdd = reinterpret_cast<DockAddEx>(get("DockWindowAddEx"));
        sDockRemove = reinterpret_cast<DockRemove>(get("DockWindowRemove"));
        sDockActivate = reinterpret_cast<DockActivate>(get("DockWindowActivate"));
        sGetExtState = reinterpret_cast<GetExtState>(get("GetExtState"));
        sSetExtState = reinterpret_cast<SetExtState>(get("SetExtState"));
        if (!sRun || !sToggle || !sResource) { webOscTrace("plugin: mandatory API missing"); unregisterPlugin(); return 0; }
        webOscTrace("plugin: REAPER functions resolved");
        installRecoveredReaperCallbacks({toggleState, runAction, namedLookup,
            reverseLookup, dockAdd, dockRemove, dockActivate, createDockHost,
            destroyDockHost, resourcePath, extGet, extSet});
        sOpenId = rec->Register("custom_action", &sOpenAction);
        if (!sOpenId) {
            webOscTrace("plugin: open action registration failed");
            unregisterPlugin(); return 0;
        }
        {
            char line[160];
            std::snprintf(line, sizeof(line), "plugin: action registered open=%d", sOpenId);
            webOscTrace(line);
        }
        if (!rec->Register("hookcommand2", reinterpret_cast<void *>(hookCommand))) {
            webOscTrace("plugin: hookcommand2 registration failed");
            unregisterPlugin(); return 0;
        }
        if (!rec->Register("hookcommand", reinterpret_cast<void *>(hookMainCommand))) {
            webOscTrace("plugin: hookcommand registration failed");
            unregisterPlugin(); return 0;
        }
        rec->Register("API_CWB_Open", reinterpret_cast<void *>(CWB_Open));
        rec->Register("APIvararg_CWB_Open", reinterpret_cast<void *>(CWB_Open_vararg));
        rec->Register("APIdef_CWB_Open", const_cast<char *>(kApiDescription));
        webOscTrace("plugin: callbacks registered, OSC deferred until browser opens");
        // An opt-in environment variable enables OSC before the browser opens.
        const char *eager = std::getenv("REAPER_WEB_OSC_EAGER_OSC");
        if (eager && std::strcmp(eager, "1") == 0) startOscWhenReady();
        webOscTrace("plugin: entry success");
        return 1;
    }
}
