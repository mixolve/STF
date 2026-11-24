#pragma once
#import <objc/runtime.h>
#include <vector>

// Reconstructed installMethod/originalMethod/uninstallMethods behavior.
// Only class/method identity and public Objective-C runtime APIs are used.
namespace mx {
using SwellAPI = void *(*)(const char *);
SwellAPI findSwellAPI();

class HookRegistry {
public:
    bool install(Class klass, SEL selector, IMP replacement);
    IMP original(id object, SEL selector) const;
    void uninstall();
    HookRegistry(const HookRegistry&) = delete;
    HookRegistry& operator=(const HookRegistry&) = delete;
    HookRegistry() = default;
private:
    struct Record { Class klass; SEL selector; IMP original; const char *encoding; };
    std::vector<Record> records;
};
}
