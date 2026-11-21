/*
 * mixolve_after-fx — two native REAPER Main-section actions.
 * macOS ARM64. No SWS, Lua polling, or legacy command IDs.
 * v1.1: custom_action must be handled through hookcommand2 (SDK).
 *
 * Derived from the user-supplied Cycle Action:
 * if an item has >1 takes: cycle next, delete active, remove empty takes;
 * then apply track/take FX (stereo or mono) and activate take #1.
 *
 * Multi-take preparation is limited to those selected items with >1 takes.
 * This prevents deleting the only take from a single-take item when the
 * selection contains a mixture of single- and multi-take items.
 *
 * SDK ABI source: https://github.com/justinfrankel/reaper-sdk
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define REAPER_PLUGIN_VERSION 0x20E

/* Minimal SDK ABI declarations for macOS. */
typedef struct ReaProject ReaProject;
typedef struct MediaItem MediaItem;
typedef struct MediaItem_Take MediaItem_Take;
typedef struct reaper_plugin_info_t {
    int caller_version;
    void *hwnd_main;
    int (*Register)(const char *, void *);
    void *(*GetFunc)(const char *);
} reaper_plugin_info_t;
typedef struct custom_action_register_t {
    int uniqueSectionId;
    const char *idStr;
    const char *name;
    void *extra;
} custom_action_register_t;

enum {
    ACT_CYCLE_NEXT_TAKE = 42349,
    ACT_DELETE_ACTIVE_TAKE = 40129,
    ACT_REMOVE_EMPTY_TAKES = 41348,
    ACT_APPLY_FX_STEREO = 40209,
    ACT_APPLY_FX_MONO = 40361
};

static int (*register_plugin)(const char *, void *);
static ReaProject *(*r_EnumProjects)(int, char *, int);
static int (*r_CountSelectedMediaItems)(ReaProject *);
static MediaItem *(*r_GetSelectedMediaItem)(ReaProject *, int);
static int (*r_CountTakes)(MediaItem *);
static void (*r_SelectAllMediaItems)(ReaProject *, bool);
static void (*r_SetMediaItemSelected)(MediaItem *, bool);
static bool (*r_ValidatePtr2)(ReaProject *, void *, const char *);
static void (*r_Main_OnCommand)(int, int);
static MediaItem_Take *(*r_GetTake)(MediaItem *, int);
static void (*r_SetActiveTake)(MediaItem_Take *);
static void (*r_Undo_BeginBlock2)(ReaProject *);
static void (*r_Undo_EndBlock2)(ReaProject *, const char *, int);
static void (*r_UpdateArrange)(void);
static void (*r_ShowConsoleMsg)(const char *); /* optional diagnostics */

static bool processing = false;
static int action_stereo = 0;
static int action_mono = 0;

static custom_action_register_t action_reg_stereo = {
    0, "MIXOLVE_AFTER_FX_STEREO", "mixolve: After FX (Stereo)", NULL
};
static custom_action_register_t action_reg_mono = {
    0, "MIXOLVE_AFTER_FX_MONO", "mixolve: After FX (Mono)", NULL
};

static bool still_valid(ReaProject *project, MediaItem *item) {
    return item && r_ValidatePtr2(project, item, "MediaItem*");
}

/* Restore the original set of selected items (except any deleted by REAPER). */
static void select_saved_items(ReaProject *project, MediaItem **items, int n) {
    r_SelectAllMediaItems(project, false);
    for (int i = 0; i < n; ++i)
        if (still_valid(project, items[i])) r_SetMediaItemSelected(items[i], true);
}

