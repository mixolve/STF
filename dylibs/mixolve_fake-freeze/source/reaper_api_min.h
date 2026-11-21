/* Minimal REAPER extension ABI declarations (macOS/Linux), matching
   REAPER SDK reaper_plugin.h, API version 0x20E.
   Source of ABI: https://github.com/justinfrankel/reaper-sdk
   This is an original minimal declaration set, not a bundled SDK header. */
#ifndef MFF_REAPER_API_MIN_H
#define MFF_REAPER_API_MIN_H

#include <stdbool.h>

typedef struct MediaTrack MediaTrack;
typedef struct MediaItem MediaItem;
typedef struct ReaProject ReaProject;
typedef struct KbdSectionInfo KbdSectionInfo;

typedef struct reaper_plugin_info_t {
    int caller_version;
    void *hwnd_main;
    int (*Register)(const char *name, void *infostruct);
    void *(*GetFunc)(const char *name);
} reaper_plugin_info_t;

typedef struct custom_action_register_t {
    int uniqueSectionId;
    const char *idStr;
    const char *name;
    void *extra;
} custom_action_register_t;

#define REAPER_PLUGIN_VERSION 0x20E

#endif
