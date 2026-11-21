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
    // editing: keep toolbar visible while a toolbar text field has focus,
    //          even if the pointer leaves the browser view
    // popupOpen: keep a visible toolbar open while a native menu/popover is up
    bool update(double now, bool inside, bool atEdge, bool overPanel,
                bool editing, bool popupOpen) {
        if (!std::isfinite(now)) {
            reset();
            return visible;
        }
        if (visible) {
            // Popup menus frequently sit outside the toolbar/browser bounds.
            // Pointer location alone must not dismiss a toolbar in use.
            if (!editing && !popupOpen && (!inside || !overPanel)) reset();
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
