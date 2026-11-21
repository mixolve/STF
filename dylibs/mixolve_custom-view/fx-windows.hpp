#pragma once
#include "model.hpp"
// REAPER main window + verified floating Track/Take FX windows on macOS.
// Automatically hides native titlebars; Toggle and Move-until-click actions
// are registered in the REAPER Main Action List.
extern "C" bool MixolveFXWindowsStart(ep::Info *info);
extern "C" void MixolveFXWindowsStop();
