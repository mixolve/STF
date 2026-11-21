#pragma once
// Pure state machine for bottom-edge hover activation. All times are seconds
// on a monotonic clock. The panel is hidden initially. Re-entering the edge
// starts a fresh 500ms dwell; moving away cancels the pending reveal.
#include <cmath>

namespace webOscVisibility {
constexpr double kShowAfterSeconds = 0.500;
constexpr double kEdgeTriggerHeight = 14.0; // points from the bottom edge

struct State {
    bool visible = false;
    double enteredEdgeAt = -1.0;

    void reset() {
        visible = false;
        enteredEdgeAt = -1.0;
    }

    // inside: pointer is inside the browser's content view
    // atEdge: pointer is inside and within the activation strip at the bottom
    // overPanel: pointer is over the visible toolbar, including its controls
    // editing: keep toolbar visible while a text field has focus
    bool update(double now, bool inside, bool atEdge, bool overPanel, bool editing) {
        if (!std::isfinite(now)) {
            reset();
            return visible;
        }
        if (visible) {
            if (!inside || (!overPanel && !editing)) reset();
            return visible;
        }
        if (!inside || !atEdge) {
            enteredEdgeAt = -1.0;
            return false;
        }
        if (enteredEdgeAt < 0.0 || now < enteredEdgeAt) {
            enteredEdgeAt = now;
            return false;
        }
        if (now - enteredEdgeAt >= kShowAfterSeconds) {
            visible = true;
            enteredEdgeAt = -1.0;
        }
        return visible;
    }
};
} // namespace webOscVisibility
