#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include "model.hpp"
#include "main-toolbar-target.hpp"
#include "toolbar-readout-layout.hpp"
#include "cpu-status.hpp"
#include "objc-hooks.hpp"
#include <memory>
#include <algorithm>
#include <cmath>
#include <set>
#include <vector>
#include <string>
#include <cstdio>
#include <cstring>
#include <cctype>

static const char *kMixolveToolbarBuild="mixolve_toolbar_v88_arrange_scrollbars";
// The action ID matches the other REAPER action registrations; the visible
// name uses the same lowercase mixolve_custom-view prefix.
struct MXReadoutAction { int section; const char *id; const char *name; };
static MXReadoutAction kReadoutRowToggle={0,
 "MIXOLVE_CUSTOMVIEW_READOUT_ROW_TOGGLE",
 "mixolve_custom-view: toggle toolbar readout row"};
static int readoutRowActionID=0;
static bool readoutRowHook1=false,readoutRowHook2=false,readoutRowToggleHook=false;
static bool readoutRowEnabled=true;
static const char *kReadoutSection="mixolve_custom-view";
static const char *kReadoutVisibilityKey="readout_row_enabled_v1";
static const char *(*readoutGetExtState)(const char*,const char*)=nullptr;
static void (*readoutSetExtState)(const char*,const char*,const char*,bool)=nullptr;
static void (*readoutRefreshToolbar)(int,int)=nullptr;
static void toolbarDiagnostic(NSString *message){
 static NSString *previous=nil;
 if([previous isEqualToString:message])return;
 previous=[message copy];
 NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/mixolve-custom-view-toolbar.log"];
 FILE *fp=fopen(path.fileSystemRepresentation,"a");
 if(fp){fprintf(fp,"%s %s %s\n",kMixolveToolbarBuild,[[NSDate date] description].UTF8String,message.UTF8String);fclose(fp);}
}


