#import <AppKit/AppKit.h>
#include "model.hpp"
#include <cstdio>
#include <cmath>

extern "C" void MixolveSetTCPNameMouseFilter(bool (*)(NSEvent*));
namespace {
ep::Info host{};
void *(*project)(int,char*,int);
int (*countTracks)(void*);
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
int swallowedKey=-1;
NSRect labelRect(void *t,const char *key){
 char text[1024]{};int x,y,w,h;
 if(!trackString(t,key,text,false)||std::sscanf(text,"%d %d %d %d",&x,&y,&w,&h)!=4||w<=0||h<=0)return NSZeroRect;
 // REAPER's macOS screen rect stores the top edge in native bottom-up coordinates.
 return NSMakeRect(x,y-h,w,h);
}
bool contains(NSRect rect,NSPoint point){return rect.size.width>0&&NSPointInRect(point,rect);}
void finish(bool commit){
 if(!field||finishing)return;
 finishing=true;
 NSTextField *closing=field;NSWindow *w=window;
 NSString *name=[closing.currentEditor isKindOfClass:NSTextView.class]?[(NSTextView*)closing.currentEditor string]:closing.stringValue;
 if(commit&&project(-1,nullptr,0)==owner&&valid(owner,track,"MediaTrack*")){
  char old[65536]{};trackString(track,"P_NAME",old,false);
  // A different rename while editing must not be overwritten by stale input.
  if(initial==old&&name&&initial!=name.UTF8String){
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
namespace {
void open(void *t,NSView *view,NSWindow *w){
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
bool mouseEvent(NSEvent *event){
 if(event.type==NSEventTypeKeyUp&&event.keyCode==swallowedKey){swallowedKey=-1;return true;}
 if(event.type==NSEventTypeKeyDown&&field&&(event.window==window||NSApp.keyWindow==window)){
  unsigned short key=event.keyCode;
  if(key==53||key==36||key==76||key==48){swallowedKey=key;finish(key!=53);return true;}
 }

 bool down=event.type==NSEventTypeLeftMouseDown,up=event.type==NSEventTypeLeftMouseUp,drag=event.type==NSEventTypeLeftMouseDragged;
 if(!down&&!up&&!drag)return false;
 if(swallowRelease){if(up)swallowRelease=false;if(up||drag)return true;swallowRelease=false;}
 if(!down||!event.window)return false;
 NSPoint point=[event.window convertPointToScreen:event.locationInWindow];
 if(field){
  NSRect rect=[window convertRectToScreen:[field convertRect:field.bounds toView:nil]];
  if(event.window==window&&contains(rect,point))return false;
  finish(true);
 }
 NSView *root=event.window.contentView,*target=[root hitTest:[root convertPoint:event.locationInWindow fromView:nil]];
 NSString *targetClass=NSStringFromClass(target.class);
 if(![targetClass containsString:@"REAPERTCPDisplay"]&&![targetClass containsString:@"TCPReadoutCanvas"])return false;
 void *p=project(-1,nullptr,0);
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
extern "C" bool MixolveTrackNameEntry(ep::Info *info){
 if(!info){if(host.reg){MixolveSetTCPNameMouseFilter(nullptr);host.reg("-timer",(void*)tick);finish(false);}host={};delegate=nil;swallowRelease=false;swallowedKey=-1;return true;}
 if(host.reg)return true;
#define LOAD(var,key) var=(decltype(var))info->get(key);if(!var)return false
 LOAD(project,"EnumProjects");LOAD(countTracks,"CountTracks");LOAD(getTrack,"GetTrack");LOAD(trackString,"GetSetMediaTrackInfo_String");LOAD(valid,"ValidatePtr2");
 LOAD(countEnvelopes,"CountTrackEnvelopes");LOAD(getEnvelope,"GetTrackEnvelope");LOAD(envelopeValue,"GetEnvelopeInfo_Value");
 LOAD(undoBegin,"Undo_BeginBlock2");LOAD(undoEnd,"Undo_EndBlock2");LOAD(dirty,"MarkProjectDirty");LOAD(adjust,"TrackList_AdjustWindows");LOAD(arrange,"UpdateArrange");
#undef LOAD
 if(!info->reg("timer",(void*)tick))return false;
 host=*info;delegate=[MXTCPNameDelegate new];MixolveSetTCPNameMouseFilter(mouseEvent);return true;
}
