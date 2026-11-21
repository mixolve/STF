#pragma once
// Local, minimal REAPER extension ABI declarations for this reconstructed plug-in.
// Compatible with the public REAPER SDK layout (version 0x20E):
// https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h
// Only the structures used by ReaperEntry.mm are declared here.
// This is NOT the complete REAPER SDK.
#include <cstddef>
#include <cstdint>

struct HWND__;                // SWELL HWND is a pointer-sized opaque handle.
using HWND = HWND__ *;
struct KbdSectionInfo;         // Passed to API functions; never dereferenced here.

constexpr int REAPER_PLUGIN_VERSION = 0x20E;
#define REAPER_PLUGIN_DLL_EXPORT __attribute__((visibility("default")))
#define REAPER_PLUGIN_HINSTANCE void *
#define REAPER_PLUGIN_ENTRYPOINT ReaperPluginEntry

struct reaper_plugin_info_t {
    int caller_version;
    HWND hwnd_main;
    int (*Register)(const char *name, void *infostruct);
    void *(*GetFunc)(const char *name);
};

struct custom_action_register_t {
    int uniqueSectionId;
    const char *idStr;
    const char *name;
    void *extra;
};

static_assert(sizeof(void *) == 8, "This build requires a 64-bit target");
static_assert(offsetof(reaper_plugin_info_t, hwnd_main) == 8, "REAPER ABI mismatch");
static_assert(offsetof(reaper_plugin_info_t, Register) == 16, "REAPER ABI mismatch");
static_assert(offsetof(reaper_plugin_info_t, GetFunc) == 24, "REAPER ABI mismatch");
static_assert(sizeof(reaper_plugin_info_t) == 32, "REAPER ABI mismatch");
static_assert(offsetof(custom_action_register_t, idStr) == 8, "REAPER ABI mismatch");
static_assert(sizeof(custom_action_register_t) == 32, "REAPER ABI mismatch");
