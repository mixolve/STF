// mixolve_custom-view: track-name mouse/key filtering only.
// Pass raw NSEvent keyboard data through unchanged so Russian/Cyrillic input
// reaches REAPER Action List's shortcut recorder exactly as macOS generated it.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

namespace {
bool (*mouseFilter)(NSEvent *) = nullptr;
Class appClass = Nil;
IMP originalSend = nullptr;

void sendEvent(id self, SEL selector, NSEvent *event) {
    if (mouseFilter && mouseFilter(event)) return;
    ((void (*)(id, SEL, NSEvent *))originalSend)(self, selector, event);
}
} // namespace

extern "C" void MixolveSetTCPNameMouseFilter(bool (*filter)(NSEvent *)) {
    mouseFilter = filter;
}

extern "C" void MixolveKeyboardStop() {
    mouseFilter = nullptr;
    if (!appClass) return;
    Method method = class_getInstanceMethod(appClass, @selector(sendEvent:));
    if (method && method_getImplementation(method) == (IMP)sendEvent)
        class_replaceMethod(appClass, @selector(sendEvent:), originalSend, method_getTypeEncoding(method));
    originalSend = nullptr;
    appClass = Nil;
}

extern "C" void MixolveKeyboardStart() {
    if (appClass || !NSApp) return;
    Class candidate = object_getClass(NSApp);
    Method method = class_getInstanceMethod(candidate, @selector(sendEvent:));
    if (!method) return;
    IMP previous = method_getImplementation(method);
    if (!previous || previous == (IMP)sendEvent) return;
    originalSend = previous;
    appClass = candidate;
    class_replaceMethod(appClass, @selector(sendEvent:), (IMP)sendEvent, method_getTypeEncoding(method));
}
