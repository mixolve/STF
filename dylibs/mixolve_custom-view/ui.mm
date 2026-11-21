#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#include "model.hpp"
#include "objc-hooks.hpp"
#include <memory>
#include <algorithm>
#include <vector>

// Independent status rendering: no binary-specific offsets, global registries,
// or custom Objective-C runtime classes are required.
extern "C" NSTextFieldCell *MXCreateCenteredReadoutCell(NSString *text);
static mx::HookRegistry statusDrawHooks;
static CGFloat rowPixel(NSView *view){return 1.0/std::max((CGFloat)1,view.window.backingScaleFactor);}
static void prepareInlineStatus(NSView *view);
static BOOL drawInlineStatus(NSView *view);
static void loweredStatusDraw(NSView *view,SEL selector,NSRect dirty){
 IMP original = statusDrawHooks.original(view,selector);if(!original)return;
 prepareInlineStatus(view);
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
 text=[text stringByReplacingOccurrencesOfString:@"CPU: " withString:@""];
 text=[text stringByReplacingOccurrencesOfString:@"RAM: " withString:@""];
 return [text stringByReplacingOccurrencesOfString:@" - " withString:@" — "];
}
static NSFont *statusFont(NSTextField *status){
 return status.font?:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}
static NSTextField *findInView(NSView *view){
 if([view isKindOfClass:[NSTextField class]]&&view.tag==1259&&view.superview)return (NSTextField*)view;
 for(NSView *child in view.subviews){NSTextField *field=findInView(child);if(field)return field;}
 return nil;
}
static NSTextField *findStatus(id main){
 if([main isKindOfClass:[NSWindow class]])main=[main contentView];
 if([main isKindOfClass:[NSView class]]){NSTextField *field=findInView(main);if(field)return field;}
 for(NSWindow *window in NSApp.orderedWindows){NSTextField *field=findInView(window.contentView);if(field&&![field isHiddenOrHasHiddenAncestor])return field;}
 for(NSWindow *window in NSApp.windows){NSTextField *field=findInView(window.contentView);if(field&&![field isHiddenOrHasHiddenAncestor])return field;}
 return nil;
}
static char selectionFontKey;
static void compactSelection(NSLayoutManager *manager,SEL selector,const NSRect *rects,NSUInteger count,NSRange range,NSColor *color){
 Class base=class_getSuperclass(object_getClass(manager));
 IMP original=class_getMethodImplementation(base,selector);
 NSFont *font=objc_getAssociatedObject(manager,&selectionFontKey);
 NSColor *rgb=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
 if(font&&rgb&&fabs(rgb.redComponent-136.0/255.0)<0.005&&fabs(rgb.greenComponent-rgb.redComponent)<0.005&&fabs(rgb.blueComponent-rgb.redComponent)<0.005){
  std::vector<NSRect> compact(rects,rects+count);
  CGFloat inkHeight=ceil(font.capHeight);
  for(NSRect &rect:compact){CGFloat h=std::min(rect.size.height,inkHeight);rect.origin.y+=floor((rect.size.height-h)/2);rect.size.height=h;}
  ((void(*)(id,SEL,const NSRect*,NSUInteger,NSRange,NSColor*))original)(manager,selector,compact.data(),count,range,color);
 }else ((void(*)(id,SEL,const NSRect*,NSUInteger,NSRange,NSColor*))original)(manager,selector,rects,count,range,color);
}
static void compactEditorSelection(NSTextView *editor){
 NSLayoutManager *manager=editor.layoutManager;if(!manager)return;
 Class base=object_getClass(manager);
 NSString *name=NSStringFromClass(base);
 if(![name hasPrefix:@"MXCompactSelection_"]){
  NSString *subname=[@"MXCompactSelection_" stringByAppendingString:name];
  Class subclass=NSClassFromString(subname);
  if(!subclass){
   subclass=objc_allocateClassPair(base,subname.UTF8String,0);
   SEL selector=@selector(fillBackgroundRectArray:count:forCharacterRange:color:);
   class_addMethod(subclass,selector,(IMP)compactSelection,method_getTypeEncoding(class_getInstanceMethod(base,selector)));
   objc_registerClassPair(subclass);
  }
  SEL selector=@selector(fillBackgroundRectArray:count:forCharacterRange:color:);
  class_replaceMethod(subclass,selector,(IMP)compactSelection,method_getTypeEncoding(class_getInstanceMethod(base,selector)));
  object_setClass(manager,subclass);
 }
 objc_setAssociatedObject(manager,&selectionFontKey,editor.font,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void styleValueEditor(NSTextView *editor){
 if(!editor)return;
 compactEditorSelection(editor);
 editor.textColor=NSColor.whiteColor;editor.insertionPointColor=NSColor.whiteColor;
 NSColor *selection=[NSColor colorWithSRGBRed:136.0/255.0 green:136.0/255.0 blue:136.0/255.0 alpha:1];
 editor.selectedTextAttributes=@{NSBackgroundColorAttributeName:selection,NSForegroundColorAttributeName:NSColor.whiteColor};
}
@class MXEnvelopeController;
@interface MXEnvelopeField:NSTextField
@property(weak) MXEnvelopeController *owner;
@property BOOL inlineEditing;
-(BOOL)selectAllForEditing;
@end
@interface MXEnvelopePanel:NSView
@property(strong) MXEnvelopeField *value;
@property(strong) NSTextFieldCell *loopValue;
@property(strong) NSTextFieldCell *prefixValue;
@property(strong) NSTextFieldCell *separator;
-(void)drawSeparator;
@end
@implementation MXEnvelopePanel
-(BOOL)isFlipped{return YES;}
-(BOOL)isOpaque{return NO;}
-(void)drawRect:(NSRect)dirty{}
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
 @public ep::Model model;ep::Point snapshot;bool editing,finishing,updating,consumeValueMouseUp;
}
@property(strong) MXEnvelopePanel *panel;
@property(strong) id mouseMonitor;
@property(weak) NSTextField *status;
@property(weak) NSResponder *previous;
@property void *(*mainHwnd)(void);
@property void *(*getAPI)(const char*);
-(void)tick;
-(void)update;
-(void)statusFrameChanged:(NSNotification*)note;
-(void)finish:(BOOL)commit;
-(BOOL)beginValueEditing;
@end
@implementation MXEnvelopeField
-(void)drawRect:(NSRect)dirty{if(self.inlineEditing)[super drawRect:dirty];}
-(BOOL)acceptsFirstResponder{return self.editable&&self.enabled;}
-(BOOL)acceptsFirstMouse:(NSEvent*)event{return YES;}
-(BOOL)selectAllForEditing{
 if(!self.editable||!self.enabled||!self.window)return NO;
 self.owner.previous=self.window.firstResponder;
 if(![self.owner beginValueEditing])return NO;
 [NSApp activateIgnoringOtherApps:YES];[self.window makeKeyWindow];
 [self selectText:nil];
 NSTextView *editor=(NSTextView*)self.currentEditor;
 if(!editor){
  editor=(NSTextView*)[self.window fieldEditor:YES forObject:self];
  if(editor){editor.fieldEditor=YES;[self.cell selectWithFrame:self.bounds inView:self editor:editor delegate:self start:0 length:self.stringValue.length];}
 }
 if(!editor||![self.window makeFirstResponder:editor]){[self.owner finish:NO];return NO;}
 styleValueEditor(editor);
 [editor setSelectedRange:NSMakeRange(0,editor.string.length)];[editor scrollRangeToVisible:editor.selectedRange];[editor setNeedsDisplay:YES];
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
  _panel=[[MXEnvelopePanel alloc]initWithFrame:NSMakeRect(0,0,210,20)];
  _panel.value=[[MXEnvelopeField alloc]initWithFrame:NSMakeRect(41,1,162,18)];
  _panel.value.cell=MXCreateCenteredReadoutCell(@"");
  _panel.loopValue=MXCreateCenteredReadoutCell(@"00:00.000");
  _panel.loopValue.bordered=NO;_panel.loopValue.drawsBackground=NO;_panel.loopValue.textColor=NSColor.whiteColor;
  _panel.loopValue.scrollable=YES;_panel.loopValue.wraps=NO;_panel.loopValue.usesSingleLineMode=YES;
  _panel.prefixValue=[_panel.loopValue copy];_panel.separator=[_panel.loopValue copy];_panel.separator.stringValue=@"—";
  _panel.value.owner=self;_panel.value.delegate=self;_panel.value.bordered=NO;
  _panel.value.drawsBackground=NO;_panel.value.textColor=NSColor.whiteColor;
  _panel.value.focusRingType=NSFocusRingTypeNone;
  _panel.value.cell.scrollable=YES;_panel.value.cell.wraps=NO;
  _panel.value.usesSingleLineMode=YES;
  [_panel addSubview:_panel.value];
 }
 return self;
}
-(void)statusFrameChanged:(NSNotification*)note{[self tick];}
-(void)tick{
 if(updating)return;updating=true;
 @try{[self update];}@finally{updating=false;}
}
-(void)update{
 BOOL apiReady=model.api.load(self.getAPI);
 id root=self.mainHwnd?(__bridge id)self.mainHwnd():nil;
 NSTextField *status=findStatus(root);
 if(!status||!status.superview){
  if(editing)[self finish:NO];[self.panel removeFromSuperview];self.status=nil;return;
 }
 if(self.status!=status){
  [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:self.status];
  self.status=status;status.postsFrameChangedNotifications=YES;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(statusFrameChanged:) name:NSViewFrameDidChangeNotification object:status];
 }
 NSView *parent=[status superview];
 whiteStatusText(status);lowerStatusRow(status);
 NSFont *font=statusFont(status);
 if(![self.panel.loopValue.font isEqual:font])self.panel.loopValue.font=font;
 if(![self.panel.prefixValue.font isEqual:font])self.panel.prefixValue.font=font;
 if(![self.panel.separator.font isEqual:font])self.panel.separator.font=font;
 NSString *prefix=visibleStatusText(status);
 if(![self.panel.prefixValue.stringValue isEqualToString:prefix]){self.panel.prefixValue.stringValue=prefix;[status setNeedsDisplay:YES];}
 // Read the actual loop bounds, independently of the time selection link option.
 auto loop=(void(*)(void*,bool,bool,double*,double*,bool))self.getAPI("GetSet_LoopTimeRange2");
 double loopStart=0,loopEnd=0;if(loop)loop(nullptr,false,true,&loopStart,&loopEnd,false);
 double length=std::max(0.0,loopEnd-loopStart);
 unsigned long long ms=std::isfinite(length)?(unsigned long long)llround(std::min(length,1.0e12)*1000.0):0;
 NSString *loopText=[NSString stringWithFormat:@"%02llu:%02llu.%03llu",ms/60000,(ms/1000)%60,ms%1000];
 if(![self.panel.loopValue.stringValue isEqualToString:loopText]){self.panel.loopValue.stringValue=loopText;[status setNeedsDisplay:YES];}

 // Use the same typeface and height as the existing CPU/RAM line.
 if(![self.panel.value.font isEqual:font])self.panel.value.font=font;
 if(![self.panel.value.textColor isEqual:NSColor.whiteColor])self.panel.value.textColor=NSColor.whiteColor;
 NSRect frame=[status frame];CGFloat height=std::max((CGFloat)18,std::min((CGFloat)24,frame.size.height));
 CGFloat width=320,padding=ceil([@" — " sizeWithAttributes:@{NSFontAttributeName:font}].width);
 CGFloat textWidth=ceil([visibleStatusText(status)sizeWithAttributes:@{NSFontAttributeName:font}].width)+padding;
 CGFloat x=NSMinX(frame)+textWidth;
 // A full-width native status control often has trailing blank space. Place
 // the editor there; otherwise use the blank area immediately to its right.
 CGFloat inside=NSMaxX(frame)-x-2;
 if(inside>=80)width=std::min(width,inside);
 else if(x+width>NSMaxX(frame))x=NSMaxX(frame)+8;
 NSRect proposed=NSMakeRect(x,NSMidY(frame)-height/2,width,height);
 auto fit=[&](NSRect &rect)->BOOL{
  if(NSMinX(rect)<NSMinX(parent.bounds)||NSMaxX(rect)>NSMaxX(parent.bounds))return NO;
  // custom-view's 22px text frame extends 4px into the native TCP canvas.
  // Keep the new control inside the actual free strip, not over that canvas.
  for(NSView *other in parent.subviews){
   if(other==status||other==self.panel||other.hidden)continue;
   NSRect hit=NSIntersectionRect(rect,other.frame);
   if(NSIsEmptyRect(hit)||other.frame.size.height<height*3||hit.size.height>5)continue;
   if(NSMinY(other.frame)<=NSMinY(rect)&&NSMaxY(other.frame)<NSMaxY(rect)){
    CGFloat end=NSMaxY(rect);rect.origin.y=NSMaxY(other.frame);rect.size.height=end-rect.origin.y;
   }else if(NSMaxY(other.frame)>=NSMaxY(rect)&&NSMinY(other.frame)>NSMinY(rect))rect.size.height=NSMinY(other.frame)-rect.origin.y;
  }
  if(rect.size.height<16)return NO;
  BOOL available=YES;
  for(NSView *other in parent.subviews){
   if(other==status||other==self.panel||other.hidden)continue;
   if(NSIntersectsRect(rect,other.frame)){
    available=NO;
   }
  }
  return available;
 };
 BOOL fits=fit(proposed);
 if(!fits){proposed=NSMakeRect(NSMinX(frame)-width-8,NSMidY(frame)-height/2,width,height);fits=fit(proposed);}
 // Frame notifications arrive while REAPER is still resizing sibling views.
 // Keep the last valid layout during that intermediate state instead of flashing hidden.
 if(!fits&&self.panel.superview==parent&&!self.panel.hidden){
  proposed=self.panel.frame;fits=YES;
 }
 height=proposed.size.height;width=proposed.size.width;
 BOOL hidden=!fits||[status isHiddenOrHasHiddenAncestor];
 if(self.panel.hidden!=hidden)self.panel.hidden=hidden;
 if(self.panel.hidden&&editing){[self finish:NO];return;}
 if(self.panel.superview!=parent){[self.panel removeFromSuperview];[parent addSubview:self.panel positioned:NSWindowAbove relativeTo:status];}
 [CATransaction begin];[CATransaction setDisableActions:YES];
 if(!NSEqualRects(self.panel.frame,proposed))self.panel.frame=proposed;
 NSString *valueText=self.panel.value.stringValue.length?self.panel.value.stringValue:@"NOPE";
 CGFloat valueWidth=ceil([valueText sizeWithAttributes:@{NSFontAttributeName:font}].width)+4;
 NSRect valueFrame=NSMakeRect(0,(height-18)/2+2*rowPixel(status),std::min(width,valueWidth),18);
 if(!NSEqualRects(self.panel.value.frame,valueFrame))self.panel.value.frame=valueFrame;
 [CATransaction commit];
 if(!apiReady){
  if(editing){[self finish:NO];return;}
  self.panel.value.editable=NO;self.panel.value.selectable=NO;self.panel.value.stringValue=@"NOPE";
  return;
 }
 if(!editing){
  BOOL inside=NO;if(self.panel.window&&!self.panel.hidden){NSPoint p=[self.panel.value convertPoint:self.panel.window.mouseLocationOutsideOfEventStream fromView:nil];inside=NSPointInRect(p,self.panel.value.bounds);}
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
 NSString *display=point.selected>0?([NSString stringWithUTF8String:point.display.c_str()]?:@"NOPE"):@"NOPE";
 if(![self.panel.value.stringValue isEqualToString:display]){
  self.panel.value.stringValue=display;
  NSRect valueFrame=self.panel.value.frame;valueFrame.size.width=std::min(width,ceil([display sizeWithAttributes:@{NSFontAttributeName:font}].width)+4);
  self.panel.value.frame=valueFrame;[status setNeedsDisplay:YES];
 }

}
-(BOOL)beginValueEditing{
 if(!self.panel.value.editable||!model.api.load(self.getAPI))return NO;
 ep::Point fresh=model.read();if(!fresh.editable)return NO;
 snapshot=fresh;self.panel.value.stringValue=[NSString stringWithUTF8String:fresh.display.c_str()]?:@"";
 editing=true;self.panel.value.inlineEditing=YES;[self.status setNeedsDisplay:YES];return YES;
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
 if(finishing)return;finishing=true;BOOL ok=YES;std::string error;
 if(commit&&editing){[self.panel.value validateEditing];ok=model.commit(snapshot,self.panel.value.stringValue.UTF8String?:"",error);}
 if(!ok){
  finishing=false;return;
 }
 editing=false;self.panel.value.inlineEditing=NO;[self.status setNeedsDisplay:YES];
 NSWindow *window=self.panel.window;
 NSTextView *editor=(NSTextView*)self.panel.value.currentEditor;
 NSLayoutManager *manager=editor.layoutManager;
 objc_setAssociatedObject(manager,&selectionFontKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 if(manager&&[NSStringFromClass(object_getClass(manager)) hasPrefix:@"MXCompactSelection_"])object_setClass(manager,class_getSuperclass(object_getClass(manager)));
 [window endEditingFor:self.panel.value];
 [window makeFirstResponder:self.previous?:nil];self.previous=nil;
 self.panel.value.textColor=NSColor.whiteColor;
 finishing=false;[self tick];
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
 if(owner.status!=view||!owner.panel.superview)return NO;
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

static ep::Info host{};
static bool registered=false;
static void timer(){@autoreleasepool{[controller tick];}}
extern "C" __attribute__((visibility("default"))) int MixolveEnvelopeEntry(ep::Info *info){@autoreleasepool{
 if(!info){
  if(registered&&host.reg)host.reg("-timer",(void*)timer);
  registered=false;if(controller){if(controller.mouseMonitor)[NSEvent removeMonitor:controller.mouseMonitor];controller.mouseMonitor=nil;[NSNotificationCenter.defaultCenter removeObserver:controller];[controller finish:NO];controller.panel.value.delegate=nil;[controller.panel removeFromSuperview];controller=nil;}
  statusDrawHooks.uninstall();host={};return 1;
 }
 if(registered)return 1;
 if(info->version!=0x20e||!info->get||!info->reg)return 0;
 host=*info;controller=[MXEnvelopeController new];controller.getAPI=info->get;
 controller.mainHwnd=(void*(*)(void))info->get("GetMainHwnd");
 registered=info->reg("timer",(void*)timer)!=0;
 if(!registered){controller=nil;host={};return 0;}
 __weak MXEnvelopeController *weak=controller;
 controller.mouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp handler:^NSEvent*(NSEvent *event){
  MXEnvelopeController *owner=weak;if(!owner)return event;
  if(event.type==NSEventTypeLeftMouseUp&&owner->consumeValueMouseUp){owner->consumeValueMouseUp=false;owner->model.pointer(false,false);return nil;}
  BOOL inside=NO;
  if(owner.panel.window==event.window&&!owner.panel.hidden){NSPoint p=[owner.panel.value convertPoint:event.locationInWindow fromView:nil];inside=NSPointInRect(p,owner.panel.value.bounds);}
  if(event.type==NSEventTypeLeftMouseDown&&inside&&owner.panel.value.editable&&(!owner->editing||owner.panel.value.currentEditor!=event.window.firstResponder)){
   owner->model.pointer(false,false);owner->model.pointer(true,true);
   if([owner.panel.value selectAllForEditing]){owner->consumeValueMouseUp=true;return nil;}
  }
  if(!owner->editing&&owner->model.api.load(owner.getAPI)){
   if(event.type==NSEventTypeLeftMouseUp)owner->model.pointer(false,false);
   else {owner->model.pointer(false,false);owner->model.pointer(true,inside);}
  }
  return event;
 }];
 return 1;
}}
