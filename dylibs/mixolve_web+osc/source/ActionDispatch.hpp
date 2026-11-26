#pragma once
#include "OscCodec.hpp"
#include "RecoveredReaperCallbacks.hpp"

namespace recovered {
// Returns the accepted action ID, including when the desired state is already set.
// Returns 0 for an invalid request.
// This is a C++-only adapter and is testable without REAPER/AppKit.
int dispatchAction(const OscActionRequest &request,
                   const RecoveredReaperCallbacks &callbacks);
}
