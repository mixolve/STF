// mixolve_custom-view: keyboard shortcuts in Cyrillic layouts.
// Convert only non-text Command/Control/Option shortcuts to the equivalent
// physical key in the current ASCII-capable layout. Ordinary Cyrillic text,
// IME composition and plugin/text-editor input remain untouched.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>

extern "C" void MixolveUpdateTCPVolumePointer(NSEvent *);
extern "C" void MixolveUpdateTCPVolumeScroll(NSEvent *,bool);

namespace {
bool (*mouseFilter)(NSEvent *) = nullptr;
Class appClass = Nil;
IMP originalSend = nullptr;
NSMutableDictionary<NSNumber *, NSString *> *normalizedKeys = nil;

bool containsCyrillic(NSString *text) {
    if (!text) return false;
    for (NSUInteger i = 0; i < text.length; ++i) {
        unichar ch = [text characterAtIndex:i];
        if ((ch >= 0x0400 && ch <= 0x052F) ||
            (ch >= 0x2DE0 && ch <= 0x2DFF) ||
            (ch >= 0xA640 && ch <= 0xA69F)) return true;
    }
    return false;
}

bool editingText(NSEvent *event) {
    NSResponder *responder = event.window.firstResponder;
    if (!responder) return false;
    if ([responder isKindOfClass:[NSTextView class]] ||
        [responder isKindOfClass:[NSTextField class]] ||
        [responder conformsToProtocol:@protocol(NSTextInputClient)]) return true;
    return false;
}

// The active Russian layout cannot be used to derive a Latin shortcut key.
// Ask macOS for the user's ASCII-capable layout, then translate the *same*
// hardware key code. Ignore Cmd/Ctrl/Option during character translation,
// but preserve these flags in the resulting NSEvent.
NSString *latinKeyForEvent(NSEvent *event) {
    TISInputSourceRef input = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    if (!input) return nil;
    CFDataRef data = (CFDataRef)TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData);
    NSString *result = nil;
    if (data && CFDataGetLength(data) >= (CFIndex)sizeof(UCKeyboardLayout)) {
        const UCKeyboardLayout *layout =
            reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(data));
        UInt32 keyModifiers = 0;
        if (event.modifierFlags & NSEventModifierFlagShift)
            keyModifiers |= (shiftKey >> 8);
        if (event.modifierFlags & NSEventModifierFlagCapsLock)
            keyModifiers |= (alphaLock >> 8);
        UInt32 deadKeyState = 0;
        UniChar chars[8] = {};
        UniCharCount length = 0;
        OSStatus status = UCKeyTranslate(layout, event.keyCode, kUCKeyActionDown,
            keyModifiers, LMGetKbdType(), kUCKeyTranslateNoDeadKeysMask,
            &deadKeyState, 8, &length, chars);
        if (status == noErr && length == 1 && chars[0] >= 0x21 && chars[0] <= 0x7E)
            result = [NSString stringWithCharacters:chars length:1];
    }
    CFRelease(input);
    return result;
}

NSEvent *shortcutEvent(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp)
        return event;

    NSNumber *key = @(event.keyCode);
    NSString *latin = nil;
    if (event.type == NSEventTypeKeyUp) {
        // Match the key-up to the rewritten key-down even if modifiers have
        // been released in the meantime.
        latin = normalizedKeys[key];
        [normalizedKeys removeObjectForKey:key];
    } else {
        if (!event.isARepeat) [normalizedKeys removeObjectForKey:key];
        NSEventModifierFlags mods = event.modifierFlags;
        bool shortcut = (mods & (NSEventModifierFlagCommand |
                                NSEventModifierFlagControl |
                                NSEventModifierFlagOption)) != 0;
        if (shortcut && !editingText(event) &&
            (containsCyrillic(event.charactersIgnoringModifiers) ||
             containsCyrillic(event.characters))) {
            latin = latinKeyForEvent(event);
            if (latin) normalizedKeys[key] = latin;
        }
    }
    if (!latin) return event;
    NSEvent *converted = [NSEvent keyEventWithType:event.type
        location:event.locationInWindow
        modifierFlags:event.modifierFlags
        timestamp:event.timestamp
        windowNumber:event.windowNumber
        context:event.context
        characters:latin
        charactersIgnoringModifiers:latin
        isARepeat:event.isARepeat
        keyCode:event.keyCode];
    return converted ?: event;
}

void sendEvent(id self, SEL selector, NSEvent *event) {
    if (!mouseFilter || !mouseFilter(event)) {
        NSEvent *forward = shortcutEvent(event);
        MixolveUpdateTCPVolumeScroll(forward, false);
        ((void (*)(id, SEL, NSEvent *))originalSend)(self, selector, forward);
        MixolveUpdateTCPVolumeScroll(forward, true);
    }
    // AppKit and SWELL can both reset the pointer during mouse dispatch.
    MixolveUpdateTCPVolumePointer(event);
}
} // namespace

extern "C" void MixolveSetTCPNameMouseFilter(bool (*filter)(NSEvent *)) {
    mouseFilter = filter;
}

extern "C" void MixolveKeyboardStop() {
    mouseFilter = nullptr;
    [normalizedKeys removeAllObjects];
    normalizedKeys = nil;
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
    normalizedKeys = [NSMutableDictionary dictionary];
    class_replaceMethod(appClass, @selector(sendEvent:), (IMP)sendEvent, method_getTypeEncoding(method));
}
