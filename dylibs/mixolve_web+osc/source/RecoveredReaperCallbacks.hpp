#pragma once
#include <cstddef>

// Thin adapter around independently loaded REAPER functions. The SDK is only
// needed by ReaperEntry.mm; GUI and UDP use this testable interface.
struct RecoveredReaperCallbacks {
    int (*getToggleState)(int commandID) = nullptr;
    void (*runAction)(int commandID) = nullptr;
    int (*namedCommandLookup)(const char *name) = nullptr;
    bool (*enumerateAction)(size_t index, int *commandID, const char **name) = nullptr;
    const char *(*reverseNamedCommandLookup)(int commandID) = nullptr;
    void (*dockWindowAddEx)(void *view, const char *title, const char *identifier, bool show) = nullptr;
    void (*dockWindowRemove)(void *view) = nullptr;
    void (*dockWindowActivate)(void *view) = nullptr;
    void *(*createDockHost)() = nullptr;
    void (*destroyDockHost)(void *view) = nullptr;
    const char *(*getResourcePath)() = nullptr;
    const char *(*getExtState)(const char *section, const char *key) = nullptr;
    void (*setExtState)(const char *section, const char *key, const char *value, bool persist) = nullptr;
};
void installRecoveredReaperCallbacks(RecoveredReaperCallbacks callbacks);
RecoveredReaperCallbacks recoveredReaperCallbacks();
