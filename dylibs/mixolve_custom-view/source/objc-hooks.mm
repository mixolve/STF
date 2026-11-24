#import <AppKit/AppKit.h>
#include "objc-hooks.hpp"
#include <dlfcn.h>

namespace mx {
SwellAPI findSwellAPI(){
 #if defined(__APPLE__)
 id delegate=NSApp.delegate;
 SEL selector=NSSelectorFromString(@"swellGetAPPAPIFunc");
 if(delegate&&[delegate respondsToSelector:selector]){
  IMP method=[delegate methodForSelector:selector];
  if(method){using Provider=void *(*)(id,SEL);
   void *api=((Provider)method)(delegate,selector);if(api)return (SwellAPI)api;}
 }
 #endif
 SwellAPI fn=(SwellAPI)dlsym(RTLD_DEFAULT,"SWELLAPI_GetFunc");
 if(fn)return fn;
 for(const char *name:{"libSwell.dylib","libSwell.so"}){
  void *lib=dlopen(name,RTLD_LAZY|RTLD_NOLOAD);
  if(lib&&(fn=(SwellAPI)dlsym(lib,"SWELLAPI_GetFunc")))return fn;
 }
 return nullptr;
}

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
