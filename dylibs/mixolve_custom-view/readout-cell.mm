// Independent reconstruction of the CFXCenteredVolumeCell drawing geometry.
// Does not depend on any previous dylib, object layout, or undocumented offsets.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include "readout-baseline.hpp"
#include <cmath>
#include <limits>

namespace {
static CGFloat centeredBaseline(NSFont *font, CGFloat height) {
    if (!font || height <= 0.0) return NAN;
    CTFontRef ct = CTFontCreateWithName((__bridge CFStringRef)font.fontName,
                                        font.pointSize * 2.0, nullptr);
    if (!ct) return NAN;
    double ascent = CTFontGetAscent(ct), descent = CTFontGetDescent(ct);
    CFDataRef os2 = CTFontCopyTable(ct, kCTFontTableOS2, kCTFontTableOptionNoOptions);
    const CGFloat units = CTFontGetUnitsPerEm(ct);
    if (os2 && CFDataGetLength(os2) >= 78 && units > 0.0) {
        const UInt8 *bytes = CFDataGetBytePtr(os2);
        double scale = (font.pointSize * 2.0) / units;
        ascent = (double)((bytes[74] << 8) | bytes[75]) * scale;
        descent = (double)((bytes[76] << 8) | bytes[77]) * scale;
    }
    if (os2) CFRelease(os2);
    CFRelease(ct);
    if (!std::isfinite(ascent) || !std::isfinite(descent)) return NAN;
    return (CGFloat)mx::readoutBaseline({ascent, descent, (double)height});
}
}

@interface MXCenteredReadoutCell : NSTextFieldCell
@end
@implementation MXCenteredReadoutCell
- (NSRect)drawingRectForBounds:(NSRect)bounds {
    NSFont *font = self.font;
    if (!font) return [super drawingRectForBounds:bounds];
    CGFloat baseline = centeredBaseline(font, bounds.size.height);
    if (!std::isfinite(baseline)) return [super drawingRectForBounds:bounds];
    NSLayoutManager *manager = [[NSLayoutManager alloc] init];
    CGFloat lineHeight = [manager defaultLineHeightForFont:font];
    CGFloat defaultBaseline = [manager defaultBaselineOffsetForFont:font];
    if (!std::isfinite(lineHeight) || lineHeight <= 0) return [super drawingRectForBounds:bounds];
    bounds.origin.y += baseline - defaultBaseline;
    bounds.size.height = lineHeight;
    return bounds;
}
- (NSRect)titleRectForBounds:(NSRect)bounds {
    return [self drawingRectForBounds:bounds];
}
@end

// Factory avoids relying on the class name of any formerly embedded native core.
extern "C" NSTextFieldCell *MXCreateCenteredReadoutCell(NSString *text) {
    return [[MXCenteredReadoutCell alloc] initTextCell:text ?: @""];
}
