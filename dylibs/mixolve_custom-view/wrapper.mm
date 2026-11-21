// mixolve_custom-view — standalone REAPER extension entry.
// The window controller is independent of envelope/SWS and track-name APIs.
#import <Foundation/Foundation.h>
#include "model.hpp"
#include "fx-windows.hpp"

extern "C" int MixolveEnvelopeEntry(ep::Info *);
extern "C" void MixolveKeyboardStart();
extern "C" void MixolveKeyboardStop();
extern "C" bool MixolveTrackNameEntry(ep::Info *);

static bool started = false;
static bool windowsStarted = false;
static bool envelopeStarted = false;
static bool keyboardStarted = false;
static bool trackNameStarted = false;

extern "C" __attribute__((visibility("default")))
int ReaperPluginEntry(void *module, ep::Info *info) {
    (void)module;
    @autoreleasepool {
        if (!info) {
            if (started) {
                if (windowsStarted) MixolveFXWindowsStop();
                if (trackNameStarted) MixolveTrackNameEntry(nullptr);
                if (envelopeStarted) MixolveEnvelopeEntry(nullptr);
                if (keyboardStarted) MixolveKeyboardStop();
            }
            started = windowsStarted = envelopeStarted = keyboardStarted = trackNameStarted = false;
            return 0;
        }
        if (started) return 1;
        if (info->version != 0x20e || !info->get || !info->reg) return 0;

        // Windows register first so the two Main-section actions remain
        // available even if SWS/envelope or rename APIs are unavailable.
        windowsStarted = MixolveFXWindowsStart(info);
        envelopeStarted = MixolveEnvelopeEntry(info) != 0;
        MixolveKeyboardStart();
        keyboardStarted = true;
        trackNameStarted = MixolveTrackNameEntry(info);

        started = windowsStarted || envelopeStarted || trackNameStarted;
        if (!started) {
            if (keyboardStarted) MixolveKeyboardStop();
            keyboardStarted = false;
            return 0;
        }
        return 1;
    }
}
