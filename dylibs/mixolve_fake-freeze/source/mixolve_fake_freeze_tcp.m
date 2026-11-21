/*
  mixolve_fake-freeze TCP button input bridge (macOS / AppKit).

  Port of the F/LI repeat-click handling in supplied custom-view/keyboard.mm.
  It does NOT change keyboard shortcuts, track-name editing, or other buttons.
  WALTER button sprites/placements are provided by the user's existing theme.
*/
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <math.h>

static Class mff_app_class;
static IMP mff_original_send;
static IMP mff_original_current;
static NSEvent *mff_dispatch_input;
static NSEvent *mff_dispatch_substitute;
static __weak NSWindow *mff_last_window;
static NSPoint mff_last_point;
static NSTimeInterval mff_last_time;

static NSEvent *mff_single_tcp_click(NSEvent *event) {
    if (event.type != NSEventTypeLeftMouseDown || event.clickCount <= 1)
        return event;
    if (!mff_last_window || event.window != mff_last_window)
        return event;
    NSPoint p = event.locationInWindow;
    if (fabs(p.x - mff_last_point.x) > 4 || fabs(p.y - mff_last_point.y) > 4)
        return event;
    double dt = event.timestamp - mff_last_time;
    if (dt < 0 || dt > fmax(1.0, [NSEvent doubleClickInterval] * 2.0))
        return event;

    NSEvent *single = [NSEvent mouseEventWithType:event.type
            location:p modifierFlags:event.modifierFlags timestamp:event.timestamp
            windowNumber:event.windowNumber context:nil eventNumber:event.eventNumber
            clickCount:1 pressure:event.pressure];
    return single ?: event;
}

static NSEvent *mff_current_event(id self, SEL selector) {
    NSEvent *native = ((NSEvent *(*)(id, SEL))mff_original_current)(self, selector);
    /* Native dialogs can re-enter the event loop during a render: never
       substitute an event other than the exact event being dispatched. */
    return mff_dispatch_substitute && native == mff_dispatch_input
         ? mff_dispatch_substitute : native;
}

static void mff_refresh_tcp_target(NSEvent *event) {
    if (event.type != NSEventTypeLeftMouseDown || !event.window) return;
    NSView *root = event.window.contentView;
    if (!root) return;
    NSPoint local = [root convertPoint:event.locationInWindow fromView:nil];
    NSView *target = [root hitTest:local];
    if (!target || ![NSStringFromClass(target.class) containsString:@"REAPERTCPDisplay"])
        return;
    /* WALTER layout changes can invalidate virtual-control hover targets
       while the physical mouse pointer remains stationary. */
    NSEvent *move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
            location:event.locationInWindow modifierFlags:event.modifierFlags
            timestamp:event.timestamp windowNumber:event.windowNumber
            context:nil eventNumber:event.eventNumber clickCount:0 pressure:0];
    if (move) [target mouseMoved:move];
}

static void mff_send_event(id self, SEL selector, NSEvent *event) {
    mff_refresh_tcp_target(event);
    NSEvent *prior_input = mff_dispatch_input;
    NSEvent *prior_substitute = mff_dispatch_substitute;
    NSEvent *replacement = mff_single_tcp_click(event);
    mff_dispatch_input = event;
    mff_dispatch_substitute = replacement == event ? nil : replacement;
    @try {
        ((void (*)(id, SEL, NSEvent *))mff_original_send)(self, selector, replacement);
    } @finally {
        mff_dispatch_input = prior_input;
        mff_dispatch_substitute = prior_substitute;
    }
}

/* Called only when REAPER actually dispatches an F/LI custom action. */
void MFF_TCP_ButtonClickNoted(void) {
    NSEvent *event = mff_dispatch_input;
    if (!event || (event.type != NSEventTypeLeftMouseDown &&
                   event.type != NSEventTypeLeftMouseUp) || !event.window)
        return;
    mff_last_window = event.window;
    mff_last_point = event.locationInWindow;
    mff_last_time = event.timestamp;
}

void MFF_TCP_Start(void) {
    if (mff_app_class || !NSApp) return;
    Class cls = object_getClass(NSApp);
    Method send = class_getInstanceMethod(cls, @selector(sendEvent:));
    Method current = class_getInstanceMethod(cls, @selector(currentEvent));
    if (!send || !current) return;
    mff_original_send = method_getImplementation(send);
    mff_original_current = method_getImplementation(current);
    class_replaceMethod(cls, @selector(sendEvent:), (IMP)mff_send_event,
                        method_getTypeEncoding(send));
    class_replaceMethod(cls, @selector(currentEvent), (IMP)mff_current_event,
                        method_getTypeEncoding(current));
    mff_app_class = cls;
}

void MFF_TCP_Stop(void) {
    if (mff_app_class) {
        Method send = class_getInstanceMethod(mff_app_class, @selector(sendEvent:));
        Method current = class_getInstanceMethod(mff_app_class, @selector(currentEvent));
        if (send && method_getImplementation(send) == (IMP)mff_send_event)
            class_replaceMethod(mff_app_class, @selector(sendEvent:), mff_original_send,
                                method_getTypeEncoding(send));
        if (current && method_getImplementation(current) == (IMP)mff_current_event)
            class_replaceMethod(mff_app_class, @selector(currentEvent), mff_original_current,
                                method_getTypeEncoding(current));
    }
    mff_app_class = Nil;
    mff_last_window = nil;
    mff_dispatch_input = nil;
    mff_dispatch_substitute = nil;
}
