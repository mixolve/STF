#pragma once
#include "model.hpp"
// REAPER main window + verified floating Track/Take FX windows on macOS.
// Automatically hides native titlebars. Registers global and focused chrome
// toggles, Move-until-click, and a focused FX preset-panel toggle.
extern "C" bool MixolveFXWindowsStart(ep::Info *info);
extern "C" void MixolveFXWindowsStop();

void MixolveRefreshArrangeViewAfterInput();

#ifdef __OBJC__
@class NSWindow;
bool MixolveIsFXShortcutWindow(NSWindow *window);
#endif
