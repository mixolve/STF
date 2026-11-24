#pragma once
// Geometry shared by the native TCP volume badge and its inline editor.
// REAPER supplies the WALTER rect for both the painted and editable label.
#include <algorithm>
#include <cmath>

namespace mx {
inline double trackVolumeFontSize(double cellWidth, double textWidth,
                                  double baseSize) {
    if (!std::isfinite(cellWidth) || cellWidth <= 0.0 ||
        !std::isfinite(textWidth) || textWidth <= 0.0 ||
        !std::isfinite(baseSize) || baseSize <= 0.0) return baseSize;
    const double available = std::max(1.0, cellWidth - 4.0);
    return textWidth <= available ? baseSize :
        std::max(9.0, std::min(baseSize, baseSize * available / textWidth));
}
inline double trackVolumeBaseline(double height, double capHeight,
                                  double backingScale) {
    if (!std::isfinite(height) || !std::isfinite(capHeight) ||
        !std::isfinite(backingScale) || height <= 0.0 ||
        capHeight <= 0.0 || backingScale <= 0.0) return 0.0;
    return std::round((height - capHeight) * 0.5 * backingScale) / backingScale;
}
}