static void run_after_fx(int apply_action) {
    if (processing) return;
    ReaProject *project = r_EnumProjects(-1, NULL, 0);
    if (!project) return;

    int count = r_CountSelectedMediaItems(project);
    if (count <= 0) {
        if (r_ShowConsoleMsg)
            r_ShowConsoleMsg("mixolve_after-fx: select at least one media item.\n");
        return;
    }
    /* One allocation for selected-item pointers and a flag for every item. */
    if ((size_t)count > (SIZE_MAX / sizeof(MediaItem *))) return;
    MediaItem **items = (MediaItem **)malloc((size_t)count * sizeof(*items));
    if (!items) return;
    bool any_multi = false;
    for (int i = 0; i < count; ++i) {
        items[i] = r_GetSelectedMediaItem(project, i);
        if (items[i] && r_CountTakes(items[i]) > 1) any_multi = true;
    }

    processing = true;
    r_Undo_BeginBlock2(project);

    if (any_multi) {
        /* Match the screenshot's conditional branch, but only for items
           that actually have multiple takes. Single-take items are safe. */
        r_SelectAllMediaItems(project, false);
        for (int i = 0; i < count; ++i) {
            MediaItem *item = items[i];
            if (still_valid(project, item) && r_CountTakes(item) > 1)
                r_SetMediaItemSelected(item, true);
        }
        r_Main_OnCommand(ACT_CYCLE_NEXT_TAKE, 0);
        r_Main_OnCommand(ACT_DELETE_ACTIVE_TAKE, 0);
        r_Main_OnCommand(ACT_REMOVE_EMPTY_TAKES, 0);
    }

    /* The FX-apply command acts on all originally selected surviving items. */
    select_saved_items(project, items, count);
    if (r_CountSelectedMediaItems(project) > 0)
        r_Main_OnCommand(apply_action, 0);

    /* Native replacement for Xenakios: Select first take in selected items. */
    for (int i = 0; i < count; ++i) {
        MediaItem *item = items[i];
        if (!still_valid(project, item)) continue;
        MediaItem_Take *first = r_GetTake(item, 0);
        if (first) r_SetActiveTake(first);
    }

    select_saved_items(project, items, count);
    r_Undo_EndBlock2(project, apply_action == ACT_APPLY_FX_MONO
        ? "mixolve: After FX (Mono)" : "mixolve: After FX (Stereo)", 4);
    r_UpdateArrange();
    processing = false;
    free(items);
}

/* Both dispatchers are needed: custom_action routes keyboard and Action List
 * invocations via hookcommand2; hookcommand covers Main_OnCommand callers. */
static bool dispatch_action(int command) {
    if (command == action_stereo && action_stereo > 0) {
        run_after_fx(ACT_APPLY_FX_STEREO);
        return true;
    }
    if (command == action_mono && action_mono > 0) {
        run_after_fx(ACT_APPLY_FX_MONO);
        return true;
    }
    return false;
}

static bool hook_command(int command, int flag) {
    (void)flag;
    return dispatch_action(command);
}

/* Exact REAPER hookcommand2 ABI: six arguments, bool return. */
static bool hook_command2(void *section, int command, int val, int valhw,
                          int relmode, void *hwnd) {
    (void)section; (void)val; (void)valhw;
    (void)relmode; (void)hwnd;
    return dispatch_action(command);
}

__attribute__((visibility("default")))
int ReaperPluginEntry(void *instance, reaper_plugin_info_t *info) {
    (void)instance;
    if (!info) {
        if (register_plugin) {
            register_plugin("-hookcommand2", (void *)hook_command2);
            register_plugin("-hookcommand", (void *)hook_command);
            register_plugin("-custom_action", (void *)&action_reg_mono);
            register_plugin("-custom_action", (void *)&action_reg_stereo);
        }
        register_plugin = NULL;
        action_stereo = action_mono = 0;
        return 0;
    }
    if (info->caller_version != REAPER_PLUGIN_VERSION ||
        !info->Register || !info->GetFunc) return 0;

#define LOAD(name) do { \
    r_##name = (__typeof__(r_##name))info->GetFunc(#name); \
    if (!r_##name) return 0; \
} while (0)
    LOAD(EnumProjects);
    LOAD(CountSelectedMediaItems);
    LOAD(GetSelectedMediaItem);
    LOAD(CountTakes);
    LOAD(SelectAllMediaItems);
    LOAD(SetMediaItemSelected);
    LOAD(ValidatePtr2);
    LOAD(Main_OnCommand);
    LOAD(GetTake);
    LOAD(SetActiveTake);
    LOAD(Undo_BeginBlock2);
    LOAD(Undo_EndBlock2);
    LOAD(UpdateArrange);
#undef LOAD

    r_ShowConsoleMsg = (void (*)(const char *))info->GetFunc("ShowConsoleMsg");
    register_plugin = info->Register;
    action_stereo = register_plugin("custom_action", (void *)&action_reg_stereo);
    if (action_stereo <= 0) goto fail;
    action_mono = register_plugin("custom_action", (void *)&action_reg_mono);
    if (action_mono <= 0) goto fail;
    if (!register_plugin("hookcommand", (void *)hook_command)) goto fail;
    if (!register_plugin("hookcommand2", (void *)hook_command2)) {
        register_plugin("-hookcommand", (void *)hook_command);
        goto fail;
    }
    register_plugin("ext_name", (void *)"mixolve_after-fx");
    return 1;
fail:
    if (action_mono > 0) register_plugin("-custom_action", (void *)&action_reg_mono);
    if (action_stereo > 0) register_plugin("-custom_action", (void *)&action_reg_stereo);
    register_plugin = NULL;
    action_stereo = action_mono = 0;
    return 0;
}
