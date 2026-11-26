#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#include "model.hpp"
#include "objc-hooks.hpp"
#include "track-volume.hpp"
#include "track-volume-layout.hpp"
#include <vector>
#include <string>
#include <string_view>
#include <utility>
#include <cstdio>
#include <cmath>
#include <algorithm>

extern "C" void MixolveSetTCPNameMouseFilter(bool (*)(NSEvent*));
namespace {
ep::Info host{};
void *(*project)(int,char*,int);
void *(*mainHwnd)();
int (*countTracks)(void*);
void *(*getTrackFromPoint)(int,int,int*)=nullptr;
void *(*getTrack)(void*,int);
bool (*trackString)(void*,const char*,char*,bool);
bool (*valid)(void*,void*,const char*);
int (*countEnvelopes)(void*);
void *(*getEnvelope)(void*,int);
double (*envelopeValue)(void*,const char*);
void (*undoBegin)(void*);
void (*undoEnd)(void*,const char*,int);
void (*dirty)(void*);
void (*adjust)(bool);
void (*arrange)();
void *owner,*track;
std::string initial;
NSString *previousText;
__weak NSWindow *window;
__weak NSView *parent;
NSTextField *field;
NSObject<NSTextFieldDelegate> *delegate;
bool finishing,swallowRelease;
// Track volume readout is a separate TCP field; it never uses the envelope editor.
double (*trackNumber)(void*,const char*)=nullptr;
void *(*volumeConfigVar)(const char*,int*)=nullptr;
bool (*setTrackNumber)(void*,const char*,double)=nullptr;
// Draw within REAPER's native window, in a topmost child NSView. A separate
// NSWindow/NSPanel is composed independently and can flicker against SWELL's
// TCP drawing. The readout never creates a new window of its own.
struct MXVolumeItem {
 void *track=nullptr;
 NSView *canvas=nil;
 std::string text;
 unsigned missed=0;
};
std::vector<MXVolumeItem> volumeItems;
void *volumeItemsProject=nullptr;
int (*swellClassName)(void*,char*,int)=nullptr;
mx::HookRegistry tcpPaintHooks;
__weak NSView *nativeVolumeTCP;
__weak NSWindow *tcpTrackingWindow;
bool refreshingVolumeReadouts=false;
__weak NSWindow *volumeWindow;
__weak NSView *volumeParent;
NSTextField *volumeField;
NSObject<NSTextFieldDelegate> *volumeDelegate;
void *volumeTrack=nullptr,*volumeProject=nullptr;
double initialVolume=1.0;
std::string initialVolumeText;
bool volumeFinishing=false;
unsigned volumeEditorInvisibleTicks=0;
NSRect volumeEditorScreenRect=NSZeroRect;
// Own the full gesture so the native fader cannot change gain on mouse-down.
struct MXVolumePress {
 void *track=nullptr,*project=nullptr;
 NSRect label=NSZeroRect;
 NSInteger windowNumber=0;
 bool dragged=false;
};
MXVolumePress volumePress;
struct MXVolumeCaretClick {
 NSPoint point=NSZeroPoint;
 NSTimeInterval repeatUntil=0;
 NSRange selectionBeforeClick=NSMakeRange(0,0);
};
MXVolumeCaretClick volumeCaretClick;
NSUInteger volumeSelectionAnchor=NSNotFound;


int swallowedKey=-1;
NSRect labelRect(void *t,const char *key){
 char text[1024]{};int x,y,w,h;
 if(!trackString(t,key,text,false)||std::sscanf(text,"%d %d %d %d",&x,&y,&w,&h)!=4||w<=0||h<=0)return NSZeroRect;
 // REAPER's macOS screen rect stores the top edge in native bottom-up coordinates.
 return NSMakeRect(x,y-h,w,h);
}
bool contains(NSRect rect,NSPoint point){return rect.size.width>0&&NSPointInRect(point,rect);}
struct VolumeScrollUndo {
 void *project=nullptr;
 void *anchor=nullptr;
 double deadline=0.0;
 bool multipleTracks=false;
};
VolumeScrollUndo volumeScrollUndo;
constexpr double volumeScrollUndoInterval=1.0;

void finishVolumeScrollUndo(){
 if(!volumeScrollUndo.project)return;
 const auto pending=volumeScrollUndo;
 volumeScrollUndo={};
 // A project tab can disappear before the next extension timer tick.
 for(int i=0;void *openProject=project(i,nullptr,0);++i){
  if(openProject!=pending.project)continue;
  undoEnd(openProject,pending.multipleTracks?"Adjust selected track volumes":"Set track volume",1);
  break;
 }
}

bool beforeVolumeScrollCommand(void *,int,int,int,int,void *){
 finishVolumeScrollUndo();
 return false;
}

void finish(bool commit){
 if(!field||finishing)return;
 finishing=true;
 NSTextField *closing=field;NSWindow *w=window;
 NSString *name=[closing.currentEditor isKindOfClass:NSTextView.class]?[(NSTextView*)closing.currentEditor string]:closing.stringValue;
 if(commit&&project(-1,nullptr,0)==owner&&valid(owner,track,"MediaTrack*")){
  char old[65536]{};trackString(track,"P_NAME",old,false);
  // A different rename while editing must not be overwritten by stale input.
  if(initial==old&&name&&initial!=name.UTF8String){
   finishVolumeScrollUndo();
   undoBegin(owner);trackString(track,"P_NAME",const_cast<char*>(name.UTF8String),true);
   undoEnd(owner,"Rename track",1);dirty(owner);adjust(false);arrange();
  }
 }
 [w endEditingFor:closing];[closing removeFromSuperview];
 field=nil;track=nullptr;owner=nullptr;parent=nil;window=nil;initial.clear();previousText=nil;
 finishing=false;
}
bool place(){
 if(!field||!parent||!window||project(-1,nullptr,0)!=owner||!valid(owner,track,"MediaTrack*"))return false;
 NSRect rect=labelRect(track,"P_UI_RECT:tcp.label");if(rect.size.width<=2||rect.size.height<=2)return false;
 rect=NSInsetRect(rect,1,1);
 NSRect local=[parent convertRect:[window convertRectFromScreen:rect] fromView:nil];
 if(!NSIntersectsRect(local,parent.visibleRect))return false;
 if(!NSEqualRects(field.frame,local))field.frame=local;return true;
}
void selectionStyle(){
 NSTextView *text=(NSTextView*)field.currentEditor;
 if(![text isKindOfClass:NSTextView.class])return;
 text.textColor=NSColor.whiteColor;text.insertionPointColor=NSColor.whiteColor;
 text.selectedTextAttributes=@{NSBackgroundColorAttributeName:[NSColor colorWithCalibratedWhite:119.0/255 alpha:1],NSForegroundColorAttributeName:NSColor.whiteColor};
 text.automaticQuoteSubstitutionEnabled=NO;text.automaticDashSubstitutionEnabled=NO;text.automaticTextReplacementEnabled=NO;text.automaticSpellingCorrectionEnabled=NO;
}
void uppercase(){
 NSTextView *text=(NSTextView*)field.currentEditor;
 if(![text isKindOfClass:NSTextView.class]||text.hasMarkedText)return;
 NSString *old=text.string,*before=previousText?:@"";
 NSUInteger prefix=0,suffix=0;
 while(prefix<old.length&&prefix<before.length&&[old characterAtIndex:prefix]==[before characterAtIndex:prefix])prefix++;
 while(suffix<old.length-prefix&&suffix<before.length-prefix&&[old characterAtIndex:old.length-1-suffix]==[before characterAtIndex:before.length-1-suffix])suffix++;
 NSRange inserted=NSMakeRange(prefix,old.length-prefix-suffix);
 NSString *part=[old substringWithRange:inserted],*upper=part.uppercaseString;
 if([part isEqualToString:upper]){previousText=[old copy];return;}
 NSRange range=text.selectedRange;
 auto remap=[&](NSUInteger pos)->NSUInteger{
  pos=MIN(pos,old.length);
  if(pos<=prefix)return pos;
  if(pos>=NSMaxRange(inserted))return pos-inserted.length+upper.length;
  return prefix+[part substringToIndex:pos-prefix].uppercaseString.length;
 };
 NSUInteger start=remap(range.location),end=remap(NSMaxRange(range));
 text.string=[old stringByReplacingCharactersInRange:inserted withString:upper];
 text.selectedRange=NSMakeRange(start,end-start);previousText=[text.string copy];
}
}
@interface MXTCPNameCell : NSTextFieldCell
@end
@implementation MXTCPNameCell
-(NSRect)drawingRectForBounds:(NSRect)rect{
 rect=[super drawingRectForBounds:rect];CGFloat height=self.font.ascender-self.font.descender+2;
 if(rect.size.height>height){rect.origin.y+=floor((rect.size.height-height)/2);rect.size.height=height;}return rect;
}
@end
@interface MXTCPNameDelegate : NSObject<NSTextFieldDelegate>
@end
@implementation MXTCPNameDelegate
-(void)controlTextDidBeginEditing:(NSNotification*)notification{selectionStyle();}
-(void)controlTextDidChange:(NSNotification*)notification{uppercase();}
-(void)controlTextDidEndEditing:(NSNotification*)notification{if(!finishing)finish(true);}
-(BOOL)control:(NSControl*)control textView:(NSTextView*)text doCommandBySelector:(SEL)selector{
 if(selector==@selector(cancelOperation:)){finish(false);return YES;}
 if(selector==@selector(insertNewline:)||selector==@selector(insertTab:)||selector==@selector(insertBacktab:)){finish(true);return YES;}
 return NO;
}
@end
// One appearance for the painted value and the live Cocoa field editor.
// The selection's FOREGROUND is #222222; its highlight must differ from the
// #222222 control background or the selected digits would disappear.
static NSColor *volumeBackground(){
 return [NSColor colorWithSRGBRed:34.0/255.0 green:34.0/255.0 blue:34.0/255.0 alpha:1];
}
static NSColor *volumeSelectionBackground(){
 return [NSColor colorWithSRGBRed:184.0/255.0 green:184.0/255.0 blue:184.0/255.0 alpha:1];
}
// Use the regular Charon face in both readout modes.
static NSFont *trackVolumeFont(CGFloat width){
 constexpr CGFloat pointSize=16.0;
 NSFont *base=[NSFont fontWithName:@"IosevkaCharonMono-Regular" size:pointSize]
     ?: [NSFont monospacedSystemFontOfSize:pointSize weight:NSFontWeightRegular];
 if(width<=0)return base;
 CGFloat needed=MAX([@"+00.00" sizeWithAttributes:@{NSFontAttributeName:base}].width,
                    [@"MUTED" sizeWithAttributes:@{NSFontAttributeName:base}].width);
 if(needed<=MAX(1.0,width-4.0))return base;
 CGFloat smaller=mx::trackVolumeFontSize(width,needed,pointSize);
 return [NSFont fontWithDescriptor:base.fontDescriptor size:smaller]?:base;
}
// AppKit lays out both views from the top. Share the cap-height baseline
// and TextKit glyph metrics across the editable and passive readout.
static CGFloat volumeTextInset(NSLayoutManager *layout,NSTextContainer *container,
                               NSFont *font,CGFloat height,CGFloat scale){
 [layout ensureLayoutForTextContainer:container];
 CGFloat lineBaseline=layout.numberOfGlyphs?
     [layout locationForGlyphAtIndex:0].y:[layout defaultBaselineOffsetForFont:font];
 CGFloat baseline=height-mx::trackVolumeBaseline(height,font.capHeight,scale);
 return MAX(0.0,baseline-lineBaseline)+0.5/scale;
}
static void alignVolumeEditor(NSTextView *editor,CGFloat height){
 editor.alignment=NSTextAlignmentCenter;
 editor.textContainer.lineFragmentPadding=0;
 NSFont *font=editor.font;
 if(!font||height<=0)return;
 CGFloat scale=MAX(1.0,editor.window.backingScaleFactor);
 CGFloat inset=volumeTextInset(editor.layoutManager,editor.textContainer,font,height,scale);
 editor.textContainerInset=NSMakeSize(0,inset);
}
static void styleVolumeEditor(NSTextView *editor){
 if(![editor isKindOfClass:NSTextView.class])return;
 editor.drawsBackground=YES;
 editor.backgroundColor=volumeBackground();
 editor.textColor=NSColor.whiteColor;
 editor.insertionPointColor=NSColor.whiteColor;
 editor.selectedTextAttributes=@{
  NSBackgroundColorAttributeName:volumeSelectionBackground(),
  NSForegroundColorAttributeName:volumeBackground()
 };
 editor.automaticQuoteSubstitutionEnabled=NO;
 editor.automaticDashSubstitutionEnabled=NO;
 editor.automaticTextReplacementEnabled=NO;
 editor.automaticSpellingCorrectionEnabled=NO;
}
static NSRect volumeEditorTextBand(NSTextView *editor,NSUInteger glyph){
 NSLayoutManager *layout=editor.layoutManager;
 NSFont *font=editor.font;
 CGFloat baseline=layout.numberOfGlyphs?
     NSMinY([layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr])+
     [layout locationForGlyphAtIndex:glyph].y:
     [layout defaultBaselineOffsetForFont:font];
 CGFloat scale=MAX(1.0,editor.window.backingScaleFactor);
 CGFloat height=ceil(font.capHeight*scale)/scale;
 return NSMakeRect(0,editor.textContainerOrigin.y+baseline-height,0,height);
}
@interface MXTCPVolumeLayoutManager : NSLayoutManager
@property(nonatomic) CGFloat readoutScale;
@end
@implementation MXTCPVolumeLayoutManager
-(void)drawGlyphsForGlyphRange:(NSRange)glyphs atPoint:(NSPoint)origin{
 CGFloat scale=MAX(1.0,self.firstTextView.window.backingScaleFactor?:self.readoutScale);
 CGFloat lower=floor(origin.y*scale);
 CGFloat fraction=origin.y*scale-lower;
 CGContextRef context=NSGraphicsContext.currentContext.CGContext;
 if(!context||fraction<0.001){
  [super drawGlyphsForGlyphRange:glyphs atPoint:origin];
  return;
 }
 // TextKit snaps glyph baselines to device pixels. Blend adjacent rows
 // so the same half-pixel position is visible on the readout and editor.
 CGContextSaveGState(context);
 CGContextBeginTransparencyLayer(context,nullptr);
 CGContextSetBlendMode(context,kCGBlendModePlusLighter);
 CGContextSetAlpha(context,1.0-fraction);
 NSPoint row=NSMakePoint(origin.x,lower/scale);
 [super drawGlyphsForGlyphRange:glyphs atPoint:row];
 CGContextSetAlpha(context,fraction);
 row.y+=1.0/scale;
 [super drawGlyphsForGlyphRange:glyphs atPoint:row];
 CGContextEndTransparencyLayer(context);
 CGContextRestoreGState(context);
}
-(void)fillBackgroundRectArray:(const NSRect*)rects count:(NSUInteger)count
             forCharacterRange:(NSRange)characters color:(NSColor*)color{
 NSTextView *editor=self.firstTextView;
 NSFont *font=editor.font;
 NSRange selected=NSIntersectionRange(characters,editor.selectedRange);
 // AppKit substitutes its own color when the selection is inactive.
 if(!font||!selected.length||selected.location>=editor.string.length||editor.hasMarkedText){
  [super fillBackgroundRectArray:rects count:count forCharacterRange:characters color:color];
  return;
 }
 NSUInteger glyph=[self glyphIndexForCharacterAtIndex:selected.location];
 NSRect band=volumeEditorTextBand(editor,glyph);
 for(NSUInteger i=0;i<count;i++){
  NSRect rect=rects[i];
  rect.origin.y=band.origin.y;
  rect.size.height=band.size.height;
  NSRectFill(rect);
 }
}
@end
@interface MXTCPVolumeFieldEditor : NSTextView
@end
@implementation MXTCPVolumeFieldEditor
-(NSPoint)textContainerOrigin{
 NSPoint origin=[super textContainerOrigin];
 // Keep AppKit's horizontal scrolling. The single-line editor shares the
 // passive readout's fractional vertical inset instead of snapping it.
 origin.y=self.textContainerInset.height;
 return origin;
}
-(BOOL)shouldDrawInsertionPoint{return NO;}
-(void)drawRect:(NSRect)dirty{
 [super drawRect:dirty];
 NSWindow *w=self.window;
 NSRange selection=self.selectedRange;
 if(!w||w.firstResponder!=self||selection.length||selection.location>self.string.length)return;
 NSRect screen=[self firstRectForCharacterRange:selection actualRange:nullptr];
 if(NSHeight(screen)<=0)return;
 CGFloat x=NSMinX([self convertRect:[w convertRectFromScreen:screen] fromView:nil]);
 NSRect caret=volumeEditorTextBand(self,0);
 CGFloat pixel=1.0/MAX(1.0,w.backingScaleFactor);
 caret.origin.y-=pixel;
 caret.size.height+=2.0*pixel;
 caret.size.width=pixel;
 caret.origin.x=MIN(x,NSMaxX(self.visibleRect)-pixel);
 [self.insertionPointColor setFill];
 NSRectFill(NSIntersectionRect(caret,self.visibleRect));
}
-(void)setSelectedRanges:(NSArray<NSValue*>*)ranges affinity:(NSSelectionAffinity)affinity
           stillSelecting:(BOOL)selecting{
 [super setSelectedRanges:ranges affinity:affinity stillSelecting:selecting];
 [self setNeedsDisplay:YES];
}
-(void)mouseDown:(NSEvent*)event{(void)event;}
-(void)resetCursorRects{
 [self addCursorRect:self.visibleRect cursor:NSCursor.arrowCursor];
}
-(void)cursorUpdate:(NSEvent*)event{
 (void)event;
 [NSCursor.arrowCursor set];
}
-(void)mouseMoved:(NSEvent*)event{
 (void)event;
 [NSCursor.arrowCursor set];
}
@end
@interface MXTCPVolumeField : NSTextField
@end
@implementation MXTCPVolumeField
-(void)mouseDown:(NSEvent*)event{(void)event;}
-(void)resetCursorRects{
 [self addCursorRect:self.visibleRect cursor:NSCursor.arrowCursor];
}
@end
@interface MXTCPVolumeCell : NSTextFieldCell
@property(nonatomic,strong) MXTCPVolumeFieldEditor *volumeEditor;
@end
@implementation MXTCPVolumeCell
-(NSTextView*)fieldEditorForView:(NSView*)view{
 (void)view;
 if(!self.volumeEditor){
  self.volumeEditor=[[MXTCPVolumeFieldEditor alloc]initWithFrame:NSZeroRect];
  [self.volumeEditor.textContainer replaceLayoutManager:[MXTCPVolumeLayoutManager new]];
  self.volumeEditor.fieldEditor=YES;
 }
 return self.volumeEditor;
}
-(NSRect)drawingRectForBounds:(NSRect)rect{
 rect=[super drawingRectForBounds:rect];
 CGFloat h=ceil(self.font.ascender-self.font.descender)+1;
 if(rect.size.height>h){rect.origin.y+=floor((rect.size.height-h)/2.0);rect.size.height=h;}
 return rect;
}
-(NSRect)editingRectForBounds:(NSRect)rect{
 // Keep the field editor at the same vertical location as the passive cell.
 return [self drawingRectForBounds:rect];
}
@end
// Editing lives in the SAME NSWindow as the TCP. The working track-name
// editor uses the native window field editor; a borderless child window did
// not reliably retain keyboard focus and left editing effectively disabled.
@interface MXTCPVolumeOverlay : NSView
@property(nonatomic,copy) NSString *volumeText;
@end
@implementation MXTCPVolumeOverlay
-(BOOL)isOpaque{return YES;}
-(BOOL)isFlipped{return YES;}
-(NSView*)hitTest:(NSPoint)point{(void)point;return nil;}
-(void)drawRect:(NSRect)dirty{
 (void)dirty;
 NSRect cell=self.bounds;
 [volumeBackground() setFill];
 NSRectFill(cell);
 if(!self.volumeText.length)return;

 NSFont *font=trackVolumeFont(NSWidth(cell));
 NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];
 paragraph.alignment=NSTextAlignmentCenter;
 NSTextStorage *text=[[NSTextStorage alloc]initWithString:self.volumeText attributes:@{
  NSFontAttributeName:font,
  NSForegroundColorAttributeName:NSColor.whiteColor,
  NSParagraphStyleAttributeName:paragraph
 }];
 MXTCPVolumeLayoutManager *layout=[MXTCPVolumeLayoutManager new];
 NSTextContainer *container=[[NSTextContainer alloc]initWithSize:
     NSMakeSize(NSWidth(cell),NSHeight(cell)+font.pointSize)];
 container.lineFragmentPadding=0;
 container.maximumNumberOfLines=1;
 [text addLayoutManager:layout];
 [layout addTextContainer:container];
 CGFloat scale=MAX(1.0,self.window.backingScaleFactor);
 layout.readoutScale=scale;
 CGFloat inset=volumeTextInset(layout,container,font,NSHeight(cell),scale);
 NSRange glyphs=[layout glyphRangeForTextContainer:container];
 if(!glyphs.length)return;
 // The scrolling field editor snaps its centered origin to a whole point.
 CGFloat glyphX=[layout locationForGlyphAtIndex:glyphs.location].x;
 CGFloat x=NSMinX(cell)+floor(glyphX)-glyphX;
 [NSGraphicsContext saveGraphicsState];
 NSRectClip(cell);
 [layout drawGlyphsForGlyphRange:glyphs atPoint:NSMakePoint(x,NSMinY(cell)+inset)];
 [NSGraphicsContext restoreGraphicsState];
}
@end
namespace {
bool finishVolume(bool commit);
}
@interface MXTCPVolumeDelegate : NSObject<NSTextFieldDelegate>
@end
@implementation MXTCPVolumeDelegate
-(void)controlTextDidBeginEditing:(NSNotification*)note{
 NSTextField *control=(NSTextField*)note.object;
 styleVolumeEditor((NSTextView*)control.currentEditor);
}
-(BOOL)control:(NSControl*)control textView:(NSTextView*)text doCommandBySelector:(SEL)cmd{
 (void)control;(void)text;
 if(cmd==@selector(cancelOperation:)){finishVolume(false);return YES;}
 if(cmd==@selector(insertNewline:)||cmd==@selector(insertTab:)||cmd==@selector(insertBacktab:)){
  finishVolume(true);return YES;
 }
 return NO;
}
@end
namespace {
NSRect visibleOnScreen(NSView *view){
 if(!view.window||view.isHiddenOrHasHiddenAncestor)return NSZeroRect;
 return [view.window convertRectToScreen:[view convertRect:view.visibleRect toView:nil]];
}
bool isNativeTCP(NSView *view){
 char name[64]{};
 return swellClassName&&swellClassName((__bridge void*)view,name,sizeof(name))&&
        std::string_view(name)=="REAPERTCPDisplay";
}
NSView *findTCP(NSView *view,NSRect screen,int depth){
 if(!view||depth>14||!NSContainsRect(visibleOnScreen(view),screen))return nil;
 NSString *cls=NSStringFromClass(view.class);
 if([cls containsString:@"REAPERTCPDisplay"]||isNativeTCP(view)){
  nativeVolumeTCP=view;
  return view;
 }
 if([cls containsString:@"TCPReadoutCanvas"])return view;
 for(NSView *child in view.subviews){
  if(NSView *tcp=findTCP(child,screen,depth+1))return tcp;
 }
 return nil;
}
NSRect volumeRect(void *t){
 // P_UI_RECT is the actual active WALTER label rectangle (57x20 on the
 // original reference theme). Never guess a hard-coded TCP x/y offset or
 // substitute tcp.volume, which can be a different control on other themes.
 return labelRect(t,"P_UI_RECT:tcp.volume.label");
}
bool volumeVisibleAtPoint(void *t,NSRect rect){
 if(!getTrackFromPoint||NSIsEmptyRect(rect))return false;
 // WALTER may return screen rectangles for tracks that have scrolled ABOVE
 // the TCP viewport. A host-window intersection is not a visibility test.
 // The native hit-test checks the actual window region under the readout.
 return getTrackFromPoint((int)floor(NSMidX(rect)),
                           (int)floor(NSMidY(rect)),nullptr)==t;
}
// GetTrackFromPoint can report the TCP under a floating FX. The overlay
// must belong to the TCP's window so the compositor keeps it under the FX.
NSView *volumeHostForScreenRect(NSRect screen){
 if(NSIsEmptyRect(screen))return nil;
 NSView *cached=nativeVolumeTCP;
 if(cached.window.isVisible&&!cached.window.isMiniaturized&&
    NSContainsRect(visibleOnScreen(cached),screen))return cached;
 id main=mainHwnd?(__bridge id)mainHwnd():nil;
 NSWindow *mainWindow=[main isKindOfClass:NSWindow.class]?main:
                      [main isKindOfClass:NSView.class]?[(NSView*)main window]:nil;
 for(NSWindow *candidate in NSApp.orderedWindows){
  if(!candidate.isVisible||candidate.isMiniaturized)continue;
  NSView *root=candidate.contentView;
  if(!NSContainsRect(visibleOnScreen(root),screen))continue;
  if(NSView *tcp=findTCP(root,screen,0))return tcp;
  // Some SWELL builds expose the TCP as a generic HWND. Only the main
  // window resolved by REAPER can use the native track hit as a fallback.
  if(candidate==mainWindow)return root;
 }
 return nil;
}
bool volumeReadoutMatches(const MXVolumeItem &item,NSRect screen){
 NSView *canvas=item.canvas;
 NSWindow *owner=canvas.window;
 return owner.isVisible&&!owner.isMiniaturized&&
    NSContainsRect(visibleOnScreen(canvas.superview),screen)&&
    NSEqualRects([owner convertRectToScreen:[canvas convertRect:canvas.bounds toView:nil]],screen);
}
bool volumeReadoutIsCovered(const MXVolumeItem &item,NSRect screen){
 if(!volumeReadoutMatches(item,screen))return false;
 NSWindow *owner=item.canvas.window;
 NSWindow *modal=NSApp.modalWindow;
 NSEvent *event=NSApp.currentEvent;
 for(NSWindow *front in NSApp.orderedWindows){
  if(front==owner)break;
  if(!front.isVisible||front.isMiniaturized)continue;
  if(NSIntersectsRect(front.frame,screen)||front==modal||
     (event.type==NSEventTypeLeftMouseDragged&&event.window==front))
   return true;
 }
 return false;
}
void hideVolumeOverlay(){
 for(auto &item:volumeItems)item.canvas.hidden=YES;
}
void volumeDiagnostic(const char *message, NSRect rect){
 static std::string previous;
 std::string key=message;
 if(key==previous)return;
 previous=key;
 NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/mixolve-custom-view-volume.log"];
 FILE *fp=fopen(path.fileSystemRepresentation,"a");
 if(fp){fprintf(fp,"v91: %s rect=(%.0f %.0f %.0f %.0f)\n",message,
       rect.origin.x,rect.origin.y,rect.size.width,rect.size.height);fclose(fp);}
}
BOOL positionVolumeEditor(){
 if(!volumeField||!volumeParent||!volumeWindow.isVisible||volumeWindow.isMiniaturized||
    volumeParent.window!=volumeWindow||
    project(-1,nullptr,0)!=volumeProject||!valid(volumeProject,volumeTrack,"MediaTrack*"))return NO;
 NSRect rect=volumeRect(volumeTrack);
 if(rect.size.width<15||rect.size.height<9||
    !NSContainsRect(visibleOnScreen(volumeParent),rect))
  return ++volumeEditorInvisibleTicks<=2;

 NSRect local=[volumeParent convertRect:[volumeWindow convertRectFromScreen:rect] fromView:nil];
 const bool moved=!NSEqualRects(volumeField.frame,local);
 // SWELL can return no track under the field editor itself. A new label
 // position still needs a native hit before we move the editor there.
 void *hit=getTrackFromPoint((int)floor(NSMidX(rect)),(int)floor(NSMidY(rect)),nullptr);
 if(hit!=volumeTrack&&(hit||moved))return ++volumeEditorInvisibleTicks<=2;

 volumeEditorInvisibleTicks=0;
 volumeEditorScreenRect=rect;
 if(moved){
  bool resized=!NSEqualSizes(volumeField.frame.size,local.size);
  volumeField.frame=local;
  if(resized)alignVolumeEditor((NSTextView*)volumeField.currentEditor,NSHeight(local));
 }
 return YES;
}
bool focusVolumeEditor(){
 NSWindow *w=volumeWindow;
 NSTextView *editor=(NSTextView*)volumeField.currentEditor;
 if(editor&&w.firstResponder==editor)return true;
 const bool hasDraft=initialVolumeText!=(volumeField.stringValue.UTF8String?:"");
 [volumeField selectText:nil];
 editor=(NSTextView*)volumeField.currentEditor;
 if(![editor isKindOfClass:NSTextView.class]||![w makeFirstResponder:editor])return false;
 styleVolumeEditor(editor);
 alignVolumeEditor(editor,NSHeight(volumeField.bounds));
 if(hasDraft)editor.selectedRange=NSMakeRange(editor.string.length,0);
 return true;
}
NSUInteger volumeCharacterIndex(NSTextView *editor,NSPoint windowPoint){
 NSPoint point=[editor convertPoint:windowPoint fromView:nil];
 return MIN(editor.string.length,[editor characterIndexForInsertionAtPoint:point]);
}
void positionVolumeCaret(NSEvent *event){
 if(!focusVolumeEditor())return;
 NSTextView *editor=(NSTextView*)volumeField.currentEditor;
 NSPoint location=event.locationInWindow;
 const bool withinInterval=volumeCaretClick.repeatUntil>event.timestamp;
 const bool nearLastClick=hypot(location.x-volumeCaretClick.point.x,
                               location.y-volumeCaretClick.point.y)<=4.0;
 if(event.clickCount>1||(withinInterval&&nearLastClick)){
  // Undo the first press's caret move when AppKit identifies a double-click.
  NSRange previous=volumeCaretClick.selectionBeforeClick;
  if(withinInterval&&NSMaxRange(previous)<=editor.string.length)
   editor.selectedRange=previous;
  return;
 }
 volumeCaretClick={location,event.timestamp+NSEvent.doubleClickInterval,editor.selectedRange};
 volumeSelectionAnchor=volumeCharacterIndex(editor,location);
 editor.selectedRange=NSMakeRange(volumeSelectionAnchor,0);
 [editor setNeedsDisplay:YES];
}
void updateVolumeReadout(void *t,NSView *hostView,NSRect location,bool hidden){
 auto it=std::find_if(volumeItems.begin(),volumeItems.end(),
     [t](const MXVolumeItem &item){return item.track==t;});
 if(it==volumeItems.end()){
  MXTCPVolumeOverlay *canvas=[[MXTCPVolumeOverlay alloc]initWithFrame:location];
  canvas.wantsLayer=YES;
  canvas.layer.opaque=YES;
  volumeItems.push_back({t,canvas,"",0});
  it=volumeItems.end()-1;
 }
 auto &item=*it;
 item.missed=0;
 if(item.canvas.superview!=hostView){
  [item.canvas removeFromSuperview];
  NSTextField *editor=volumeTrack==t&&volumeField.superview==hostView?volumeField:nil;
  [hostView addSubview:item.canvas positioned:editor?NSWindowBelow:NSWindowAbove relativeTo:editor];
 }
 if(!NSEqualRects(item.canvas.frame,location)){
  bool resized=!NSEqualSizes(item.canvas.frame.size,location.size);
  item.canvas.frame=location;
  if(resized)[item.canvas setNeedsDisplay:YES];
 }
 const std::string text=mx::trackVolumeDisplay(trackNumber(t,"D_VOL"));
 if(text!=item.text){
  item.text=text;
  MXTCPVolumeOverlay *canvas=(MXTCPVolumeOverlay*)item.canvas;
  canvas.volumeText=[NSString stringWithUTF8String:text.c_str()];
  [canvas setNeedsDisplay:YES];
 }
 item.canvas.hidden=hidden;
}
double volumeFaderSetting(const char *name,double fallback){
 int size=0;
 const void *value=volumeConfigVar?volumeConfigVar(name,&size):nullptr;
 if(!value||size!=sizeof(double))return fallback;
 const double db=*static_cast<const double*>(value);
 return std::isfinite(db)?db:fallback;
}
mx::TrackVolumeRange volumeFaderRange(){
 mx::TrackVolumeRange range;
 range.minDb=volumeFaderSetting("sliderminv",range.minDb);
 range.maxDb=volumeFaderSetting("slidermaxv",range.maxDb);
 return range.minDb>=-160.0&&range.maxDb<=60.0&&range.minDb<range.maxDb?
     range:mx::TrackVolumeRange{};
}
void applyTrackVolume(void *p,void *anchor,double target,double factor,mx::TrackVolumeRange range,bool scrolling=false){
 struct Change {void *track;double gain;};
 std::vector<Change> gains{{anchor,trackNumber(anchor,"D_VOL")}};
 if(factor!=1.0&&trackNumber(anchor,"I_SELECTED")!=0.0){
  for(int i=0,n=countTracks(p);i<n;i++){
   void *t=getTrack(p,i);
   if(t&&t!=anchor&&trackNumber(t,"I_SELECTED")!=0.0)
    gains.push_back({t,trackNumber(t,"D_VOL")});
  }
 }
 const double minimum=mx::volumeGainFromDb(range.minDb);
 const double maximum=mx::volumeGainFromDb(range.maxDb);
 if(factor>0.0){
  double minFactor=0.0,maxFactor=INFINITY;
  for(const auto &entry:gains){
   if(entry.gain<=0.0||!std::isfinite(entry.gain))continue;
   minFactor=std::max(minFactor,minimum/entry.gain);
   maxFactor=std::min(maxFactor,maximum/entry.gain);
  }
  // Limit the whole selection at the first fader bound. Older, out-of-range
  // values may span more than the entire fader range; clamp those individually.
  if(minFactor<=maxFactor)factor=std::clamp(factor,minFactor,maxFactor);
 }
 std::vector<Change> changes;
 for(const auto &entry:gains){
  const double shifted=entry.gain>0.0?entry.gain*factor:
      entry.track==anchor?target:0.0;
  if(!std::isfinite(entry.gain)||std::isnan(shifted))continue;
  const double limited=shifted>0.0?
      mx::muteTrackVolumeBelowThreshold(std::clamp(shifted,minimum,maximum)):0.0;
  if(limited!=entry.gain)changes.push_back({entry.track,limited});
 }
 if(changes.empty())return;
 const bool multipleTracks=changes.size()>1;
 if(scrolling){
  const double now=NSProcessInfo.processInfo.systemUptime;
  if(volumeScrollUndo.project!=p||volumeScrollUndo.anchor!=anchor||now>=volumeScrollUndo.deadline)
   finishVolumeScrollUndo();
  if(!volumeScrollUndo.project){
   undoBegin(p);
   volumeScrollUndo={p,anchor,now+volumeScrollUndoInterval,multipleTracks};
  }
  volumeScrollUndo.multipleTracks|=multipleTracks;
 }else{
  finishVolumeScrollUndo();
  undoBegin(p);
 }
 for(const auto &change:changes)setTrackNumber(change.track,"D_VOL",change.gain);
 if(!scrolling)undoEnd(p,multipleTracks?"Adjust selected track volumes":"Set track volume",1);
 dirty(p);
 // A gain change only needs repainting. Adjusting the track-list layout
 // recalculates the arrange scroll ranges and re-enables both scrollbars.
 [nativeVolumeTCP setNeedsDisplay:YES];
 arrange();
}
bool finishVolume(bool commit){
 if(!volumeField||volumeFinishing)return true;
 NSTextField *closing=volumeField;
 NSString *entered=[closing.currentEditor isKindOfClass:NSTextView.class]?
   [(NSTextView*)closing.currentEditor string]:closing.stringValue;
 bool unchanged=entered&&initialVolumeText==entered.UTF8String;
 double target=initialVolume;
 const auto range=volumeFaderRange();
 if(commit&&!unchanged&&!mx::parseTrackVolume(entered.UTF8String?:"",target,range)){
  NSBeep();return false;
 }
 volumeFinishing=true;
 volumeCaretClick={};
 volumeSelectionAnchor=NSNotFound;
 if(commit&&!unchanged&&project(-1,nullptr,0)==volumeProject&&
    valid(volumeProject,volumeTrack,"MediaTrack*")&&
    trackNumber&&setTrackNumber&&
    trackNumber(volumeTrack,"D_VOL")==initialVolume&&target!=initialVolume){
  // A zero-gain reference has no finite dB offset. Entering a finite
  // level there restores just that track and leaves the others in place.
  const double factor=initialVolume>0.0?target/initialVolume:1.0;
  applyTrackVolume(volumeProject,volumeTrack,target,factor,range);
 }
 NSWindow *w=volumeWindow;
 // Restore the painted value before detaching the field. Waiting for the
 // next REAPER timer update exposes the theme's own readout in between.
 NSView *hostView=volumeParent;
 if(w.isVisible&&hostView.window==w&&volumeProject==volumeItemsProject&&
    project(-1,nullptr,0)==volumeProject&&valid(volumeProject,volumeTrack,"MediaTrack*")&&
    NSEqualRects(volumeRect(volumeTrack),volumeEditorScreenRect)&&
    NSContainsRect(visibleOnScreen(hostView),volumeEditorScreenRect))
  updateVolumeReadout(volumeTrack,hostView,closing.frame,false);
 volumeField=nil;volumeTrack=nullptr;volumeProject=nullptr;
 volumeParent=nil;volumeWindow=nil;initialVolumeText.clear();
 volumeEditorInvisibleTicks=0;
 volumeEditorScreenRect=NSZeroRect;
 [w endEditingFor:closing];[closing removeFromSuperview];
 volumeFinishing=false;
 return true;
}
void beginVolume(void *t,NSView *view){
 if(volumeField&&!finishVolume(true))return;
 if(field)finish(true);
 NSWindow *w=view.window;
 if(!trackNumber||!setTrackNumber||!t||!w)return;
 NSRect screen=volumeRect(t);
 if(screen.size.width<15||screen.size.height<9||
    volumeHostForScreenRect(screen)!=view)return;
 volumeEditorInvisibleTicks=0;
 volumeTrack=t;volumeProject=project(-1,nullptr,0);
 initialVolume=trackNumber(t,"D_VOL");
 initialVolumeText=mx::trackVolumeDisplay(initialVolume);
 volumeWindow=w;
 volumeParent=view;
 volumeField=[[MXTCPVolumeField alloc]initWithFrame:NSZeroRect];
 volumeField.cell=[[MXTCPVolumeCell alloc]initTextCell:@""];
 volumeField.font=trackVolumeFont(screen.size.width);
 volumeField.stringValue=[NSString stringWithUTF8String:initialVolumeText.c_str()]?:@"";
 volumeField.alignment=NSTextAlignmentCenter;
 volumeField.textColor=NSColor.whiteColor;
 volumeField.backgroundColor=volumeBackground();
 volumeField.drawsBackground=YES;
 volumeField.bordered=NO;volumeField.bezeled=NO;
 volumeField.focusRingType=NSFocusRingTypeNone;
 volumeField.editable=YES;volumeField.selectable=YES;
 volumeField.cell.scrollable=YES;volumeField.cell.usesSingleLineMode=YES;
 volumeField.cell.wraps=NO;
 volumeField.delegate=volumeDelegate;
 for(auto &item:volumeItems)if(item.track==t)item.canvas.hidden=YES;
 volumeEditorScreenRect=screen;
 volumeField.frame=[view convertRect:[w convertRectFromScreen:screen] fromView:nil];
 [view addSubview:volumeField positioned:NSWindowAbove relativeTo:nil];
 if(!w.isKeyWindow&&NSApp.isActive)[w makeKeyWindow];
 if(focusVolumeEditor())volumeDiagnostic("edit: inline field focused",screen);
}
void refreshVolumeReadouts(){
 void *p=project(-1,nullptr,0);
 // Track pointers may be reused on project/tab switch. Don't let an old
 // project's overlay briefly paint over a different track with the same ptr.
 if(p!=volumeItemsProject){
  for(auto &item:volumeItems)[item.canvas removeFromSuperview];
  volumeItems.clear();
  volumeItemsProject=p;
 }
 if(!p||!countTracks||!trackNumber||!getTrack){hideVolumeOverlay();return;}
 for(auto &item:volumeItems)++item.missed;
 int visible=0;
 for(int i=0,n=countTracks(p);i<n;i++){
  void *t=getTrack(p,i);
  NSRect r=volumeRect(t);
  if(r.size.width<15||r.size.height<9)continue;
  if(!volumeVisibleAtPoint(t,r)){
   auto existing=std::find_if(volumeItems.begin(),volumeItems.end(),
       [t](const MXVolumeItem &item){return item.track==t;});
   // Window overlap can temporarily mask the native TCP hit. Keep the
   // verified overlay in its own window so the compositor clips it.
   if(existing!=volumeItems.end()&&volumeReadoutIsCovered(*existing,r)){
    existing->missed=0;
    existing->canvas.hidden=(volumeField&&volumeTrack==t);
   }
   continue;
  }
  NSView *hostView=volumeHostForScreenRect(r);
  NSWindow *hostWindow=hostView.window;
  if(!hostWindow)continue;
  NSRect location=[hostView convertRect:[hostWindow convertRectFromScreen:r] fromView:nil];
  if(!NSIntersectsRect(location,hostView.bounds))continue;
  ++visible;
  updateVolumeReadout(t,hostView,location,volumeField&&volumeTrack==t);
 }
 for(auto it=volumeItems.begin();it!=volumeItems.end();){
  // A missed hit can keep its cached view, but never a stale screen position.
  if(it->missed&&(it->missed>=3||!valid(p,it->track,"MediaTrack*")||
     !volumeReadoutMatches(*it,volumeRect(it->track))))
   it->canvas.hidden=YES;
  if(it->missed>=50){[it->canvas removeFromSuperview];it=volumeItems.erase(it);}
  else ++it;
 }
 if(visible)volumeDiagnostic("readouts attached to native TCP window",NSZeroRect);
}

// Move the layers in the same AppKit update as the host's track rows.
void syncVolumeReadouts(){
 if(refreshingVolumeReadouts)return;
 refreshingVolumeReadouts=true;
 [CATransaction begin];
 [CATransaction setDisableActions:YES];
 refreshVolumeReadouts();
 [CATransaction commit];
 refreshingVolumeReadouts=false;
}
void drawTCPWhileTracking(NSView *view,SEL selector,NSRect dirty){
 IMP original=tcpPaintHooks.original(view,selector);
 if(!original)return;
 ((void(*)(id,SEL,NSRect))original)(view,selector,dirty);
 // SWELL can repaint inside its mouse tracking loop without an AppKit
 // sendEvent: call for each drag. Use the geometry from this native paint.
 if(host.reg&&view==nativeVolumeTCP&&tcpTrackingWindow&&view.window==tcpTrackingWindow)
  syncVolumeReadouts();
}
void tickVolume(bool afterScroll=false){
 if(volumeField){
  NSWindow *key=NSApp.keyWindow;
  if(!positionVolumeEditor()||(afterScroll&&volumeEditorInvisibleTicks)){
   volumeDiagnostic("edit: track is no longer visible",volumeEditorScreenRect);
   finishVolume(false);
  }else if(!NSApp.isActive){
   if(!finishVolume(true))finishVolume(false);
  }else if(!key||key==volumeWindow){
   // Focus changes during SWELL layout do not end the editing session.
   focusVolumeEditor();
  }
 }
 syncVolumeReadouts();
}
void open(void *t,NSView *view,NSWindow *w){
 if(volumeField&&!finishVolume(true))return;
 if(field)finish(true);
 owner=project(-1,nullptr,0);track=t;parent=view;window=w;
 char name[65536]{};trackString(track,"P_NAME",name,false);initial=name;
 field=[[NSTextField alloc]initWithFrame:NSZeroRect];
 field.cell=[[MXTCPNameCell alloc]initTextCell:@""];
 field.font=[NSFont fontWithName:@"CharonMonoCaps-Bold" size:16]?:[NSFont monospacedSystemFontOfSize:16 weight:NSFontWeightBold];
 field.stringValue=[NSString stringWithUTF8String:name]?:@"";previousText=field.stringValue;
 field.textColor=NSColor.whiteColor;field.backgroundColor=[NSColor colorWithCalibratedWhite:34.0/255 alpha:1];
 field.drawsBackground=YES;field.bordered=NO;field.bezeled=NO;field.focusRingType=NSFocusRingTypeNone;
 field.editable=YES;field.selectable=YES;field.delegate=delegate;
 field.cell.usesSingleLineMode=YES;field.cell.scrollable=YES;field.cell.wraps=NO;
 [view addSubview:field];if(!place()){finish(false);return;}
 NSTextView *editor=(NSTextView*)[w fieldEditor:YES forObject:field];
 if(!editor){finish(false);return;}
 editor.fieldEditor=YES;
 [field.cell selectWithFrame:field.bounds inView:field editor:editor delegate:field start:0 length:field.stringValue.length];
 if(![w makeFirstResponder:editor]){finish(false);return;}
 selectionStyle();editor.selectedRange=NSMakeRange(0,editor.string.length);
}
void *volumeTrackAt(void *p,NSWindow *w,NSPoint point,NSRect &rect){
 if(!p||!w||!trackNumber||!setTrackNumber||!countTracks||!getTrack)return nullptr;
 for(int i=0,n=countTracks(p);i<n;i++){
  void *t=getTrack(p,i);
  NSRect r=volumeRect(t);
  if(contains(r,point)&&volumeVisibleAtPoint(t,r)&&volumeHostForScreenRect(r).window==w){
   rect=r;
   return t;
  }
 }
 return nullptr;
}
bool scrollTrackVolume(NSEvent *event){
 const double vertical=event.scrollingDeltaY;
 if(!std::isfinite(vertical)||vertical==0.0||
    std::abs(vertical)<std::abs(event.scrollingDeltaX))return false;
 NSWindow *w=event.window;
 if(!w)return false;
 NSPoint point=[w convertPointToScreen:event.locationInWindow];
 void *p=project(-1,nullptr,0);
 if(!p)return false;
 void *anchor=nullptr;
 if(volumeField&&w==volumeWindow&&p==volumeProject&&contains(volumeEditorScreenRect,point)){
  anchor=volumeTrack;
 }else{
  anchor=getTrackFromPoint((int)floor(point.x),(int)floor(point.y),nullptr);
  if(!anchor)return false;
  NSRect rect=volumeRect(anchor);
  if(!contains(rect,point)||volumeHostForScreenRect(rect).window!=w)return false;
 }
 if(!valid(p,anchor,"MediaTrack*"))return false;

 // Ignore gesture momentum so the gain stops changing when the fingers stop.
 if(event.momentumPhase!=NSEventPhaseNone)return true;
 if(volumeField&&!finishVolume(true))return true;
 if(project(-1,nullptr,0)!=p||!valid(p,anchor,"MediaTrack*"))return true;

 constexpr double stepDb=0.01;
 const double delta=std::clamp(vertical*stepDb,-6.0,6.0);
 const double current=trackNumber(anchor,"D_VOL");
 const auto range=volumeFaderRange();
 if(current==0.0){
  if(delta>0.0){
   const double resumeDb=std::max(range.minDb,mx::trackVolumeMuteThresholdDb);
   applyTrackVolume(p,anchor,mx::volumeGainFromDb(resumeDb+std::max(0.0,delta-stepDb)),1.0,range,true);
  }
  return true;
 }
 const double factor=mx::volumeGainFromDb(delta);
 applyTrackVolume(p,anchor,current*factor,factor,range,true);
 return true;
}
bool mouseEvent(NSEvent *event){
 switch(event.type){
  case NSEventTypeScrollWheel:
   if(scrollTrackVolume(event))return true;
   finishVolumeScrollUndo();
   return false;
  case NSEventTypeLeftMouseDown:
  case NSEventTypeRightMouseDown:
  case NSEventTypeOtherMouseDown:
  case NSEventTypeKeyDown:
   finishVolumeScrollUndo();
   break;
  default:break;
 }
 if(event.type==NSEventTypeKeyDown&&volumeField){
  if(event.window==volumeWindow||(!event.window&&NSApp.keyWindow==volumeWindow)){
   unsigned short key=event.keyCode;
   if(key==53||key==36||key==76||key==48){
    swallowedKey=key;finishVolume(key!=53);return true;
   }
   focusVolumeEditor();
   volumeCaretClick={};
   volumeSelectionAnchor=NSNotFound;
  }else if(event.window){
   if(!finishVolume(true))finishVolume(false);
  }
 }
 if(event.type==NSEventTypeKeyUp&&event.keyCode==swallowedKey){swallowedKey=-1;return true;}
 if(event.type==NSEventTypeKeyDown&&field&&(event.window==window||NSApp.keyWindow==window)){
  unsigned short key=event.keyCode;
  if(key==53||key==36||key==76||key==48){swallowedKey=key;finish(key!=53);return true;}
 }

 bool down=event.type==NSEventTypeLeftMouseDown;
 bool up=event.type==NSEventTypeLeftMouseUp;
 bool drag=event.type==NSEventTypeLeftMouseDragged;
 if(!down&&!up&&!drag)return false;
 if(swallowRelease){
  if(drag){
   if(volumeSelectionAnchor!=NSNotFound&&focusVolumeEditor()){
    NSTextView *editor=(NSTextView*)volumeField.currentEditor;
    NSPoint screen=event.window?[event.window convertPointToScreen:event.locationInWindow]:NSEvent.mouseLocation;
    NSUInteger index=volumeCharacterIndex(editor,[volumeWindow convertPointFromScreen:screen]);
    NSUInteger anchor=MIN(volumeSelectionAnchor,editor.string.length);
    editor.selectedRange=NSMakeRange(MIN(anchor,index),MAX(anchor,index)-MIN(anchor,index));
    volumeCaretClick={};
   }
   return true;
  }
  volumeSelectionAnchor=NSNotFound;
  swallowRelease=false;
  if(up)return true;
 }
 if(drag){
  if(!volumePress.track)return false;
  NSPoint point=event.window?[event.window convertPointToScreen:event.locationInWindow]:NSEvent.mouseLocation;
  // Minor motion while clicking is still a click. A drag must leave the
  // label and its small margin before it cancels the pending edit.
  if(!contains(NSInsetRect(volumePress.label,-4.0,-4.0),point))volumePress.dragged=true;
  return true;
 }
 if(up){
  MXVolumePress completed=volumePress;
  volumePress={};
  if(!completed.track)return false;
  if(!completed.dragged&&project(-1,nullptr,0)==completed.project&&
     valid(completed.project,completed.track,"MediaTrack*")){
   NSView *hostView=volumeHostForScreenRect(volumeRect(completed.track));
   if(hostView.window.windowNumber==completed.windowNumber)beginVolume(completed.track,hostView);
  }
  return true;
 }
 if(!event.window)return false;
 NSPoint point=[event.window convertPointToScreen:event.locationInWindow];
 // mouseDown
 volumePress={};
 if(volumeField){
  NSRect editRect=[volumeWindow convertRectToScreen:
     [volumeField convertRect:volumeField.bounds toView:nil]];
  if(event.window==volumeWindow&&contains(editRect,point)){
   positionVolumeCaret(event);
   swallowRelease=true;
   return true;
  }
  if(!finishVolume(true)){swallowRelease=true;return true;}
 }
 if(field){
  NSRect rect=[window convertRectToScreen:[field convertRect:field.bounds toView:nil]];
  if(event.window==window&&contains(rect,point))return false;
  finish(true);
 }
 NSView *root=event.window.contentView,*target=[root hitTest:[root convertPoint:event.locationInWindow fromView:nil]];
 // A single press can open the editor. All presses on the readout are
 // consumed before SWELL receives them.
 void *p=project(-1,nullptr,0);
 NSRect rect=NSZeroRect;
 if(void *t=volumeTrackAt(p,event.window,point,rect)){
  // AppKit can carry a click count over from a nearby control. A
  // readout that is not editing can always accept its first press.
  volumePress={t,p,rect,event.windowNumber,false};
  return true;
 }
 NSString *targetClass=NSStringFromClass(target.class);
 if(![targetClass containsString:@"REAPERTCPDisplay"]&&![targetClass containsString:@"TCPReadoutCanvas"])return false;
 for(int i=0;i<countTracks(p);i++){
  void *t=getTrack(p,i);NSRect label=labelRect(t,"P_UI_RECT:tcp.label");
  if(contains(label,point)&&event.clickCount>=2){open(t,target,event.window);swallowRelease=true;return true;}
  // Keep the old editor's suppression of clicks on envelope-name labels.
  NSRect panel=labelRect(t,"P_UI_RECT:tcp.size");
  if(label.size.width>0&&panel.size.height>0&&point.x>=label.origin.x&&point.x<NSMaxX(label)){
   for(int j=0;j<countEnvelopes(t);j++){
    void *env=getEnvelope(t,j);double h=envelopeValue(env,"I_TCPH"),y=envelopeValue(env,"I_TCPY");
    double top=NSMaxY(panel)-y-floor((h-label.size.height)/2);
    if(h>0&&point.y<=top&&point.y>top-label.size.height){swallowRelease=true;return true;}
   }
  }
 }
 return false;
}
void tick(){
 if(volumeScrollUndo.project&&
    (project(-1,nullptr,0)!=volumeScrollUndo.project||
     NSProcessInfo.processInfo.systemUptime>=volumeScrollUndo.deadline))finishVolumeScrollUndo();
 tickVolume();
 if(field){if(!place())finish(false);return;}
 // Also replace REAPER's native rename field when opened by an action/keyboard.
 NSWindow *w=NSApp.keyWindow;NSTextView *text=(NSTextView*)w.firstResponder;
 if(![text isKindOfClass:NSTextView.class])return;
 NSTextField *native=(NSTextField*)text.delegate;
 if(![native isKindOfClass:NSTextField.class]||native.tag!=1000)return;
 NSView *view=native.superview;
 while(view&&![NSStringFromClass(view.class) containsString:@"REAPERTCPDisplay"]&&![NSStringFromClass(view.class) containsString:@"TCPReadoutCanvas"])view=view.superview;
 if(!view)return;
 NSRect rect=[w convertRectToScreen:[native convertRect:native.bounds toView:nil]];
 void *p=project(-1,nullptr,0);
 for(int i=0;i<countTracks(p);i++){
  void *t=getTrack(p,i);NSRect label=labelRect(t,"P_UI_RECT:tcp.label");
  if(label.size.width>0&&fabs(label.origin.x-rect.origin.x)<=3&&fabs(NSMaxY(label)-NSMaxY(rect))<=3){
   NSEvent *escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil characters:@"\033" charactersIgnoringModifiers:@"\033" isARepeat:NO keyCode:53];
   [w sendEvent:escape];open(t,view,w);return;
  }
 }
}
}
extern "C" void MixolveUpdateTCPVolumeLayout(NSEvent *event,bool afterDispatch){
 if(!host.reg)return;
 NSWindow *w=event.window;
 if(!w)return;
 if(event.type==NSEventTypeScrollWheel){
  auto inWindow=[w](const MXVolumeItem &item){return item.canvas.window==w;};
  if(w!=volumeWindow&&std::none_of(volumeItems.begin(),volumeItems.end(),inWindow))return;
  if(afterDispatch)tickVolume(true);
  else for(auto &item:volumeItems)if(inWindow(item))item.canvas.hidden=YES;
  return;
 }
 if(!afterDispatch&&event.type==NSEventTypeLeftMouseDown){
  tcpTrackingWindow=nil;
  NSPoint point=[w convertPointToScreen:event.locationInWindow];
  NSView *tcp=volumeHostForScreenRect(NSMakeRect(point.x,point.y,1,1));
  if(tcp&&tcp==nativeVolumeTCP&&tcp.window==w)tcpTrackingWindow=w;
  return;
 }
 if(!afterDispatch||tcpTrackingWindow!=w)return;
 switch(event.type){
  case NSEventTypeLeftMouseDown:
  case NSEventTypeLeftMouseDragged:
  case NSEventTypeLeftMouseUp:
   tickVolume();
   if(event.type==NSEventTypeLeftMouseUp||!(NSEvent.pressedMouseButtons&1))
    tcpTrackingWindow=nil;
   break;
  default:break;
 }
}
extern "C" void MixolveUpdateTCPVolumePointer(NSEvent *event){
 NSWindow *w=volumeWindow;
 if(!volumeField||!w||event.window!=w)return;
 switch(event.type){
  case NSEventTypeMouseMoved:
  case NSEventTypeCursorUpdate:
  case NSEventTypeMouseEntered:
  case NSEventTypeLeftMouseDown:
  case NSEventTypeLeftMouseUp:
  case NSEventTypeLeftMouseDragged:
   if(NSPointInRect([volumeField convertPoint:event.locationInWindow fromView:nil],volumeField.bounds))
    [NSCursor.arrowCursor set];
   break;
  default:break;
 }
}
extern "C" bool MixolveTrackNameEntry(ep::Info *info){
 if(!info){
  if(host.reg){
   MixolveSetTCPNameMouseFilter(nullptr);host.reg("-timer",(void*)tick);
   host.reg("-hookcommand2",reinterpret_cast<void*>(beforeVolumeScrollCommand));
   finishVolumeScrollUndo();
   tcpPaintHooks.uninstall();
   finishVolume(false);finish(false);
   hideVolumeOverlay();
   for(auto &item:volumeItems)[item.canvas removeFromSuperview];
   volumeItems.clear();volumeItemsProject=nullptr;
  }
  host={};delegate=nil;volumeDelegate=nil;
  nativeVolumeTCP=nil;tcpTrackingWindow=nil;swellClassName=nullptr;
  swallowRelease=false;swallowedKey=-1;volumePress={};volumeCaretClick={};volumeSelectionAnchor=NSNotFound;return true;
 }
 if(host.reg)return true;
#define LOAD(var,key) var=(decltype(var))info->get(key);if(!var)return false
 LOAD(project,"EnumProjects");LOAD(countTracks,"CountTracks");LOAD(getTrack,"GetTrack");LOAD(trackString,"GetSetMediaTrackInfo_String");LOAD(valid,"ValidatePtr2");
 LOAD(countEnvelopes,"CountTrackEnvelopes");LOAD(getEnvelope,"GetTrackEnvelope");LOAD(envelopeValue,"GetEnvelopeInfo_Value");
 LOAD(undoBegin,"Undo_BeginBlock2");LOAD(undoEnd,"Undo_EndBlock2");LOAD(dirty,"MarkProjectDirty");LOAD(adjust,"TrackList_AdjustWindows");LOAD(arrange,"UpdateArrange");
 LOAD(trackNumber,"GetMediaTrackInfo_Value");LOAD(setTrackNumber,"SetMediaTrackInfo_Value");
 LOAD(getTrackFromPoint,"GetTrackFromPoint");LOAD(mainHwnd,"GetMainHwnd");
#undef LOAD
 volumeConfigVar=reinterpret_cast<decltype(volumeConfigVar)>(info->get("get_config_var"));
 if(!info->reg("timer",(void*)tick))return false;
 if(!info->reg("<hookcommand2",reinterpret_cast<void*>(beforeVolumeScrollCommand))){
  info->reg("-timer",(void*)tick);
  return false;
 }
 host=*info;delegate=[MXTCPNameDelegate new];volumeDelegate=[MXTCPVolumeDelegate new];
 if(auto get=mx::findSwellAPI())swellClassName=(decltype(swellClassName))get("GetClassName");
 tcpPaintHooks.install(NSClassFromString(@"REAPERSwell_hwnd"),@selector(drawRect:),(IMP)drawTCPWhileTracking);
 MixolveSetTCPNameMouseFilter(mouseEvent);return true;
}
