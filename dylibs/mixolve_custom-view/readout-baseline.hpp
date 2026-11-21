#pragma once

namespace mx {
struct BaselineMetrics {
    double ascent;
    double descent;
    double height;
};

// Port of the integer rounding/placement part of CFXReadoutBaseline.
// Input ascent/descent must already be scaled to the font size used by CoreText.
// The caller validates fonts and finite metric values.
double readoutBaseline(BaselineMetrics metrics);
}
