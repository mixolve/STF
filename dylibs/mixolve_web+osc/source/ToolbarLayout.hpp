#pragma once
// Width-only toolbar layout. No Auto Layout width constraints or scroll view:
// a control is either displayed at its full width or entirely hidden.
#include <cmath>

namespace webOscLayout {
constexpr double kPanelHeight = 30.0;
constexpr double kControlHeight = 22.0;
constexpr double kSidePadding = 6.0;
constexpr double kSpacing = 6.0;
constexpr double kMinAddressWidth = 90.0;
constexpr double kDockWidth = 76.0;
constexpr double kListenWidth = 98.0;
constexpr double kHostWidth = 166.0;
constexpr double kSendWidth = 90.0;
constexpr double kEnabledWidth = 82.0;

struct Item {
    bool visible = false;
    double x = 0.0;
    double width = 0.0;
};
struct Layout {
    Item address, dock, listen, host, send, enabled;
};

// The rightmost OSC controls disappear first. The address uses remaining
// space, but never becomes narrower than kMinAddressWidth. Below that size,
// only Dock remains (if it fits). Nothing ever pushes the window's min width.
inline Layout compute(double windowWidth) {
    Layout result{};
    if (!std::isfinite(windowWidth) || windowWidth < 0) return result;
    const double available = windowWidth - 2.0 * kSidePadding;
    if (available < kDockWidth) return result;

    // At very narrow widths keep Dock reachable without compressing the URL.
    const double base = kDockWidth + kSpacing + kMinAddressWidth;
    if (available < base) {
        result.dock = {true, kSidePadding, kDockWidth};
        return result;
    }

    bool listen = true, host = true, send = true, enabled = true;
    auto needed = [&]() {
        double fixed = kDockWidth + kSpacing + kMinAddressWidth;
        if (listen)  fixed += kSpacing + kListenWidth;
        if (host)    fixed += kSpacing + kHostWidth;
        if (send)    fixed += kSpacing + kSendWidth;
        if (enabled) fixed += kSpacing + kEnabledWidth;
        return fixed;
    };
    if (needed() > available) enabled = false;
    if (needed() > available) send = false;
    if (needed() > available) host = false;
    if (needed() > available) listen = false;

    const double excess = available - needed();
    const double addressWidth = kMinAddressWidth + excess;
    double x = kSidePadding;
    result.address = {true, x, addressWidth};
    x += addressWidth + kSpacing;
    result.dock = {true, x, kDockWidth};
    x += kDockWidth;
    if (listen)  { x += kSpacing; result.listen  = {true, x, kListenWidth}; x += kListenWidth; }
    if (host)    { x += kSpacing; result.host    = {true, x, kHostWidth}; x += kHostWidth; }
    if (send)    { x += kSpacing; result.send    = {true, x, kSendWidth}; x += kSendWidth; }
    if (enabled) { x += kSpacing; result.enabled = {true, x, kEnabledWidth}; }
    return result;
}
} // namespace webOscLayout