// Independent status rendering: no binary-specific offsets, global registries,
// or custom Objective-C runtime classes are required.
extern "C" NSTextFieldCell *MXCreateCenteredReadoutCell(NSString *text);
static mx::HookRegistry statusDrawHooks;
static CGFloat rowPixel(NSView *view){return 1.0/std::max((CGFloat)1,view.window.backingScaleFactor);}
static void prepareInlineStatus(NSView *view);
static BOOL drawInlineStatus(NSView *view);
// The original REAPER status field stays in its hierarchy as a live data source.
// Its paint is suppressed only after the toolbar rendering has a valid home.
static NSView *movedStatusSource=nil;
static BOOL toolbarReadoutActive=NO;
static void loweredStatusDraw(NSView *view,SEL selector,NSRect dirty){
 IMP original = statusDrawHooks.original(view,selector);if(!original)return;
 if(!readoutRowEnabled){
  ((void(*)(id,SEL,NSRect))original)(view,selector,dirty);
  return;
 }
 prepareInlineStatus(view);
 if(toolbarReadoutActive && movedStatusSource==view)return;
 if(drawInlineStatus(view))return;
 CGContextRef context=NSGraphicsContext.currentContext.CGContext;
 CGContextSaveGState(context);CGContextTranslateCTM(context,0,(view.flipped?1:-1)*2*rowPixel(view));
 ((void(*)(id,SEL,NSRect))original)(view,selector,dirty);CGContextRestoreGState(context);
}
static void lowerStatusRow(NSTextField *status){
 Class cls=object_getClass(status);
 if (!statusDrawHooks.install(cls,@selector(drawRect:),(IMP)loweredStatusDraw)) return;
 [status setNeedsDisplay:YES];
}
static void whiteStatusText(NSTextField *status){
 if(![status.textColor isEqual:NSColor.whiteColor])status.textColor=NSColor.whiteColor;
}
static NSString *visibleStatusText(NSTextField *status){
 NSString *text=status.stringValue?:@"";
 text=[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
 text=[text stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
 text=[text stringByReplacingOccurrencesOfString:@"CPU: " withString:@""];
 text=[text stringByReplacingOccurrencesOfString:@"RAM: " withString:@""];
 return [text stringByReplacingOccurrencesOfString:@" - " withString:@" — "];
}
static NSFont *statusFont(NSTextField *status){
 return status.font?:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}
// The installed family PostScript name is IosevkaCharonMono-Regular.
// Never bundle or distribute user font binaries with the extension.
static NSFont *mainToolbarFont(){
 return [NSFont fontWithName:@"IosevkaCharonMono-Regular" size:16.0]
     ?: [NSFont fontWithName:@"Iosevka Charon Mono" size:16.0]
     ?: [NSFont monospacedSystemFontOfSize:16.0 weight:NSFontWeightRegular];
}
// Main Toolbar is its own REAPER/SWELL child window, typically class
// "unknown", which ends just before REAPERTCPDisplay begins. Importantly the
// toolbar can be hundreds of points high: it is NOT a fixed strip at TCP.top.
static NSRect mxScreenRect(NSView *view){
 return [view.window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
}
static void mxCollectViews(NSView *root,std::vector<NSView*> &out,int depth){
 if(!root||depth>12||out.size()>=2048||[root isHiddenOrHasHiddenAncestor])return;
 out.push_back(root);
 for(NSView *child in root.subviews)mxCollectViews(child,out,depth+1);
}
struct MXSWELLRect {int left,top,right,bottom;};
using MXSWELLGetWindow=void *(*)(void *,int);
using MXSWELLGetClassName=int (*)(void *,char *,int);
using MXSWELLGetRect=bool (*)(void *,MXSWELLRect *);
using MXSWELLIsVisible=int (*)(void *);
static mx::ToolbarRect mxRect(MXSWELLRect r){
#if defined(__APPLE__)
 return mx::normalizeSwellRect(r.left,r.top,r.right,r.bottom,true);
#else
 return mx::normalizeSwellRect(r.left,r.top,r.right,r.bottom,false);
#endif
}
static mx::ToolbarRect mxDownwardRect(NSRect r){
 return {NSMinX(r),-NSMaxY(r),NSMaxX(r),-NSMinY(r)};
}
static BOOL resolveMainToolbarScreenRect(void *mainHandle,NSWindow *host,
                                         NSRect *out,NSString **source){
 if(!mainHandle||!host||!host.contentView||!out)return NO;
 std::vector<NSView*> native;
 mxCollectViews(host.contentView,native,0);
 auto get=mx::findSwellAPI();
 if(get){
  auto childWindow=(MXSWELLGetWindow)get("GetWindow");
  auto className=(MXSWELLGetClassName)get("GetClassName");
  auto rect=(MXSWELLGetRect)get("GetWindowRect");
  auto visible=(MXSWELLIsVisible)get("IsWindowVisible");
  if(childWindow&&className&&rect){
   std::vector<mx::ToolbarNode> nodes;
   std::set<void*> visited;
   std::vector<std::string> classes;
   auto walk=[&](auto&& self,void *hwnd,void *parent,int depth)->void{
    if(!hwnd||depth>10||nodes.size()>2048||!visited.insert(hwnd).second)return;
    char name[256]={0};MXSWELLRect r{};
    className(hwnd,name,(int)sizeof(name));
    if(!rect(hwnd,&r))return;
    std::string klass=name;
    std::string lower=klass;std::transform(lower.begin(),lower.end(),lower.begin(),[](unsigned char c){return (char)tolower(c);});
    const bool generic=klass=="unknown"||klass.empty()||
                       lower.find("toolbar")!=std::string::npos;
    nodes.push_back({mxRect(r),hwnd,parent,generic,!visible||visible(hwnd)!=0});
    classes.push_back(klass);
    for(void *child=childWindow(hwnd,5);child;child=childWindow(child,2))
      self(self,child,hwnd,depth+1);
   };
   walk(walk,mainHandle,nullptr,0);
   std::size_t tcpIndex=nodes.size();double largest=0;
   for(std::size_t i=0;i<nodes.size();++i){
    if(classes[i]!="REAPERTCPDisplay"||!nodes[i].visible)continue;
    double area=mx::rw(nodes[i].rect)*mx::rh(nodes[i].rect);
    if(area>largest){largest=area;tcpIndex=i;}
   }
   const int toolbarIndex=mx::findMainToolbar(nodes,tcpIndex);
   if(toolbarIndex<0){
    toolbarDiagnostic([NSString stringWithFormat:@"SWELL candidates: nodes=%zu tcp=%@ window=(%.0f %.0f %.0f %.0f)",
     nodes.size(),tcpIndex<nodes.size()?@"found":@"missing",
     host.frame.origin.x,host.frame.origin.y,host.frame.size.width,host.frame.size.height]);
   }
   if(toolbarIndex>=0){
    void *target=(void*)nodes[(size_t)toolbarIndex].identity;
    void *tcp=(void*)nodes[tcpIndex].identity;
    NSView *targetView=nil,*tcpView=nil;
    for(NSView *v:native){
     if((__bridge void *)v==target)targetView=v;
     if((__bridge void *)v==tcp)tcpView=v;
    }
    // SWELL HWND is ordinarily an NSView on macOS, so use native coordinates.
    if(targetView&&targetView.window==host){
     *out=mxScreenRect(targetView);
     if(source)*source=@"swell-native-toolbar";
     return YES;
    }
    // A macOS HWND can be a Cocoa NSView even when its pointer is not in the
    // contentView's subview traversal. SWELL GetWindowRect already returns
    // screen coordinates on macOS. Validate them against the host's content
    // frame instead of rejecting the verified toolbar solely for lacking a
    // matching NSView in the traversal.
#if defined(__APPLE__)
    auto nativeRect=nodes[(size_t)toolbarIndex].rect;
    NSRect direct=NSMakeRect(nativeRect.left,-nativeRect.bottom,
                            mx::rw(nativeRect),mx::rh(nativeRect));
    NSRect content=mxScreenRect(host.contentView);
    if(direct.size.width>=160&&direct.size.height>=5&&
       NSMinX(direct)>=NSMinX(content)-8&&NSMaxX(direct)<=NSMaxX(content)+8&&
       NSMaxY(direct)<=NSMaxY(content)+8&&NSMinY(direct)>=NSMinY(content)-8){
     *out=direct;
     if(source)*source=@"swell-cocoa-screen-rect";
     return YES;
    }
#endif
    // Some builds wrap the toolbar HWND in an AppKit view. Anchor its SWELL
    // rect to the *actual TCP view*, never to the guessed main-window origin.
    if(!tcpView){
     for(NSView *v:native)
      if([NSStringFromClass(v.class) containsString:@"REAPERTCPDisplay"]){tcpView=v;break;}
    }
    if(tcpView&&tcpView.window==host){
     NSRect tcpScreen=mxScreenRect(tcpView);
     auto a=nodes[(size_t)toolbarIndex].rect;
     auto b=nodes[tcpIndex].rect;
     CGFloat sx=tcpScreen.size.width/mx::rw(b),sy=tcpScreen.size.height/mx::rh(b);
     if(std::isfinite(sx)&&std::isfinite(sy)&&sx>0.45&&sx<2.6&&sy>0.45&&sy<2.6){
      NSRect result=NSMakeRect(NSMinX(tcpScreen)+(a.left-b.left)*sx,
       NSMaxY(tcpScreen)-(a.bottom-b.top)*sy,mx::rw(a)*sx,mx::rh(a)*sy);
      NSRect content=mxScreenRect(host.contentView);
      if(result.size.height>=5&&result.size.width>=170&&
         NSMinX(result)>=NSMinX(content)-5&&NSMaxX(result)<=NSMaxX(content)+5&&
         NSMaxY(result)<=NSMaxY(content)+5&&NSMinY(result)>=NSMinY(content)-5){
       *out=result;
       if(source)*source=@"swell-tcp-anchored-toolbar";
       return YES;
      }
     }
    }
   }
  }
 }
 // Pure AppKit fallback: match visible sibling views by real bounds; there is
 // no fallback that fabricates a 34px strip from the TCP rectangle.
 std::vector<mx::ToolbarNode> nodes;
 std::size_t tcpIndex=native.size();double largest=0;
 for(NSView *v:native){
  NSString *cls=NSStringFromClass(v.class);
  const bool isTcp=[cls containsString:@"REAPERTCPDisplay"];
  const bool generic=![cls containsString:@"REAPER"]||
                     [[cls lowercaseString] containsString:@"toolbar"];
  NSRect r=mxScreenRect(v);
  nodes.push_back({mxDownwardRect(r),(__bridge void*)v,
                   (__bridge void*)v.superview,generic,YES});
  double area=r.size.width*r.size.height;
  if(isTcp&&area>largest){largest=area;tcpIndex=nodes.size()-1;}
 }
 int index=mx::findMainToolbar(nodes,tcpIndex);
 if(index>=0){
  NSView *target=(__bridge NSView*)nodes[(size_t)index].identity;
  *out=mxScreenRect(target);
  if(source)*source=@"appkit-toolbar";
  return YES;
 }
 if(source)*source=get?@"not-found-in-tree":@"swell-api-unavailable";
 return NO;
}
static BOOL mainToolbarPlacement(void *mainHandle,NSWindow *host,
                                 NSRect *out,NSString **source){
 NSRect toolbar=NSZeroRect;
 if(!resolveMainToolbarScreenRect(mainHandle,host,&toolbar,source))return NO;
 // The toolbar can be resized even below the line's natural height.
 // Keep a font-sized 20pt line visible rather than disabling it under 37pt.
 constexpr CGFloat insetX=4,rowHeight=20;
 if(toolbar.size.width<20||toolbar.size.height<1)return NO;
 // Move the entire readout exactly four points down. Keep the shift even
 // when the toolbar is shorter than the text, rather than silently clamping.
 const CGFloat topInset=mx::toolbarTextTopInset(toolbar.size.height,9,rowHeight)+4;
 *out=NSMakeRect(NSMinX(toolbar)+insetX,NSMaxY(toolbar)-topInset-rowHeight,
                 std::max((CGFloat)1,toolbar.size.width-2*insetX),rowHeight);
 return YES;
}
// Compact readouts are rendered at full size when possible and scaled only
// as a last resort; the original status text remains the data source.
// Abbreviate memory units only. Other measurements remain complete.
static NSString *shortMetric(NSString *input, BOOL memory){
 NSString *text=[input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
 if(!memory)return text;
 if([text hasSuffix:@"MB"])return [[text substringToIndex:text.length-2] stringByAppendingString:@"M"];
 if([text hasSuffix:@"GB"])return [[text substringToIndex:text.length-2] stringByAppendingString:@"G"];
 if([text hasSuffix:@"KB"])return [[text substringToIndex:text.length-2] stringByAppendingString:@"K"];
 return text;
}
// REAPER replaces the native status text with hover help for volume and
// envelopes; the metric filter keeps only a verified CPU percent.
static NSString *cpuFromMetricStatus(NSString *statusText){
 std::string cpu;
 if(!mx::cpuFromStatus(statusText.UTF8String?:"",cpu))return nil;
 return [NSString stringWithUTF8String:cpu.c_str()];
}
static NSString *formatProjectTime(void *(*getAPI)(const char*),const char *fn,double value,BOOL length){
 if(!getAPI)return @"00:00.000";
 char text[256]={0};
 if(length){
  auto format=(void(*)(double,char*,int,double,int))getAPI(fn);
  if(!format)return @"00:00.000";
  format(value,text,(int)sizeof(text),0.0,0);
 }else{
  auto format=(void(*)(double,char*,int,int))getAPI(fn);
  if(!format)return @"00:00.000";
  format(value,text,(int)sizeof(text),0);
 }
 NSString *formatted=text[0]?[NSString stringWithUTF8String:text]:@"00:00.000";
 // REAPER's time mode can produce 0:00.000; keep a two-digit leading field.
 if(formatted.length>=2 && [formatted characterAtIndex:1]==':' &&
    [formatted characterAtIndex:0]>='0' && [formatted characterAtIndex:0]<='9')
  return [@"0" stringByAppendingString:formatted];
 return formatted;
}
// Preserve complete values when the toolbar is narrow: scale glyphs along X
// instead of silently cutting digits from CPU/RAM/time measurements.
static void drawCompactLine(NSString *text,NSFont *font,NSRect rect){
 if(!text.length||rect.size.width<=1)return;
 NSDictionary *attrs=@{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.whiteColor};
 CGFloat natural=[text sizeWithAttributes:attrs].width;
 CGFloat sx=natural>0?std::min((CGFloat)1,(rect.size.width-2)/natural):1;
 CGContextRef context=NSGraphicsContext.currentContext.CGContext;
 CGContextSaveGState(context);
 CGContextTranslateCTM(context,rect.origin.x,rect.origin.y);
 CGContextScaleCTM(context,sx,1);
 [text drawAtPoint:NSZeroPoint withAttributes:attrs];
 CGContextRestoreGState(context);
}
// REAPER themes and SWELL releases need not preserve the status field tag.
// Prefer the actual live CPU/RAM source over an unrelated NSTextField.
static NSTextField *findInView(NSView *view,BOOL byContent){
 if(!view || [view isHiddenOrHasHiddenAncestor])return nil;
 if([view isKindOfClass:[NSTextField class]] && view.superview){
  NSTextField *field=(NSTextField*)view;
  NSString *text=field.stringValue?:@"";
  if(byContent){
   if([text rangeOfString:@"CPU:" options:NSCaseInsensitiveSearch].location!=NSNotFound &&
      [text rangeOfString:@"RAM:" options:NSCaseInsensitiveSearch].location!=NSNotFound)return field;
  }else if(field.tag==1259)return field;
 }
 for(NSView *child in view.subviews){NSTextField *field=findInView(child,byContent);if(field)return field;}
 return nil;
}
static NSTextField *findStatus(id main){
 if([main isKindOfClass:[NSWindow class]])main=[main contentView];
 if([main isKindOfClass:[NSView class]]){
  NSTextField *field=findInView(main,YES);if(field)return field;
 }
 // The host window is authoritative. Other windows are only for floating status.
 for(NSWindow *window in NSApp.orderedWindows){
  NSTextField *field=findInView(window.contentView,YES);if(field)return field;
 }
 for(NSWindow *window in NSApp.windows){
  NSTextField *field=findInView(window.contentView,YES);if(field)return field;
 }
 if([main isKindOfClass:[NSView class]]){NSTextField *field=findInView(main,NO);if(field)return field;}
 for(NSWindow *window in NSApp.orderedWindows){
  NSTextField *field=findInView(window.contentView,NO);if(field)return field;
 }
 return nil;
}
// Move only our selection BACKGROUND one point upward. Do not resize the
// selection rect or alter the glyph layout; the old v50 code did both.
static char selectionPixelKey;
static void shiftSelectionBackground(NSLayoutManager *manager,SEL selector,
      const NSRect *rects,NSUInteger count,NSRange range,NSColor *color){
 Class parent=class_getSuperclass(object_getClass(manager));
 IMP original=class_getMethodImplementation(parent,selector);
 if(!original)return;
 using Draw = void (*)(id, SEL, const NSRect *, NSUInteger, NSRange, NSColor *);
 NSColor *rgb=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
 BOOL ours=rgb&&std::abs(rgb.redComponent-136.0/255.0)<0.005 &&
         std::abs(rgb.greenComponent-136.0/255.0)<0.005 &&
         std::abs(rgb.blueComponent-136.0/255.0)<0.005;
 if(!ours||!rects||!count){((Draw)original)(manager,selector,rects,count,range,color);return;}
 std::vector<NSRect> shifted(rects,rects+count);
 NSNumber *pixel=objc_getAssociatedObject(manager,&selectionPixelKey);
 const CGFloat offset=pixel?pixel.doubleValue:1.0;
 for(NSRect &r:shifted)r.origin.y-=offset;
 ((Draw)original)(manager,selector,shifted.data(),count,range,color);
}
static void installSelectionBackgroundShift(NSTextView *editor){
 NSLayoutManager *lm=editor.layoutManager;if(!lm)return;
 Class base=object_getClass(lm);
 NSString *name=NSStringFromClass(base);
 if([name hasPrefix:@"MXSelectionBackgroundUp_"])return;
 SEL method=@selector(fillBackgroundRectArray:count:forCharacterRange:color:);
 Method original=class_getInstanceMethod(base,method);
 if(!original)return;
 NSString *subName=[@"MXSelectionBackgroundUp_" stringByAppendingString:name];
 Class derived=NSClassFromString(subName);
 if(!derived){
  derived=objc_allocateClassPair(base,subName.UTF8String,0);
  if(!derived)return;
  class_addMethod(derived,method,(IMP)shiftSelectionBackground,method_getTypeEncoding(original));
  objc_registerClassPair(derived);
 }
 object_setClass(lm,derived);
}
static void styleValueEditor(NSTextView *editor){
 if(!editor)return;
 installSelectionBackgroundShift(editor);
 CGFloat scale=editor.window?editor.window.backingScaleFactor:1.0;
 objc_setAssociatedObject(editor.layoutManager,&selectionPixelKey,
   @(1.0/std::max((CGFloat)1,scale)),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 editor.textColor=NSColor.whiteColor;
 editor.insertionPointColor=NSColor.whiteColor;
 NSColor *selection=[NSColor colorWithSRGBRed:136.0/255.0
                                         green:136.0/255.0
                                          blue:136.0/255.0 alpha:1];
 NSColor *selectedInk=[NSColor colorWithSRGBRed:34.0/255.0
                                               green:34.0/255.0
                                                blue:34.0/255.0 alpha:1];
 editor.selectedTextAttributes=@{NSBackgroundColorAttributeName:selection,
                                NSForegroundColorAttributeName:selectedInk};
}
// An attached, transparent AppKit window is above SWELL-drawn siblings.
// Inserting a subview into REAPER's contentView cannot guarantee this z-order.
// NSTextFieldCell can add an I-beam cursor independently of its containing
// NSTextField's resetCursorRects. Override the CELL as well as the editor.
@interface MXArrowTextCell : NSTextFieldCell
@end
@implementation MXArrowTextCell
-(void)resetCursorRect:(NSRect)cellFrame inView:(NSView*)controlView{
 if(!controlView)return;
 NSRect cursorRect=NSIntersectionRect(cellFrame,controlView.visibleRect);
 if(!NSIsEmptyRect(cursorRect))
  [controlView addCursorRect:cursorRect cursor:[NSCursor arrowCursor]];
}
@end
// AppKit's standard field editor uses an I-beam cursor. Supply a dedicated
// editor for our numeric control so the mouse cursor stays an arrow during
// editing, while native selection and keyboard input continue to work.
@interface MXArrowFieldEditor : NSTextView
@end
@implementation MXArrowFieldEditor
-(void)resetCursorRects{
 [self addCursorRect:self.visibleRect cursor:[NSCursor arrowCursor]];
}
-(void)cursorUpdate:(NSEvent*)event{[[NSCursor arrowCursor] set];}
-(void)mouseMoved:(NSEvent*)event{
 [super mouseMoved:event];
 [[NSCursor arrowCursor] set];
}
-(void)mouseEntered:(NSEvent*)event{
 [super mouseEntered:event];
 [[NSCursor arrowCursor] set];
}
-(void)mouseDragged:(NSEvent*)event{
 [super mouseDragged:event];
 [[NSCursor arrowCursor] set];
}
@end
@interface MXToolbarOverlayWindow:NSWindow
@property(strong) MXArrowFieldEditor *arrowEditor;
@end
@implementation MXToolbarOverlayWindow
-(BOOL)canBecomeKeyWindow{return YES;} // Needed for editable envelope readout.
-(BOOL)canBecomeMainWindow{return NO;}
-(NSText*)fieldEditor:(BOOL)createFlag forObject:(id)object{
 if([object isKindOfClass:[NSTextField class]]&&
    [object respondsToSelector:@selector(selectAllForEditing)]){
  if(!self.arrowEditor&&createFlag){
   self.arrowEditor=[[MXArrowFieldEditor alloc]initWithFrame:NSMakeRect(0,0,120,22)];
   self.arrowEditor.fieldEditor=YES;
   self.arrowEditor.richText=NO;
   self.arrowEditor.importsGraphics=NO;
  }
  return self.arrowEditor;
 }
 return [super fieldEditor:createFlag forObject:object];
}
@end
@class MXEnvelopeController;
// A real, transparent AppKit hit target spans the ENTIRE value area. A local
// event monitor alone is insufficient when SWELL dispatches mouse events
// through the native REAPER view rather than NSApplication's monitor path.
@interface MXValueClickZone:NSView
@property(weak) MXEnvelopeController *owner;
@end
@interface MXEnvelopeField:NSTextField
@property(weak) MXEnvelopeController *owner;
@property BOOL inlineEditing;
-(BOOL)selectAllForEditing;
@end
@interface MXEnvelopePanel:NSView
@property(strong) MXEnvelopeField *value;
@property(strong) MXValueClickZone *clickZone;
@property(strong) NSTextFieldCell *passiveValue;
@property(strong) NSTextFieldCell *loopValue;
@property(strong) NSTextFieldCell *prefixValue;
@property(strong) NSTextFieldCell *separator;
@property BOOL toolbarPlacement;
@property BOOL compactToolbar;
@property(copy) NSString *toolbarCpuLine;
@property(copy) NSString *toolbarTimeLine;
@property(copy) NSString *compactValue;
@property CGFloat toolbarTextScale;
-(NSRect)editHitFrame;
-(void)syncEditClickZone;
-(void)drawSeparator;
@end
@implementation MXEnvelopePanel
-(BOOL)isFlipped{return YES;}
-(BOOL)isOpaque{return NO;}
-(NSRect)editHitFrame{
 // The complete existing value slot is clickable, including the area below
 // and beside the glyphs. Do not expand the overlay or its visual bounds.
 auto hit=mx::readoutValueHitRect(self.bounds.size.width,
                                   self.bounds.size.height,NSMinX(self.value.frame));
 return NSMakeRect(hit.x,hit.y,hit.width,hit.height);
}
-(void)syncEditClickZone{
 if(!self.clickZone)return;
 NSRect frame=[self editHitFrame];
 if(!NSEqualRects(self.clickZone.frame,frame))self.clickZone.frame=frame;
}
-(void)drawRect:(NSRect)dirty{
 if(!self.toolbarPlacement)return;
 NSFont *font=self.value.font?:mainToolbarFont();
 // The prefix is custom-painted; the inactive value uses a dedicated cell.
 // The native editable NSTextField is hidden until editing begins.
 CGFloat sx=std::max((CGFloat)0.01,self.toolbarTextScale);
 CGFloat naturalWidth=ceil([self.prefixValue.stringValue sizeWithAttributes:
     @{NSFontAttributeName:font}].width)+4;
 CGContextRef context=NSGraphicsContext.currentContext.CGContext;
 CGContextSaveGState(context);
 CGContextTranslateCTM(context,4,0);
 CGContextScaleCTM(context,sx,1);
 // Put both text cells on the same baseline with a 2pt top inset.
 [self.prefixValue drawWithFrame:NSMakeRect(0,2,naturalWidth,
                          std::max((CGFloat)0,self.bounds.size.height-2))
                          inView:self];
 CGContextRestoreGState(context);
 // Draw the inactive value with a SEPARATE, non-selectable cell. The real
 // NSTextField is hidden outside editing, so its Cocoa field editor cannot
 // leave a gray selection behind after Escape or losing focus.
 if(!self.value.inlineEditing){
  self.passiveValue.font=self.value.font;
  self.passiveValue.stringValue=self.value.stringValue?:@"";
  [self.passiveValue drawWithFrame:self.value.frame inView:self];
 }
}
-(void)drawSeparator{
 NSFont *font=self.value.font?:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
 CTFontRef native=CTFontCreateWithName((__bridge CFStringRef)font.fontName,font.pointSize,nullptr);
 CGColorRef color=(self.value.textColor?:[NSColor textColor]).CGColor;
 NSDictionary *attributes=@{(__bridge NSString*)kCTFontAttributeName:(__bridge id)native,(__bridge NSString*)kCTForegroundColorAttributeName:(__bridge id)color};
 NSAttributedString *text=[[NSAttributedString alloc]initWithString:@"-" attributes:attributes];
 CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
 CGRect ink=CTLineGetBoundsWithOptions(line,kCTLineBoundsUseGlyphPathBounds);
 CGContextRef context=NSGraphicsContext.currentContext.CGContext;
 CGContextSaveGState(context);CGContextTranslateCTM(context,0,self.bounds.size.height);CGContextScaleCTM(context,1,-1);
 CGContextSetTextMatrix(context,CGAffineTransformIdentity);
 CGContextSetTextPosition(context,round(-ink.origin.x),round((self.bounds.size.height-ink.size.height)/2-ink.origin.y)-2*rowPixel(self));
 CTLineDraw(line,context);CGContextRestoreGState(context);CFRelease(line);CFRelease(native);
}
@end
@interface MXEnvelopeController:NSObject<NSTextFieldDelegate>{
 @public ep::Model model;ep::Point snapshot;bool editing,finishing,updating;
}
@property(strong) MXEnvelopePanel *panel;
@property(strong) MXToolbarOverlayWindow *overlay;
@property(weak) NSWindow *overlayHost;
@property(strong) id mouseMonitor;
@property(weak) NSTextField *status;
@property(weak) NSResponder *previous;
@property void *(*mainHwnd)(void);
@property void *(*getAPI)(const char*);
-(void)tick;
-(void)update;
-(void)hideToolbarOverlay;
-(BOOL)showToolbarOverlayInWindow:(NSWindow*)window screenRect:(NSRect)rect;
-(void)statusFrameChanged:(NSNotification*)note;
-(void)overlayResignedKey:(NSNotification*)notification;
-(void)applicationResignedActive:(NSNotification*)notification;
-(void)finish:(BOOL)commit;
-(BOOL)beginValueEditing;
@end
@implementation MXValueClickZone
-(BOOL)isOpaque{return NO;}
-(BOOL)acceptsFirstMouse:(NSEvent*)event{return YES;}
-(void)resetCursorRects{
 [self addCursorRect:self.bounds cursor:[NSCursor arrowCursor]];
}
-(void)mouseDown:(NSEvent*)event{
 MXEnvelopeController *owner=self.owner;
 if(owner&&owner.panel.toolbarPlacement&&!owner->editing&&owner.panel.value.editable){
  // The passive value is painted in MXEnvelopePanel, while the actual
  // NSTextField stays hidden. Clicks below or beside the text arrive here.
  if([owner.panel.value selectAllForEditing])return;
 }
 [super mouseDown:event];
}
@end
@implementation MXEnvelopeField
// Native NSTextField drawing in both states ensures the SAME baseline,
// selection geometry and glyph positioning before and during editing.
-(void)drawRect:(NSRect)dirty{[super drawRect:dirty];}
-(BOOL)acceptsFirstResponder{return self.editable&&self.enabled;}
-(BOOL)acceptsFirstMouse:(NSEvent*)event{return YES;}
-(void)resetCursorRects{
 [self addCursorRect:self.visibleRect cursor:[NSCursor arrowCursor]];
}
-(void)cursorUpdate:(NSEvent*)event{[[NSCursor arrowCursor] set];}
-(BOOL)selectAllForEditing{
 if(!self.editable||!self.enabled||!self.window)return NO;
 self.owner.previous=self.window.firstResponder;
 if(![self.owner beginValueEditing])return NO;
 [self.window makeKeyWindow];
 // selectText: installs the Cocoa field editor using the SAME cell that
 // paints the non-editing state. Manual selectWithFrame created a second,
 // incorrectly aligned editor and made it difficult to click.
 [self selectText:nil];
 NSTextView *editor=(NSTextView*)self.currentEditor;
 if(!editor){[self.owner finish:NO];return NO;}
 [editor setSelectedRange:NSMakeRange(0,editor.string.length)];
 styleValueEditor(editor);
 [self.window invalidateCursorRectsForView:self];
 [self.window invalidateCursorRectsForView:editor];
 [[NSCursor arrowCursor] set];
 return YES;
}
-(void)mouseDown:(NSEvent*)event{
 BOOL first=!self.owner->editing||self.currentEditor!=self.window.firstResponder;
 if(first){[self selectAllForEditing];return;}
 [super mouseDown:event];
}
@end
@implementation MXEnvelopeController
-(instancetype)init{
 if((self=[super init])){
  _panel=[[MXEnvelopePanel alloc]initWithFrame:NSMakeRect(0,0,260,20)];
  _panel.value=[[MXEnvelopeField alloc]initWithFrame:NSMakeRect(4,0,90,20)];
  _panel.value.cell=[[MXArrowTextCell alloc] initTextCell:@""];
  _panel.passiveValue=[[NSTextFieldCell alloc] initTextCell:@""];
  _panel.passiveValue.bordered=NO;_panel.passiveValue.drawsBackground=NO;
  _panel.passiveValue.textColor=NSColor.whiteColor;
  _panel.passiveValue.usesSingleLineMode=YES;
  _panel.passiveValue.wraps=NO;
  _panel.passiveValue.alignment=NSTextAlignmentLeft;
  _panel.loopValue=MXCreateCenteredReadoutCell(@"00:00.000");
  _panel.loopValue.bordered=NO;_panel.loopValue.drawsBackground=NO;_panel.loopValue.textColor=NSColor.whiteColor;
  _panel.loopValue.scrollable=YES;_panel.loopValue.wraps=NO;_panel.loopValue.usesSingleLineMode=YES;
  _panel.prefixValue=[[NSTextFieldCell alloc]initTextCell:@""];
  _panel.prefixValue.bordered=NO;_panel.prefixValue.drawsBackground=NO;
  _panel.prefixValue.textColor=NSColor.whiteColor;
  _panel.prefixValue.usesSingleLineMode=YES;_panel.prefixValue.wraps=NO;
  _panel.prefixValue.alignment=NSTextAlignmentLeft;
  _panel.separator=[_panel.loopValue copy];_panel.separator.stringValue=@"—";
  _panel.value.owner=self;_panel.value.delegate=self;_panel.value.bordered=NO;
  _panel.value.drawsBackground=NO;_panel.value.textColor=NSColor.whiteColor;
  _panel.value.focusRingType=NSFocusRingTypeNone;
  _panel.value.cell.scrollable=YES;_panel.value.cell.wraps=NO;
  _panel.value.usesSingleLineMode=YES;
  _panel.value.lineBreakMode=NSLineBreakByClipping;
  _panel.value.alignment=NSTextAlignmentLeft;
  _panel.toolTip=nil;_panel.value.toolTip=nil;
  _panel.toolbarCpuLine=@"00.0";
  [_panel addSubview:_panel.value];
  _panel.clickZone=[[MXValueClickZone alloc]initWithFrame:NSZeroRect];
  _panel.clickZone.owner=self;
  [_panel addSubview:_panel.clickZone];
  _panel.clickZone.hidden=YES;
  // Inactive rendering uses passiveValue above, not the editable text field.
  _panel.value.hidden=YES;
 }
 return self;
}
-(void)hideToolbarOverlay{
 self.panel.clickZone.hidden=YES;
 if(self.overlay){[self.overlay orderOut:nil];self.overlayHost=nil;}
}
-(BOOL)showToolbarOverlayInWindow:(NSWindow*)window screenRect:(NSRect)rect{
 if(!window||!window.visible)return NO;
 NSRect onScreen=rect;
 if(onScreen.size.width<16||onScreen.size.height<16)return NO;
 if(!self.overlay){
  self.overlay=[[MXToolbarOverlayWindow alloc] initWithContentRect:onScreen
    styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  self.overlay.opaque=NO;self.overlay.backgroundColor=NSColor.clearColor;
  self.overlay.hasShadow=NO;self.overlay.movable=NO;
  self.overlay.releasedWhenClosed=NO;
  self.overlay.collectionBehavior=NSWindowCollectionBehaviorTransient|NSWindowCollectionBehaviorIgnoresCycle;
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(overlayResignedKey:)
      name:NSWindowDidResignKeyNotification object:self.overlay];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(applicationResignedActive:)
      name:NSApplicationDidResignActiveNotification object:NSApp];
 }
 if(self.overlay.parentWindow!=window){
  if(editing)[self finish:NO];
  [self.overlay orderOut:nil];
  if(self.overlay.parentWindow)[self.overlay.parentWindow removeChildWindow:self.overlay];
  [window addChildWindow:self.overlay ordered:NSWindowAbove];
  self.overlayHost=window;
 }
 if(!NSEqualRects(self.overlay.frame,onScreen))
  [self.overlay setFrame:onScreen display:YES];
 if(!self.overlay.visible)[self.overlay orderFront:nil];
 if(self.panel.superview!=self.overlay.contentView){
  if(editing)[self finish:NO];
  [self.panel removeFromSuperview];
  [self.overlay.contentView addSubview:self.panel];
 }
 NSRect panelRect=NSMakeRect(0,0,rect.size.width,rect.size.height);
 if(!NSEqualRects(self.panel.frame,panelRect))self.panel.frame=panelRect;
 self.panel.hidden=NO;
 return YES;
}
-(void)statusFrameChanged:(NSNotification*)note{[self tick];}
-(void)overlayResignedKey:(NSNotification*)notification{
 if(editing)[self finish:NO]; // Never commit on focus loss.
}
-(void)applicationResignedActive:(NSNotification*)notification{
 if(editing)[self finish:NO];
}
-(void)tick{
 if(updating)return;updating=true;
 @try{[self update];}@finally{updating=false;}
}
-(void)update{
 if(!readoutRowEnabled){
  if(editing)[self finish:NO];
  BOOL wasVisible=toolbarReadoutActive;
  toolbarReadoutActive=NO;movedStatusSource=nil;
  [self hideToolbarOverlay];
  self.panel.toolbarPlacement=NO;
  if(wasVisible&&self.status)[self.status setNeedsDisplay:YES];
  return;
 }
 BOOL apiReady=model.api.load(self.getAPI);
 id root=self.mainHwnd?(__bridge id)self.mainHwnd():nil;
 // Keep the previously identified native field while REAPER temporarily
 // replaces its contents with a hover hint (volume, envelope point, etc.).
 NSTextField *status=self.status;
 if(!status||!status.superview||[status isHiddenOrHasHiddenAncestor])
  status=findStatus(root);
 if(!status||!status.superview){
  toolbarDiagnostic(@"no status source; search missed native status field");
  toolbarReadoutActive=NO;movedStatusSource=nil;[self hideToolbarOverlay];
  if(editing)[self finish:NO];[self.panel removeFromSuperview];self.status=nil;return;
 }
 if(self.status!=status){
  [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:self.status];
  self.status=status;status.postsFrameChangedNotifications=YES;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(statusFrameChanged:) name:NSViewFrameDidChangeNotification object:status];
 }
 NSView *parent=[status superview];
 whiteStatusText(status);lowerStatusRow(status);
 NSFont *font=mainToolbarFont();
 if(![self.panel.loopValue.font isEqual:font])self.panel.loopValue.font=font;
 if(![self.panel.prefixValue.font isEqual:font])self.panel.prefixValue.font=font;
 if(![self.panel.separator.font isEqual:font])self.panel.separator.font=font;
 // Never display hover text, tool descriptions or RAM in the first block.
 // A temporary mouseover must not change a previously valid CPU reading.
 NSString *cpuLine=cpuFromMetricStatus(visibleStatusText(status));
 if(cpuLine.length && ![self.panel.toolbarCpuLine isEqualToString:cpuLine]){
  self.panel.toolbarCpuLine=cpuLine;[self.panel setNeedsDisplay:YES];
 }
 if(!self.panel.toolbarCpuLine.length)self.panel.toolbarCpuLine=@"00.0";
 auto loop=(void(*)(void*,bool,bool,double*,double*,bool))self.getAPI("GetSet_LoopTimeRange2");
 auto cursor=(double(*)(void*))self.getAPI("GetCursorPositionEx");
 double loopStart=0,loopEnd=0;if(loop)loop(nullptr,false,true,&loopStart,&loopEnd,false);
 double length=(loopEnd>loopStart)?(loopEnd-loopStart):0.0;
 NSString *loopText=formatProjectTime(self.getAPI,"format_timestr_len",length,YES);
 double cursorPos=cursor?cursor(nullptr):0.0;
 NSString *cursorText=formatProjectTime(self.getAPI,"format_timestr_pos",cursorPos,NO);
 NSString *timeLine=[NSString stringWithFormat:@"%@ — %@",cursorText?:@"00:00.000",loopText?:@"00:00.000"];
 if(![self.panel.toolbarTimeLine isEqualToString:timeLine]){
  self.panel.toolbarTimeLine=timeLine;[status setNeedsDisplay:YES];[self.panel setNeedsDisplay:YES];
 }
 if(![self.panel.value.font isEqual:font])self.panel.value.font=font;
 if(![self.panel.value.textColor isEqual:NSColor.whiteColor])self.panel.value.textColor=NSColor.whiteColor;

 // Source status is never reparented. Render in a transparent child window
 // attached to the main window above the SWELL-painted controls.
 NSString *valueText=self.panel.value.stringValue.length?self.panel.value.stringValue:@"SELECT";
 NSRect toolbarFrame=NSZeroRect;
 NSWindow *mainWindow=nil;
 if([root isKindOfClass:[NSWindow class]])mainWindow=(NSWindow*)root;
 else if([root isKindOfClass:[NSView class]])mainWindow=[(NSView*)root window];
 if(!mainWindow)mainWindow=status.window;
 NSString *toolbarSource=@"none";
 BOOL placed=mainToolbarPlacement(self.mainHwnd?self.mainHwnd():nullptr,
                                mainWindow,&toolbarFrame,&toolbarSource);
 // Calculate exact overlay width from the visible string and a small padded
 // edit target. The previous full-width overlay covered unused toolbar space.
 NSString *lead=[NSString stringWithFormat:@"%@ / %@ / ",
     self.panel.toolbarCpuLine?:@"",self.panel.toolbarTimeLine?:@""];
 NSString *shownValue=self.panel.value.stringValue.length?self.panel.value.stringValue:@"SELECT";
 CGFloat leadWidth=ceil([lead sizeWithAttributes:@{NSFontAttributeName:font}].width)+4;
 CGFloat valueNatural=ceil([shownValue sizeWithAttributes:@{NSFontAttributeName:font}].width);
 mx::ReadoutLayout layout=mx::layoutReadout(toolbarFrame.size.width,leadWidth,valueNatural);
 if(placed){
  toolbarFrame.size.width=layout.overlayWidth;
  // Keep the active field editor's geometry stable while typing.
  if(editing && self.overlay.visible && self.overlay.frame.size.width>0)
   toolbarFrame.size.width=self.overlay.frame.size.width;
 }
 BOOL top=placed&&[self showToolbarOverlayInWindow:mainWindow screenRect:toolbarFrame];
 toolbarDiagnostic([NSString stringWithFormat:@"source=%@ toolbar=%@ target=%@ overlay=%@ frame=(%.0f %.0f %.0f %.0f)",
  status?@"yes":@"no",toolbarSource,placed?@"yes":@"no",top?@"yes":@"no",
  toolbarFrame.origin.x,toolbarFrame.origin.y,toolbarFrame.size.width,toolbarFrame.size.height]);
 NSString *compactValue=valueText;
 if(top){
  self.panel.toolbarPlacement=YES;self.panel.compactToolbar=NO;
  self.panel.compactValue=compactValue;
  // No tooltips on the custom readout or on the editable volume value.
  if(self.panel.toolTip)self.panel.toolTip=nil;
  if(self.panel.value.toolTip)self.panel.value.toolTip=nil;
  self.panel.hidden=NO;
  [CATransaction begin];[CATransaction setDisableActions:YES];
  NSRect localFrame=NSMakeRect(0,0,toolbarFrame.size.width,toolbarFrame.size.height);
  if(!NSEqualRects(self.panel.frame,localFrame))self.panel.frame=localFrame;
  // Freeze field placement while editing, even when CPU/cursor/loop updates.
  // Moving its frame during NSTextView editing made text jump and selection
  // inaccurate as time/prefix widths changed.
  if(!editing){
   self.panel.prefixValue.stringValue=lead;
   self.panel.toolbarTextScale=layout.prefixScale;
   NSRect valueFrame=NSMakeRect(layout.valueX,2,layout.valueWidth,
                              std::max((CGFloat)0,toolbarFrame.size.height-2));
   if(!NSEqualRects(self.panel.value.frame,valueFrame))self.panel.value.frame=valueFrame;
  }
  // Install a native hit target over the full value column, from its top
  // to the bottom of the toolbar. This is independent of glyph bounds.
  [self.panel syncEditClickZone];
  [CATransaction commit];
  BOOL wasMoved=toolbarReadoutActive && movedStatusSource==status;
  movedStatusSource=status;toolbarReadoutActive=YES;
  [self.panel setNeedsDisplay:YES];if(!wasMoved)[status setNeedsDisplay:YES];
 }else{
  // Never draw the custom readout in the old status row or in a guessed
  // screen position. If the native Main Toolbar is not identified, the
  // REAPER status source remains visible and the extension adds nothing.
  BOOL wasMoved=toolbarReadoutActive;
  toolbarReadoutActive=NO;movedStatusSource=nil;
  [self hideToolbarOverlay];
  self.panel.toolbarPlacement=NO;self.panel.compactToolbar=NO;
  self.panel.toolbarTimeLine=nil;self.panel.compactValue=nil; // preserve last CPU reading
  self.panel.toolTip=nil;
  if(editing)[self finish:NO];
  [self.panel removeFromSuperview];
  if(wasMoved)[status setNeedsDisplay:YES];
  return;
 }
 if(!apiReady){
  if(editing){[self finish:NO];return;}
  self.panel.value.editable=NO;self.panel.value.selectable=NO;self.panel.value.stringValue=@"SELECT";
  self.panel.clickZone.hidden=YES;
  return;
 }
 if(!editing){
  // Preserve the selected envelope segment for a click anywhere in the
  // value zone, not just inside the one-line native text field.
  BOOL inside=NO;
  if(self.panel.toolbarPlacement&&self.panel.window&&!self.panel.hidden){
   NSPoint p=[self.panel convertPoint:self.panel.window.mouseLocationOutsideOfEventStream fromView:nil];
   inside=NSPointInRect(p,[self.panel editHitFrame]);
  }
  model.pointer((NSEvent.pressedMouseButtons&1)!=0,inside);
 }
 ep::Point point=model.read();
 if(editing){
  if(!point.editable||point.project!=snapshot.project||point.env!=snapshot.env||point.ai!=snapshot.ai||point.index!=snapshot.index||point.time!=snapshot.time||point.segment!=snapshot.segment||point.raw!=snapshot.raw||point.points!=snapshot.points){[self finish:NO];}
  else return;
 }
 snapshot=point;
 if(self.panel.value.editable!=point.editable)self.panel.value.editable=point.editable;
 if(self.panel.value.selectable!=point.editable)self.panel.value.selectable=point.editable;
 self.panel.clickZone.hidden=!self.panel.toolbarPlacement||!point.editable;
 // Preserve the existing v59 envelope toolbar presentation.
 std::string presentation=point.selected>0 ? point.display : "SELECT";
 NSString *display=[NSString stringWithUTF8String:presentation.c_str()]?:@"SELECT";
 if(![self.panel.value.stringValue isEqualToString:display]){
  self.panel.value.stringValue=display;
  if(!self.panel.toolbarPlacement){
   NSRect valueFrame=self.panel.value.frame;
   valueFrame.size.width=std::min(self.panel.bounds.size.width,ceil([display sizeWithAttributes:@{NSFontAttributeName:font}].width)+4);
   self.panel.value.frame=valueFrame;
  }
  [status setNeedsDisplay:YES];[self.panel setNeedsDisplay:YES];
 }
 if(self.panel.toolbarPlacement&&!editing){
  if(![self.panel.compactValue isEqualToString:display]){
   self.panel.compactValue=display;[self.panel setNeedsDisplay:YES];
  }
  // Intentionally no hover tooltip (value remains click-to-edit).
 }
}
-(BOOL)beginValueEditing{
 if(!self.panel.value.editable||!model.api.load(self.getAPI))return NO;
 ep::Point fresh=model.read();if(!fresh.editable)return NO;
 snapshot=fresh;
 // The toolbar envelope editor retains its original v59 input behavior.
 self.panel.value.stringValue=[NSString stringWithUTF8String:fresh.display.c_str()]?:@"";
 self.panel.value.hidden=NO;
 self.panel.clickZone.hidden=YES; // Do not cover the Cocoa field editor.
 editing=true;self.panel.value.inlineEditing=YES;
 [self.panel setNeedsDisplay:YES];[self.status setNeedsDisplay:YES];return YES;
}
-(void)controlTextDidBeginEditing:(NSNotification*)note{
 styleValueEditor((NSTextView*)self.panel.value.currentEditor);
 if(finishing||editing)return;
 ep::Point fresh=model.read();
 if(!fresh.editable||fresh.project!=snapshot.project||fresh.env!=snapshot.env||fresh.ai!=snapshot.ai||fresh.index!=snapshot.index||fresh.time!=snapshot.time||fresh.raw!=snapshot.raw){[self finish:NO];return;}
 snapshot=fresh;editing=true;self.panel.value.inlineEditing=YES;
}
-(BOOL)control:(NSControl*)control textView:(NSTextView*)view doCommandBySelector:(SEL)command{
 if(command==@selector(insertNewline:)){[self finish:YES];return YES;}
 if(command==@selector(cancelOperation:)){[self finish:NO];return YES;}
 return NO;
}
-(void)controlTextDidEndEditing:(NSNotification*)note{if(!finishing&&editing)[self finish:NO];}
-(void)finish:(BOOL)commit{
 if(finishing)return;
 if(!editing){
  self.panel.value.inlineEditing=NO;
  self.panel.value.hidden=YES;
  self.panel.clickZone.hidden=!self.panel.toolbarPlacement||!self.panel.value.editable;
  return;
 }
 finishing=true;BOOL ok=YES;std::string error;
 if(commit&&editing){
  [self.panel.value validateEditing];
  ok=model.commit(snapshot,self.panel.value.stringValue.UTF8String?:"",error);
 }
 if(!ok){finishing=false;return;}
 std::string original=snapshot.selected>0 ?
      snapshot.display : "SELECT";
 NSString *restore=[NSString stringWithUTF8String:original.c_str()]?:@"SELECT";
 NSWindow *window=self.panel.window;
 NSTextView *editor=(NSTextView*)self.panel.value.currentEditor;
 editing=false;
 self.panel.value.inlineEditing=NO;
 // endEditingFor: is required to detach the system field editor. Merely
 // abortEditing + setSelectedRange(0,0) can leave its selection painted.
 if(editor){
  [editor setSelectedRange:NSMakeRange(0,0)];
  [editor setNeedsDisplay:YES];
 }
 [window endEditingFor:self.panel.value];
 if(!commit)self.panel.value.stringValue=restore;
 if(editor){
  [editor setSelectedRange:NSMakeRange(0,0)];
  if(window.firstResponder==editor)[window makeFirstResponder:nil];
 }
 // Never show the same NSTextField outside editing: AppKit caches the last
 // selection in its control/editor. A separate nonselectable cell draws the
 // normal readout at the identical frame and font.
 self.panel.value.cell.highlighted=NO;
 self.panel.value.hidden=YES;
 self.panel.clickZone.hidden=!self.panel.toolbarPlacement||!self.panel.value.editable;
 [self.panel.value setNeedsDisplay:YES];
 [self.status setNeedsDisplay:YES];
 [self.panel setNeedsDisplay:YES];
 if(commit&&self.previous&&window.isKeyWindow)
  [window makeFirstResponder:self.previous];
 self.previous=nil;
 self.panel.value.textColor=NSColor.whiteColor;
 finishing=false;
 [self tick];
}

@end
static MXEnvelopeController *controller;
// Passive text is painted in the native status draw pass. The transparent
// field remains as the hit target and hosts AppKit's editor only while typing.
static void prepareInlineStatus(NSView *view){
 if(controller.status==view)[controller tick];
}
static BOOL drawInlineStatus(NSView *view){
 MXEnvelopeController *owner=controller;
 if(!readoutRowEnabled||owner.status!=view||!owner.panel.superview||owner.panel.toolbarPlacement)return NO;
 NSRect valueRect=[view convertRect:owner.panel.value.bounds fromView:owner.panel.value];
 // All labels share the same single-line cell geometry and baseline.
 NSRect prefixRect=NSMakeRect(0,valueRect.origin.y,view.bounds.size.width,18);
 [owner.panel.prefixValue drawWithFrame:prefixRect inView:view];
 if(owner.panel.hidden)return YES;
 NSFont *font=owner.panel.value.font;
 CGFloat space=ceil([@" " sizeWithAttributes:@{NSFontAttributeName:font}].width);
 CGFloat dash=ceil([@"—" sizeWithAttributes:@{NSFontAttributeName:font}].width)+4;
 NSRect leftDash=NSMakeRect(valueRect.origin.x-space-dash,valueRect.origin.y,dash,18);
 [owner.panel.separator drawWithFrame:leftDash inView:view];
 if(!owner->editing)[owner.panel.value.cell drawWithFrame:valueRect inView:view];
 NSRect rightDash=NSMakeRect(NSMaxX(valueRect)+space,valueRect.origin.y,dash,18);
 [owner.panel.separator drawWithFrame:rightDash inView:view];
 NSRect loopRect=NSMakeRect(NSMaxX(rightDash)+space,valueRect.origin.y,0,18);
 loopRect.size.width=std::max((CGFloat)0,NSMaxX([view convertRect:owner.panel.bounds fromView:owner.panel])-loopRect.origin.x);
 [owner.panel.loopValue drawWithFrame:loopRect inView:view];
 return YES;
}

// Both REAPER command hooks can report the same invocation. Deduplicate
// only the duplicate pair, not distinct user commands.
static int previousReadoutCommand=0;
static CFAbsoluteTime previousReadoutCommandTime=0;
static void toggleReadoutRow(){
 readoutRowEnabled=!readoutRowEnabled;
 if(readoutSetExtState)readoutSetExtState(kReadoutSection,kReadoutVisibilityKey,
                                    readoutRowEnabled?"1":"0",true);
 if(controller)[controller tick];
 if(readoutRefreshToolbar&&readoutRowActionID>0)
  readoutRefreshToolbar(0,readoutRowActionID);
}
static void executeReadoutCommand(int command){
 const CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
 if(previousReadoutCommand==command && now>=previousReadoutCommandTime &&
    now-previousReadoutCommandTime<0.075)return;
 previousReadoutCommand=command;previousReadoutCommandTime=now;
 toggleReadoutRow();
}
static bool dispatchReadoutCommand(int command){
 if(command!=readoutRowActionID||command<=0)return false;
 if([NSThread isMainThread])executeReadoutCommand(command);
 else dispatch_async(dispatch_get_main_queue(),^{executeReadoutCommand(command);});
 return true;
}
static bool onReadoutCommand(int command,int flag){
 (void)flag;return dispatchReadoutCommand(command);
}
static bool onReadoutCommand2(void *section,int command,int val,int valhw,int relmode,void *hwnd){
 (void)section;(void)val;(void)valhw;(void)relmode;(void)hwnd;
 return dispatchReadoutCommand(command);
}
static int readoutToggleState(int command){
 return command==readoutRowActionID ? (readoutRowEnabled?1:0) : -1;
}
static void unregisterReadoutAction(const ep::Info &info){
 if(!info.reg)return;
 if(readoutRowToggleHook)info.reg("-toggleaction",(void*)readoutToggleState);
 if(readoutRowHook1)info.reg("-hookcommand",(void*)onReadoutCommand);
 if(readoutRowHook2)info.reg("-hookcommand2",(void*)onReadoutCommand2);
 if(readoutRowActionID>0)info.reg("-custom_action",&kReadoutRowToggle);
 readoutRowActionID=0;readoutRowHook1=readoutRowHook2=readoutRowToggleHook=false;
 readoutGetExtState=nullptr;readoutSetExtState=nullptr;readoutRefreshToolbar=nullptr;
 previousReadoutCommand=0;previousReadoutCommandTime=0;
}
static ep::Info host{};
static bool registered=false;
static void timer(){@autoreleasepool{[controller tick];}}
extern "C" __attribute__((visibility("default"))) int MixolveEnvelopeEntry(ep::Info *info){@autoreleasepool{
 if(!info){
  if(registered&&host.reg)host.reg("-timer",(void*)timer);
  registered=false;if(controller){if(controller.mouseMonitor)[NSEvent removeMonitor:controller.mouseMonitor];controller.mouseMonitor=nil;[NSNotificationCenter.defaultCenter removeObserver:controller];[controller finish:NO];controller.panel.value.delegate=nil;[controller.panel removeFromSuperview];[controller hideToolbarOverlay];[controller.overlay close];controller.overlay=nil;controller=nil;}
  toolbarReadoutActive=NO;movedStatusSource=nil;
  statusDrawHooks.uninstall();unregisterReadoutAction(host);host={};return 1;
 }
 if(registered)return 1;
 if(info->version!=0x20e||!info->get||!info->reg)return 0;
 host=*info;controller=[MXEnvelopeController new];controller.getAPI=info->get;
 controller.mainHwnd=(void*(*)(void))info->get("GetMainHwnd");
 registered=info->reg("timer",(void*)timer)!=0;
 if(!registered){controller=nil;host={};return 0;}
 readoutGetExtState=(decltype(readoutGetExtState))info->get("GetExtState");
 readoutSetExtState=(decltype(readoutSetExtState))info->get("SetExtState");
 readoutRefreshToolbar=(decltype(readoutRefreshToolbar))info->get("RefreshToolbar2");
 readoutRowEnabled=true;
 if(readoutGetExtState){
  const char *saved=readoutGetExtState(kReadoutSection,kReadoutVisibilityKey);
  if(saved&&saved[0]=='0'&&!saved[1])readoutRowEnabled=false;
 }
 readoutRowActionID=info->reg("custom_action",&kReadoutRowToggle);
 if(readoutRowActionID>0){
  readoutRowHook2=info->reg("hookcommand2",(void*)onReadoutCommand2)!=0;
  readoutRowHook1=info->reg("hookcommand",(void*)onReadoutCommand)!=0;
  readoutRowToggleHook=info->reg("toggleaction",(void*)readoutToggleState)!=0;
  if(!readoutRowHook1&&!readoutRowHook2){
   toolbarDiagnostic(@"toolbar readout row action: unable to register command hooks");
   unregisterReadoutAction(*info);
  }
 }else toolbarDiagnostic(@"toolbar readout row action: custom_action registration failed");
 __weak MXEnvelopeController *weak=controller;
 controller.mouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp handler:^NSEvent*(NSEvent *event){
  MXEnvelopeController *owner=weak;if(!owner)return event;
  // The native MXValueClickZone handles ordinary AppKit events across the
  // value column. This monitor is a fallback for SWELL's own event routing:
  // hit-test in screen coordinates regardless of the event's target window.
  BOOL insideSlot=NO;
  if(event.window&&owner.overlay.visible&&owner.panel.toolbarPlacement&&!owner.panel.hidden){
   NSPoint screenPoint=[event.window convertPointToScreen:event.locationInWindow];
   NSPoint overlayPoint=[owner.overlay convertPointFromScreen:screenPoint];
   NSPoint local=[owner.panel convertPoint:overlayPoint fromView:nil];
   insideSlot=NSPointInRect(local,[owner.panel editHitFrame]);
  }
  if(event.type==NSEventTypeLeftMouseDown){
   if(owner->editing){
    if(!insideSlot)[owner finish:NO]; // no commit; allow original REAPER click
   }else if(insideSlot){
    // This branch is independent of NSView hitTest: the same screen-space
    // rectangle receives clicks over and below the value glyphs.
    if(owner.panel.value.editable){
     BOOL started=[owner.panel.value selectAllForEditing];
     toolbarDiagnostic(started?@"edit: started from screen-space slot":
                                 @"edit: slot hit but editor failed to start");
     if(started)return nil;
    }else toolbarDiagnostic(@"edit: slot hit but no editable automation point");
   }
  }
  if(event.window==owner.overlay)return event;
  if(!owner->editing&&owner->model.api.load(owner.getAPI)){
   if(event.type==NSEventTypeLeftMouseUp)owner->model.pointer(false,false);
   else {owner->model.pointer(false,false);owner->model.pointer(true,false);}
  }
  return event;
 }];
 return 1;
}}
