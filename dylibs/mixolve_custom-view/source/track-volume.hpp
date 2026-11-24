#pragma once
// Display and edit TCP track volume as signed dB; REAPER stores linear gain.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sstream>
#include <locale>

namespace mx {
struct TrackVolumeRange {
    double minDb = -72.0;
    double maxDb = 12.0;
};
inline double volumeGainFromDb(double db) {
    return std::pow(10.0, db / 20.0);
}
inline std::string trackVolumeDisplay(double linear) {
    if (!(linear > 0.0) || !std::isfinite(linear)) return "MUTED";
    double db = 20.0 * std::log10(linear);
    if (!std::isfinite(db) || db < -99.99 - 1e-9) return "MUTED";
    // Avoid "-00.00" for a value that rounds to zero.
    if (std::abs(db) < .005) db = 0.0;
    char out[64]{};
    std::snprintf(out, sizeof(out), "%+06.2f", db);
    // A decimal point is required regardless of the host's numeric locale.
    std::string display(out);
    std::replace(display.begin(), display.end(), ',', '.');
    return display;
}
inline bool parseTrackVolume(const std::string &source, double &linear, TrackVolumeRange range) {
    auto first = source.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return false;
    auto last = source.find_last_not_of(" \t\r\n");
    std::string s = source.substr(first, last - first + 1);
    if (s.size() >= 2 && (s.compare(s.size()-2, 2, "dB") == 0 ||
                          s.compare(s.size()-2, 2, "db") == 0)) {
        s.resize(s.size()-2);
        while (!s.empty() && s.back() == ' ') s.pop_back();
    }
    if (s == "MUTED" || s == "muted" || s == "Muted" ||
        s == "-inf" || s == "-INF" || s == "-infinity" || s == "-INFINITY") {
        linear = 0.0; return true;
    }
    std::replace(s.begin(), s.end(), ',', '.');
    if (s.empty()) return false;
    // Parse with the classic numeric locale even if REAPER/macOS uses a comma
    // locale; reject trailing junk rather than silently accepting partial input.
    std::istringstream input(s);
    input.imbue(std::locale::classic());
    double db = 0.0;
    if (!(input >> db)) return false;
    char extra = '\0';
    if ((input >> extra) || !input.eof() || !std::isfinite(db)) return false;
    double v = volumeGainFromDb(std::clamp(db, range.minDb, range.maxDb));
    if (!std::isfinite(v) || v <= 0.0) return false;
    linear = v;
    return true;
}
}
