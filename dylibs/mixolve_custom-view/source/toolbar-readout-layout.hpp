#pragma once
#include <algorithm>
#include <cmath>
namespace mx {
struct ReadoutLayout {
 double overlayWidth=0.0;
 double prefixScale=1.0;
 double valueX=4.0;
 double valueWidth=0.0;
};
// Click target occupies the ENTIRE value slot, not the glyph bounds.
// Its height equals the existing compact overlay; this does not resize it.
struct ValueHitRect {double x=0,y=0,width=0,height=0;};
inline ValueHitRect readoutValueHitRect(double panelWidth,double panelHeight,
                                        double valueX){
 if(!std::isfinite(panelWidth)||!std::isfinite(panelHeight)||
    !std::isfinite(valueX)||panelWidth<=0||panelHeight<=0)return {};
 const double left=std::clamp(valueX-12.0,0.0,panelWidth);
 return {left,0.0,panelWidth-left,panelHeight};
}
// Fit the child overlay to actual glyph widths, not the entire REAPER toolbar.
// Always leave a reachable field hit target when possible, independently of
// the amount of text in the automation value.
inline ReadoutLayout layoutReadout(double available, double prefixNatural,
                                    double valueNatural) {
 ReadoutLayout r{};
 if (!std::isfinite(available)||!std::isfinite(prefixNatural)||
     !std::isfinite(valueNatural)||available<=0) return r;
 constexpr double left=4.0,right=4.0;
 const double full=std::max(0.0, available);
 const double naturalPrefix=std::max(0.0,prefixNatural);
 const double naturalHit=std::clamp(valueNatural+22.0,76.0,200.0);
 const double idealWidth=left+naturalPrefix+naturalHit+right;
 r.overlayWidth=std::min(full,std::ceil(idealWidth));
 const double usable=std::max(0.0,r.overlayWidth-left-right);
 const double hit=std::min(usable,std::max(54.0,std::min(naturalHit,usable*0.45)));
 const double prefixSpace=std::max(0.0,usable-hit);
 r.prefixScale=naturalPrefix>0 ? std::clamp(prefixSpace/naturalPrefix,0.01,1.0) : 1.0;
 r.valueX=left+std::min(naturalPrefix*r.prefixScale,prefixSpace);
 r.valueWidth=std::max(0.0,r.overlayWidth-right-r.valueX);
 return r;
}
// Keep the text in view when the user reduces toolbar height. Never reject a
// verified toolbar just because its height is smaller than a font's line box.
inline double toolbarTextTopInset(double toolbarHeight,double normalTopInset=9.0,
                                 double lineHeight=20.0) {
 if(!std::isfinite(toolbarHeight)||toolbarHeight<0)return 0;
 return std::min(normalTopInset,std::max(0.0,toolbarHeight-lineHeight));
}
}
