#pragma once
#include "OscCodec.hpp"
#include "RecoveredReaperCallbacks.hpp"

namespace recovered {
// Returns true only if an action was actually executed.
// This is a C++-only adapter and is testable without REAPER/AppKit.
bool dispatchAction(const OscActionRequest &request,
                    const RecoveredReaperCallbacks &callbacks);
}
