#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
#include <cstddef>
namespace mx {
// Rectangles are in a common coordinate system where Y increases downwards
// (SWELL Linux coordinates or negated AppKit/macOS SWELL coordinates).
struct ToolbarRect {double left,top,right,bottom;};
struct ToolbarNode {
  ToolbarRect rect;
  const void *identity;
  const void *parent;
  bool generic;
  bool visible;
};
// On macOS SWELL GetWindowRect returns Cocoa screen coordinates (Y goes UP),
// i.e. top > bottom. On Linux it returns top < bottom (Y goes DOWN).
// Negating the two Cocoa Y edges produces a common downward-oriented space.
// This must happen BEFORE scoring candidates and calculating their geometry.
inline ToolbarRect normalizeSwellRect(double left,double top,double right,double bottom,
                                      bool cocoa) {
 if(cocoa) return {left,-std::max(top,bottom),right,-std::min(top,bottom)};
 return {left,std::min(top,bottom),right,std::max(top,bottom)};
}
inline double rw(const ToolbarRect &r){return r.right-r.left;}
inline double rh(const ToolbarRect &r){return r.bottom-r.top;}
inline bool validRect(const ToolbarRect &r){
 return std::isfinite(r.left)&&std::isfinite(r.right)&&
        std::isfinite(r.top)&&std::isfinite(r.bottom)&&rw(r)>0&&rh(r)>0;
}
// Only accept a real window immediately above the TCP and sharing its left
// and right edges. Docked scripts and transport panels are NOT candidates.
inline int findMainToolbar(const std::vector<ToolbarNode> &nodes,
                           std::size_t tcpIndex) {
 if(tcpIndex>=nodes.size()||!validRect(nodes[tcpIndex].rect))return -1;
 const ToolbarNode &tcp=nodes[tcpIndex];
 if(rw(tcp.rect)<150||rh(tcp.rect)<35)return -1;
 double best=-1e12;int index=-1;
 for(std::size_t i=0;i<nodes.size();++i){
  const auto &n=nodes[i];if(i==tcpIndex||!n.visible||!n.generic||!validRect(n.rect))continue;
  const double gap=tcp.rect.top-n.rect.bottom;
  const double leftDiff=std::fabs(n.rect.left-tcp.rect.left);
  const double rightDiff=std::fabs(n.rect.right-tcp.rect.right);
  const double tolerance=std::max(12.0,rw(tcp.rect)*0.08);
  if(gap<-2||gap>18||leftDiff>tolerance||rightDiff>tolerance||
     rh(n.rect)<5||rh(n.rect)>1000||rw(n.rect)<160)continue;
  // Same parent is strong evidence.  A different parent is allowed only if
  // AppKit/SWELL wrapped the toolbar with another intermediate container.
  const double score=(n.parent==tcp.parent?100:0) +
     30-2*std::max(0.0,gap)-0.6*(leftDiff+rightDiff) - 0.01*rh(n.rect);
  if(score>best){best=score;index=static_cast<int>(i);}
 }
 return index;
}
} // namespace mx
