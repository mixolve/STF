#include "objc-hooks.hpp"

namespace mx {
bool HookRegistry::install(Class klass, SEL selector, IMP replacement) {
    if (!klass || !selector || !replacement) return false;
    for (const Record& entry : records)
        if (entry.klass == klass && entry.selector == selector) return false;
    Method method = class_getInstanceMethod(klass, selector);
    if (!method) return false;
    IMP previous = method_getImplementation(method);
    const char *encoding = method_getTypeEncoding(method);
    if (!previous || !encoding) return false;
    if (!class_addMethod(klass, selector, replacement, encoding))
        class_replaceMethod(klass, selector, replacement, encoding);
    records.push_back({klass, selector, previous, encoding});
    return true;
}
IMP HookRegistry::original(id object, SEL selector) const {
    if (!object || !selector) return nullptr;
    for (Class klass = object_getClass(object); klass; klass = class_getSuperclass(klass)) {
        for (const Record& entry : records)
            if (entry.klass == klass && entry.selector == selector) return entry.original;
    }
    return nullptr;
}
void HookRegistry::uninstall() {
    for (auto it=records.rbegin(); it!=records.rend(); ++it)
        class_replaceMethod(it->klass, it->selector, it->original, it->encoding);
    records.clear();
}
}
