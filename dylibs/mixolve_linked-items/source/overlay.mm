#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "engine.hpp"
#include "mouse_modifier.hpp"
namespace {
struct DisplayBox {engine::Box box;NSRect frame;double gripWidth=0;};
std::vector<DisplayBox>display;
NSView *hostView=nil;
NSView *mirroredOverlay=nil;
NSTimer *refreshTimer=nil;
id mouseMonitor=nil;bool capturedLeft=false,capturedRight=false,capturedOther=false;
Class mirrorClass=Nil;
IMP originalNeeds=nullptr,originalRect=nullptr,originalWheel=nullptr;
bool mirroring=false;
std::vector<DisplayBox>lastVisual;
std::string lastSelected;
void mirrorDirty(){
 if(mirroring||!mirroredOverlay||!hostView)return;
 mirroring=true;
 if(!NSEqualRects(mirroredOverlay.frame,hostView.bounds))mirroredOverlay.frame=hostView.bounds;
 [mirroredOverlay setNeedsDisplay:YES];[mirroredOverlay.window invalidateCursorRectsForView:mirroredOverlay];mirroring=false;
}
void parentNeeds(id self,SEL cmd,BOOL value){
 ((void(*)(id,SEL,BOOL))originalNeeds)(self,cmd,value);
 if(value&&self==hostView)mirrorDirty();
}
void parentRect(id self,SEL cmd,NSRect rect){
 ((void(*)(id,SEL,NSRect))originalRect)(self,cmd,rect);
 if(self==hostView)mirrorDirty();
}
void parentWheel(id self,SEL cmd,NSEvent*event){
 ((void(*)(id,SEL,NSEvent*))originalWheel)(self,cmd,event);
 if(self==hostView)mirrorDirty();
}
void removeMirror(){
 if(mouseMonitor){[NSEvent removeMonitor:mouseMonitor];mouseMonitor=nil;}capturedLeft=capturedRight=capturedOther=false;
 if(mirrorClass){
  SEL a=@selector(setNeedsDisplay:),b=@selector(setNeedsDisplayInRect:),c=@selector(scrollWheel:);
  Method ma=class_getInstanceMethod(mirrorClass,a),mb=class_getInstanceMethod(mirrorClass,b),mc=class_getInstanceMethod(mirrorClass,c);
  if(method_getImplementation(ma)==(IMP)parentNeeds)class_replaceMethod(mirrorClass,a,originalNeeds,method_getTypeEncoding(ma));
  if(method_getImplementation(mb)==(IMP)parentRect)class_replaceMethod(mirrorClass,b,originalRect,method_getTypeEncoding(mb));
  if(method_getImplementation(mc)==(IMP)parentWheel)class_replaceMethod(mirrorClass,c,originalWheel,method_getTypeEncoding(mc));
 }
 mirrorClass=Nil;originalNeeds=originalRect=originalWheel=nullptr;mirroredOverlay=nil;
 if(refreshTimer){[refreshTimer invalidate];[refreshTimer release];refreshTimer=nil;}
 lastVisual.clear();lastSelected.clear();
}
void installMirror(NSView*view,NSView*overlay){
 removeMirror();mirrorClass=object_getClass(view);mirroredOverlay=overlay;
 Method a=class_getInstanceMethod(mirrorClass,@selector(setNeedsDisplay:)),b=class_getInstanceMethod(mirrorClass,@selector(setNeedsDisplayInRect:));
 originalNeeds=method_getImplementation(a);originalRect=method_getImplementation(b);
 Method c=class_getInstanceMethod(mirrorClass,@selector(scrollWheel:));originalWheel=method_getImplementation(c);
 class_replaceMethod(mirrorClass,@selector(setNeedsDisplay:),(IMP)parentNeeds,method_getTypeEncoding(a));
 class_replaceMethod(mirrorClass,@selector(setNeedsDisplayInRect:),(IMP)parentRect,method_getTypeEncoding(b));
 class_replaceMethod(mirrorClass,@selector(scrollWheel:),(IMP)parentWheel,method_getTypeEncoding(c));
}
bool sameVisual(const std::vector<DisplayBox>&a,const std::vector<DisplayBox>&b){
 if(a.size()!=b.size())return false;
 for(size_t n=0;n<a.size();n++)if(a[n].box.id!=b[n].box.id||!NSEqualRects(a[n].frame,b[n].frame)||a[n].gripWidth!=b[n].gripWidth)return false;
 return true;
}
std::string menuChild,menuSource;
std::string dragId,dragParent;bool dragIsChild=false;double dragLength=0;double mouseOrigin=0,timeOrigin=0;int resizeEdge=0;bool dragIgnoresSnap=false,dragUsesItemCopy=false;
std::string snapTarget;bool snapEnd=false;double snapOffset=0;
bool arrangeFocused(){return NSApp.isActive&&hostView.window&&hostView.window.isKeyWindow;}
NSRect grip(const DisplayBox&d,int edge){double w=d.gripWidth;return NSMakeRect(edge<0?NSMinX(d.frame):NSMaxX(d.frame)-w,NSMinY(d.frame),w,d.frame.size.height);}
struct CornerTriangle {NSRect pixels;double width,height;int edge;bool bottom;};
std::vector<CornerTriangle> cornerTriangles(const DisplayBox&d){
 NSRect pixels=[mirroredOverlay convertRectToBacking:d.frame];
 double width=std::min(12.0,std::floor(pixels.size.width/2));
 double height=std::min(std::sqrt(24.0*24.0-12.0*12.0),pixels.size.height/2);
 std::vector<CornerTriangle>out;
 for(int edge:{-1,1}){for(bool bottom:{false,true})out.push_back({pixels,width,height,edge,bottom});}
 return out;
}
std::vector<NSRect> triangleRows(const CornerTriangle&t){
 std::vector<NSRect>out;
 for(int row=0;row<t.height;row++){
  double w=std::floor(t.width*(1-(row+.5)/t.height)+.5);if(w<=0)continue;
  double x=t.edge<0?NSMinX(t.pixels):NSMaxX(t.pixels)-w,y=t.bottom?NSMaxY(t.pixels)-row-1:NSMinY(t.pixels)+row;
  out.push_back([mirroredOverlay convertRectFromBacking:NSMakeRect(x,y,w,1)]);
 }return out;
}
// Erode the combined white vertical grip and corner triangles by one backing
// pixel. The middle stays 2px wide; the corner's interior joins it seamlessly.
std::vector<NSRect> selectedGripRows(const DisplayBox&d){
 NSRect pixels=[mirroredOverlay convertRectToBacking:d.frame];auto triangles=cornerTriangles(d);std::vector<NSRect>out;
 double vertical=[mirroredOverlay convertRectToBacking:grip(d,-1)].size.width;
 if(vertical<4||pixels.size.height<=2)return out;
 auto width=[&](int row){double w=vertical;for(auto&t:triangles)if(t.edge<0){double r=t.bottom?pixels.size.height-row-1:row;if(r>=0&&r<t.height)w=std::max(w,std::floor(t.width*(1-(r+.5)/t.height)+.5));}return w;};
 for(int row=1;row<pixels.size.height-1;row++){double w=std::min({width(row-1),width(row),width(row+1)})-2;if(w<=0)continue;
  for(int edge:{-1,1})out.push_back([mirroredOverlay convertRectFromBacking:NSMakeRect(edge<0?NSMinX(pixels)+1:NSMaxX(pixels)-1-w,NSMinY(pixels)+row,w,1)]);
 }return out;
}
int triangleAt(const DisplayBox&d,NSPoint p){
 if(!NSPointInRect(p,d.frame))return 0;
 for(auto&t:cornerTriangles(d))for(auto&r:triangleRows(t))if(NSPointInRect(p,r))return t.edge;
 return 0;
}
std::vector<NSRect> gripParts(const DisplayBox&d,int edge){
 return {grip(d,edge)};
}
int gripAt(const DisplayBox&d,NSPoint p){if(int edge=triangleAt(d,p))return edge;bool left=false,right=false;for(auto&r:gripParts(d,-1))left|=NSPointInRect(p,r);for(auto&r:gripParts(d,1))right|=NSPointInRect(p,r);if(left&&right)return std::abs(p.x-NSMinX(d.frame))<std::abs(p.x-NSMaxX(d.frame))?-1:1;return left?-1:right?1:0;}

int resizeAt(const DisplayBox&d,NSPoint p){if(d.box.child||triangleAt(d,p))return 0;int edge=gripAt(d,p);return edge&&NSPointInRect(p,grip(d,edge))?edge:0;}
NSView*findArrange(NSView*v){
 if(!v||![(id)v isKindOfClass:NSView.class])return nil;
 if([v respondsToSelector:NSSelectorFromString(@"getSwellClass")]){
  const char*name=((const char*(*)(id,SEL))objc_msgSend)(v,NSSelectorFromString(@"getSwellClass"));
  if(name&&!strcmp(name,"REAPERTrackListWindow"))return v;
 }
 for(NSView*child in v.subviews){NSView*found=findArrange(child);if(found)return found;}return nil;
}
std::vector<DisplayBox>layout(NSView*v){
 std::vector<DisplayBox>out;if(!engine::project||!engine::GetSet_ArrangeView2||v.bounds.size.width<=0)return out;
 double start=0,end=0;engine::GetSet_ArrangeView2(engine::project,false,0,0,&start,&end);if(end<=start)return out;
 double width=v.bounds.size.width;
 for(auto&b:engine::boxes()){
  double x=(b.start-start)*width/(end-start),right=(b.end-start)*width/(end-start);
  if(right<0||x>width||b.bottom<0||b.top>v.bounds.size.height)continue;
  NSRect pixels=[v convertRectToBacking:NSMakeRect(x,b.top,std::max(0.0,right-x),std::max(0.0,b.bottom-b.top))];
  double leftPixel=std::round(NSMinX(pixels)),rightPixel=std::round(NSMaxX(pixels)),topPixel=std::ceil(NSMinY(pixels)),bottomPixel=std::floor(NSMaxY(pixels));
  if(rightPixel<=leftPixel||bottomPixel<=topPixel)continue;
  NSRect frame=[v convertRectFromBacking:NSMakeRect(leftPixel,topPixel,rightPixel-leftPixel,bottomPixel-topPixel)];
  double gripPixels=std::min(4.0,std::floor((rightPixel-leftPixel)/2));
  double gripWidth=[v convertSizeFromBacking:NSMakeSize(gripPixels,1)].width;
  out.push_back({b,frame,gripWidth});
 }
 return out;
}
NSCursor*cursorAt(const std::vector<DisplayBox>&controls,NSPoint p){
 for(auto it=controls.rbegin();it!=controls.rend();++it){if(gripAt(*it,p))return resizeAt(*it,p)?NSCursor.resizeLeftRightCursor:NSCursor.openHandCursor;if(it->box.child&&NSPointInRect(p,it->frame))return NSCursor.openHandCursor;}return nil;
}
// Edge magnetism is a small screen-space attraction, never a collision limit.
// Compare both moving boundaries with both boundaries of every other container,
// including containers on other tracks. The grid remains the fallback.
double snapContainer(double raw,double pixelsPerSecond){
 const double scale=std::max(1e-9,pixelsPerSecond),capture=12.0/scale,release=18.0/scale;
 double grid=engine::SnapToGrid(engine::project,raw);
 auto boxes=engine::boxes();
 if(!snapTarget.empty()){
  for(const auto&box:boxes)if(box.id==snapTarget){
   double candidate=(snapEnd?box.end:box.start)-snapOffset;
   if(candidate>=0&&std::abs(candidate-raw)<=release)return candidate;
   break;
  }
  snapTarget.clear();
 }
 double result=raw,distance=capture;
 for(const auto&box:boxes){
  if(!dragUsesItemCopy&&(box.id==dragId||(!dragIsChild&&box.parent==dragParent)))continue;
  if(dragUsesItemCopy&&engine::selectedContainer!=dragId&&box.id==engine::selectedContainer)continue;
  for(bool end:{false,true})for(double offset:{0.0,dragLength}){
   double candidate=(end?box.end:box.start)-offset,d=std::abs(candidate-raw);
   if(candidate>=0&&d<=distance){result=candidate;distance=d;snapTarget=box.id;snapEnd=end;snapOffset=offset;}
  }
 }
 if(!snapTarget.empty())return result;
 // The grid gets the same capture radius, never a timeline-wide attraction.
 return std::abs(grid-raw)<=capture?grid:raw;
}

void selectBox(const std::string&id,bool containerFocus=true){engine::selectContainer(id,containerFocus);engine::UpdateArrange();}
int trackAt(double y){for(int n=0;n<engine::CountTracks(engine::project);++n){void*t=engine::GetTrack(engine::project,n);double top=engine::GetMediaTrackInfo_Value(t,"I_TCPY"),h=engine::GetMediaTrackInfo_Value(t,"I_TCPH");if(y>=top&&y<top+h)return n;}return -1;}
}
@interface KKLinkedContainerOverlay:NSView
@end
@implementation KKLinkedContainerOverlay
-(void)dealloc{[[NSNotificationCenter defaultCenter]removeObserver:self];[super dealloc];}
-(void)focusChanged:(NSNotification*)notification{
 (void)notification;engine::overlayTick();[self setNeedsDisplay:YES];[self.window invalidateCursorRectsForView:self];
}
-(BOOL)isFlipped{return YES;}
-(BOOL)isOpaque{return NO;}
-(BOOL)acceptsFirstMouse:(NSEvent*)event{(void)event;return YES;}
-(NSView*)hitTest:(NSPoint)point{
 NSPoint local=[self convertPoint:point fromView:self.superview];
 display=layout(self);
 for(auto it=display.rbegin();it!=display.rend();++it)if(gripAt(*it,local))return self;
 for(auto it=display.rbegin();it!=display.rend();++it)if(it->box.child&&NSPointInRect(local,it->frame))return self;
 return nil;
}
-(void)liveTick:(NSTimer*)timer{
 (void)timer;if(NSApp.isActive&&self.window.visible)engine::tick();
}
-(void)redrawNow{
 // Native SWELL painting and Cocoa event dispatch do not always flush a dirty
 // child view during a drag. Keep a persistent transparent layer and commit
 // its current geometry before returning from the input event.
 [self setNeedsDisplay:YES];[self displayIfNeeded];
}
-(void)drawRect:(NSRect)dirty{
 (void)dirty;display=layout(self);lastVisual=display;lastSelected=engine::selectedContainer;
 for(auto&d:display){
  [NSColor.whiteColor setFill];
  for(int edge:{-1,1})for(auto&r:gripParts(d,edge))NSRectFill(r);
  [NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext.shouldAntialias=NO;
  for(auto&t:cornerTriangles(d))for(auto&r:triangleRows(t))NSRectFill(r);
  if(d.box.id==engine::selectedContainer){
   [[NSColor colorWithSRGBRed:34.0/255 green:34.0/255 blue:34.0/255 alpha:1]setFill];
   for(auto&r:selectedGripRows(d))NSRectFill(r);
  }
  [NSGraphicsContext restoreGraphicsState];
 }
}

-(void)mouseDown:(NSEvent*)event{
 if(!arrangeFocused())return;
 [self.window makeFirstResponder:self.superview];
 NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];display=layout(self);resizeEdge=0;snapTarget.clear();
 for(auto it=display.rbegin();it!=display.rend();++it)if(gripAt(*it,p)||(it->box.child&&NSPointInRect(p,it->frame))){
  // Preserve the child-body double click that selects its parent.
  if(it->box.child&&!gripAt(*it,p)&&event.clickCount>1){selectBox(it->box.id);engine::action(1,it->box.id);[self setNeedsDisplay:YES];return;}
  auto flags=event.modifierFlags;int modifier=lc::mouseModifierFlags(flags&NSEventModifierFlagShift,flags&NSEventModifierFlagCommand,flags&NSEventModifierFlagOption,flags&NSEventModifierFlagControl);
  char assignment[128]{};engine::GetMouseModifier("MM_CTX_ITEM",modifier,assignment,sizeof(assignment));auto policy=lc::itemDragModifier(assignment);bool copy=policy.copy;dragUsesItemCopy=copy;dragIgnoresSnap=policy.ignoreSnap;int edge=copy?0:resizeAt(*it,p);selectBox(it->box.id);dragId=it->box.id;dragParent=it->box.parent;dragIsChild=it->box.child;dragLength=it->box.end-it->box.start;resizeEdge=edge;mouseOrigin=p.x;timeOrigin=edge>0?it->box.end:it->box.start;
  if(edge)engine::beginResize(dragId,edge);else engine::beginDrag(dragId,copy);[cursorAt(display,p) set];[self setNeedsDisplay:YES];return;
 }

}
-(void)mouseDragged:(NSEvent*)event{
 if(!arrangeFocused()){engine::endDrag();dragId.clear();resizeEdge=0;[self setNeedsDisplay:YES];return;}
 if(dragId.empty())return;NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
 double start=0,end=0;engine::GetSet_ArrangeView2(engine::project,false,0,0,&start,&end);
 double pos=timeOrigin+(p.x-mouseOrigin)*(end-start)/std::max(1.0,self.bounds.size.width);
 if(resizeEdge){engine::resizeTo(pos);[self redrawNow];return;}
 if(!dragIgnoresSnap&&(dragUsesItemCopy||!(event.modifierFlags&NSEventModifierFlagShift))&&engine::GetToggleCommandStateEx(0,1157)==1)pos=snapContainer(pos,std::max(1.0,self.bounds.size.width)/(end-start));
 else snapTarget.clear();
 engine::dragTo(pos,trackAt(p.y));[self redrawNow];
}
-(void)mouseUp:(NSEvent*)event{(void)event;snapTarget.clear();if(!dragId.empty()){engine::endDrag();dragId.clear();}resizeEdge=0;[self redrawNow];[self.window invalidateCursorRectsForView:self];}
-(void)rightMouseDown:(NSEvent*)event{
 [self.window makeFirstResponder:self.superview];
 NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];display=layout(self);
 bool found=false;for(auto it=display.rbegin();it!=display.rend();++it)if(gripAt(*it,p)||(it->box.child&&NSPointInRect(p,it->frame))){selectBox(it->box.id);found=true;break;}
 if(!found)return;
 NSMenu*menu=[[NSMenu alloc]initWithTitle:@"Linked container"];
 NSArray*names=@[@"Create linked copy at edit cursor",@"Select parent",@"Move container to edit cursor",@"Detach linked copy",@"Delete container"];
 for(NSUInteger n=0;n<names.count;n++){NSMenuItem*item=[[NSMenuItem alloc]initWithTitle:names[n] action:@selector(containerAction:) keyEquivalent:@""];item.target=self;item.tag=n;if(n==3)item.enabled=engine::manifest.children.count(engine::selectedContainer)>0;[menu addItem:item];[item release];}
 menuChild=engine::selectedContainer;menuSource.clear();
 if(engine::manifest.children.count(menuChild)){
  double start=0,end=0;engine::GetSet_ArrangeView2(engine::project,false,0,0,&start,&end);
  double time=start+p.x*(end-start)/std::max(1.0,self.bounds.size.width);
  for(auto&i:engine::scan())if(i.child==menuChild&&time>=i.position&&time<i.position+i.length){menuSource=i.source;break;}
  if(!menuSource.empty()){
   bool muted=engine::manifest.children.at(menuChild).muted.count(menuSource)>0;
   NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:muted?@"Remove local mute from this item":@"Mute this item in linked copy" action:@selector(containerAction:) keyEquivalent:@""];
   item.target=self;item.tag=100;[menu addItem:item];[item release];
  }
 }
 [NSMenu popUpContextMenu:menu withEvent:event forView:self];[menu release];
}
-(void)containerAction:(NSMenuItem*)item{if(item.tag==100)engine::toggleChildItemMute(menuChild,menuSource);else engine::action((int)item.tag,engine::selectedContainer);[self setNeedsDisplay:YES];}
-(void)cursorUpdate:(NSEvent*)event{if(!arrangeFocused())return;NSCursor*cursor=cursorAt(layout(self),[self convertPoint:event.locationInWindow fromView:nil]);if(cursor)[cursor set];}
-(void)resetCursorRects{
 for(auto&d:layout(self)){
  if(d.box.child)[self addCursorRect:d.frame cursor:NSCursor.openHandCursor];
  for(int edge:{-1,1}){for(auto&r:gripParts(d,edge))[self addCursorRect:r cursor:NSCursor.openHandCursor];if(!d.box.child)[self addCursorRect:grip(d,edge) cursor:NSCursor.resizeLeftRightCursor];}
  // Cursor rectangles follow each raster row of the triangle rather than
  // claiming its empty bounding-box corners.
  for(auto&t:cornerTriangles(d))for(auto&r:triangleRows(t))[self addCursorRect:r cursor:NSCursor.openHandCursor];
 }
}

