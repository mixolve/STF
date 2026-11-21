#include "readout-baseline.hpp"
#include <cmath>
#include <cstdint>
#include <limits>

namespace mx {
double readoutBaseline(BaselineMetrics m) {
    if (!std::isfinite(m.ascent) || !std::isfinite(m.descent) ||
        !std::isfinite(m.height) || m.height <= 0.0 ||
        m.height >= 100000.0 || std::abs(m.ascent) >= 100000.0 ||
        std::abs(m.descent) >= 100000.0) return 0.0;

    // ARM64 fcvtas: nearest integer with halves away from zero.
    const std::int32_t total = static_cast<std::int32_t>(
        std::round(m.ascent + m.descent));
    const std::int32_t minimum = static_cast<std::int32_t>(
        std::round(m.height / 10.0)) + 2;
    const std::int32_t maximum =
        (static_cast<std::int32_t>(std::trunc(m.height)) - 2) * 2 + 2;
    // ARM64 signed division by two truncates toward zero.
    const std::int32_t placement = minimum + (maximum - minimum)/2
        - total/2 + static_cast<std::int32_t>(std::floor(m.ascent));
    return 1.0 + static_cast<double>(placement)/2.0;
}
}
