// mixolve_custom-view: keyboard shortcuts in Cyrillic layouts.
// Convert only non-text Command/Control/Option shortcuts to the equivalent
// physical key in the current ASCII-capable layout. Ordinary Cyrillic text,
// IME composition and text-editor input remain untouched.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#include "fx-windows.hpp"
#include "objc-hooks.hpp"
#include <cstdint>

extern "C" void MixolveUpdateTCPVolumePointer(NSEvent *);
extern "C" void MixolveUpdateTCPVolumeLayout(NSEvent *,bool);

namespace {
bool (*mouseFilter)(NSEvent *) = nullptr;
Class appClass = Nil;
IMP originalSend = nullptr;
NSMutableDictionary<NSNumber *, NSString *> *normalizedKeys = nil;
int (*shortcutRegister)(const char *, void *) = nullptr;
intptr_t (*swellSendMessage)(void *, unsigned int, uintptr_t, intptr_t) = nullptr;
__weak NSWindow *shortcutFXWindow = nil;
int fxCloseKey = -1;

// Prefix of SWELL MSG and the REAPER SDK accelerator_register_t layout.
struct ShortcutMessage { void *hwnd; unsigned int message; };
struct ShortcutAccelerator {
    int (*translate)(ShortcutMessage *, ShortcutAccelerator *);
    bool isLocal;
    void *user;
};

int routeFXShortcut(ShortcutMessage *msg, ShortcutAccelerator *) {
    NSWindow *target = shortcutFXWindow;
    if (!target || !msg || (msg->message != 0x0100 && msg->message != 0x0104)) return 0;
    id recipient = (__bridge id)msg->hwnd;
    if (recipient != target && !([recipient isKindOfClass:NSView.class] &&
                                 [(NSView *)recipient window] == target)) return 0;
    // REAPER resolves the shortcut against the current Main action table.
    return -666;
}
ShortcutAccelerator fxAccelerator{routeFXShortcut, true, nullptr};

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
    NSWindow *window = event.window ?: NSApp.keyWindow;
    NSResponder *responder = window.firstResponder;
    if ([responder isKindOfClass:NSTextView.class] ||
        [responder isKindOfClass:NSTextField.class]) return true;
    if (![responder conformsToProtocol:@protocol(NSTextInputClient)]) return false;
    id<NSTextInputClient> input = (id<NSTextInputClient>)responder;
    return input.hasMarkedText || input.selectedRange.location != NSNotFound;
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
    NSWindow *window = event.window ?: NSApp.keyWindow;
    NSEvent *converted = [NSEvent keyEventWithType:event.type
        location:event.locationInWindow
        modifierFlags:event.modifierFlags
        timestamp:event.timestamp
        windowNumber:window ? window.windowNumber : event.windowNumber
        context:nil
        characters:latin
        charactersIgnoringModifiers:latin
        isARepeat:event.isARepeat
        keyCode:event.keyCode];
    return converted ?: event;
}

bool isFXCloseShortcut(NSEvent *event) {
    constexpr NSEventModifierFlags keyModifiers = NSEventModifierFlagCommand |
        NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;
    return (event.modifierFlags & keyModifiers) == NSEventModifierFlagCommand &&
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"w"];
}

bool closeFXWithShortcut(NSWindow *window, NSEvent *event) {
    if (!swellSendMessage) return false;
    NSView *dialog = window.contentView;
    if (![dialog respondsToSelector:NSSelectorFromString(@"onSwellMessage:p1:p2:")]) return false;

    // REAPER handles Cmd+W in a dialog as WM_COMMAND / IDCANCEL.
    fxCloseKey = event.keyCode;
    [normalizedKeys removeObjectForKey:@(fxCloseKey)];
    swellSendMessage((__bridge void *)dialog, 0x0111, 2, 0);
    return true;
}

void sendEvent(id self, SEL selector, NSEvent *event) {
    if (fxCloseKey >= 0 && (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
        event.keyCode == fxCloseKey) {
        if (event.type == NSEventTypeKeyDown && event.isARepeat) return;
        fxCloseKey = -1;
        if (event.type == NSEventTypeKeyUp) return;
    }
    if (!mouseFilter || !mouseFilter(event)) {
        NSEvent *forward = shortcutEvent(event);
        NSWindow *fx = nil;
        if (forward != event && event.type == NSEventTypeKeyDown) {
            NSWindow *target = event.window ?: NSApp.keyWindow;
            if (target == NSApp.keyWindow && MixolveIsFXShortcutWindow(target)) {
                if (isFXCloseShortcut(forward)) {
                    if (closeFXWithShortcut(target, forward)) return;
                } else {
                    fx = target;
                }
            }
        }
        MixolveUpdateTCPVolumeLayout(forward, false);
        NSWindow *previousFX = shortcutFXWindow;
        shortcutFXWindow = fx;
        ((void (*)(id, SEL, NSEvent *))originalSend)(self, selector, forward);
        shortcutFXWindow = previousFX;
        switch (forward.type) {
            case NSEventTypeScrollWheel:
            case NSEventTypeLeftMouseDragged:
            case NSEventTypeLeftMouseUp:
            case NSEventTypeKeyDown:
                MixolveRefreshArrangeViewAfterInput();
                break;
            default: break;
        }
        MixolveUpdateTCPVolumeLayout(forward, true);
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
    if (shortcutRegister) shortcutRegister("-accelerator", &fxAccelerator);
    shortcutRegister = nullptr;
    swellSendMessage = nullptr;
    shortcutFXWindow = nil;
    fxCloseKey = -1;
    [normalizedKeys removeAllObjects];
    normalizedKeys = nil;
    if (!appClass) return;
    Method method = class_getInstanceMethod(appClass, @selector(sendEvent:));
    if (method && method_getImplementation(method) == (IMP)sendEvent)
        class_replaceMethod(appClass, @selector(sendEvent:), originalSend, method_getTypeEncoding(method));
    originalSend = nullptr;
    appClass = Nil;
}

extern "C" void MixolveKeyboardStart(ep::Info *info) {
    if (appClass || !NSApp) return;
    Class candidate = object_getClass(NSApp);
    Method method = class_getInstanceMethod(candidate, @selector(sendEvent:));
    if (!method) return;
    IMP previous = method_getImplementation(method);
    if (!previous || previous == (IMP)sendEvent) return;
    originalSend = previous;
    appClass = candidate;
    normalizedKeys = [NSMutableDictionary dictionary];
    if (info && info->reg && info->reg("accelerator", &fxAccelerator)) shortcutRegister = info->reg;
    if (auto swell = mx::findSwellAPI())
        swellSendMessage = reinterpret_cast<decltype(swellSendMessage)>(swell("SendMessage"));
    class_replaceMethod(appClass, @selector(sendEvent:), (IMP)sendEvent, method_getTypeEncoding(method));
}