@end
namespace engine {
// Native actions can also run from the Actions dialog. Their item/track/
// envelope context is checked by the engine; only app activation is required.
bool containerInputFocused(){return NSApp.isActive&&hostView.window;}
KKLinkedContainerOverlay*overlay=nil;

void overlayTick(){
 if(!arrangeFocused()){if(!dragId.empty()){engine::endDrag();dragId.clear();resizeEdge=0;}capturedLeft=capturedRight=capturedOther=false;}
 id main=(id)(GetMainHwnd?GetMainHwnd():nullptr);NSView*root=nil;
 if([main isKindOfClass:NSWindow.class])root=[main contentView];else if([main isKindOfClass:NSView.class])root=main;
 NSView*arrange=findArrange(root);
 if(!arrange){removeMirror();if(overlay){[overlay removeFromSuperview];[overlay release];overlay=nil;}hostView=nil;return;}
 if(!overlay||hostView!=arrange||overlay.superview!=arrange){
  removeMirror();if(overlay){[overlay removeFromSuperview];[overlay release];}
  hostView=arrange;overlay=[[KKLinkedContainerOverlay alloc]initWithFrame:arrange.bounds];
  overlay.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  overlay.wantsLayer=YES;
  overlay.layerContentsRedrawPolicy=NSViewLayerContentsRedrawDuringViewResize;
  [arrange addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
  installMirror(arrange,overlay);
  // SWELL can process mouse input on the parent before ordinary subview
  // dispatch. Consume control events before that native item-editing path.
  NSEventMask mask=NSEventMaskLeftMouseDown|NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp|NSEventMaskRightMouseDown|NSEventMaskRightMouseDragged|NSEventMaskRightMouseUp|NSEventMaskOtherMouseDown|NSEventMaskOtherMouseDragged|NSEventMaskOtherMouseUp|NSEventMaskMouseMoved;
  mouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent*(NSEvent*event){
   if(!overlay||!hostView.window||event.window!=hostView.window)return event;
   NSPoint p=[overlay convertPoint:event.locationInWindow fromView:nil];bool control=false;int edge=0;
   auto controls=layout(overlay);
   for(auto it=controls.rbegin();NSPointInRect(p,overlay.bounds)&&it!=controls.rend();++it){edge=gripAt(*it,p);if(edge||(it->box.child&&NSPointInRect(p,it->frame))){control=true;break;}}
   switch(event.type){
    case NSEventTypeLeftMouseDown:if(!control){
     if(arrangeFocused()&&NSPointInRect(p,overlay.bounds)){
      // Native parent-item clicks can choose that container, but gaps inside
      // its window are still blank arrange space and clear container selection.
      std::string id;double start=0,end=0;engine::GetSet_ArrangeView2(engine::project,false,0,0,&start,&end);
      double time=start+p.x*(end-start)/std::max(1.0,overlay.bounds.size.width);
      for(auto it=controls.rbegin();it!=controls.rend();++it)if(!it->box.child&&NSPointInRect(p,it->frame)){
       for(auto&i:engine::scan())if(engine::participates(i,it->box.id)&&time>=i.position&&time<i.position+i.length){id=it->box.id;break;}break;
      }
      selectBox(id,false);[overlay redrawNow];
     }return event;
    }capturedLeft=true;[overlay mouseDown:event];return nil;
    case NSEventTypeLeftMouseDragged:if(!capturedLeft)return event;[overlay mouseDragged:event];return nil;
    case NSEventTypeLeftMouseUp:if(!capturedLeft)return event;capturedLeft=false;[overlay mouseUp:event];return nil;
    case NSEventTypeRightMouseDown:if(!control)return event;capturedRight=true;if(arrangeFocused())[overlay rightMouseDown:event];return nil;
    case NSEventTypeRightMouseDragged:case NSEventTypeRightMouseUp:if(!capturedRight)return event;if(event.type==NSEventTypeRightMouseUp)capturedRight=false;return nil;
    case NSEventTypeOtherMouseDown:if(!control)return event;capturedOther=true;return nil;
    case NSEventTypeOtherMouseDragged:case NSEventTypeOtherMouseUp:if(!capturedOther)return event;if(event.type==NSEventTypeOtherMouseUp)capturedOther=false;return nil;
    case NSEventTypeMouseMoved:if(!control)return event;if(arrangeFocused())[cursorAt(controls,p) set];return nil;
    default:return event;
   }
  }];
  for(NSString*name in @[NSApplicationDidResignActiveNotification,NSApplicationDidBecomeActiveNotification,NSWindowDidResignKeyNotification,NSWindowDidBecomeKeyNotification])
   [[NSNotificationCenter defaultCenter]addObserver:overlay selector:@selector(focusChanged:) name:name object:nil];
  refreshTimer=[[NSTimer timerWithTimeInterval:1.0/60.0 target:overlay selector:@selector(liveTick:) userInfo:nil repeats:YES]retain];
  refreshTimer.tolerance=0.001;
  [NSRunLoop.mainRunLoop addTimer:refreshTimer forMode:NSRunLoopCommonModes];
 }
 if(!NSEqualRects(overlay.frame,arrange.bounds))overlay.frame=arrange.bounds;
 auto current=layout(overlay);if(!sameVisual(current,lastVisual)||lastSelected!=selectedContainer){[overlay redrawNow];[overlay.window invalidateCursorRectsForView:overlay];}
}
void overlayRemove(){removeMirror();if(overlay){[overlay removeFromSuperview];[overlay release];overlay=nil;}hostView=nil;display.clear();}
}
