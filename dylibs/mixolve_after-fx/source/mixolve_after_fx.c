/*
 * mixolve_after-fx — native REAPER Main-section actions.
 * macOS ARM64. No SWS, Lua polling, or legacy command IDs.
 *
 * Only unlocked items with one or two takes are processed.
 * Always render from TAKE #1 (original) while old take #2, if any, is
 * still present. After the render succeeds, delete ONLY old take #2.
 * Final take order: [original take #1 (active), new rendered take #2].
 * Initial active take does not change the render source or final order.
 *
 * Locked items are never modified. Original item selection is restored.
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
static double (*r_GetMediaItemInfo_Value)(MediaItem *, const char *);
static void (*r_SelectAllMediaItems)(ReaProject *, bool);
static void (*r_SetMediaItemSelected)(MediaItem *, bool);
static bool (*r_ValidatePtr2)(ReaProject *, void *, const char *);
static void (*r_Main_OnCommand)(int, int);
static MediaItem_Take *(*r_GetTake)(MediaItem *, int);
static MediaItem_Take *(*r_GetActiveTake)(MediaItem *);
static void (*r_SetActiveTake)(MediaItem_Take *);
static void (*r_Undo_BeginBlock2)(ReaProject *);
static void (*r_Undo_EndBlock2)(ReaProject *, const char *, int);
static void (*r_UpdateArrange)(void);
static void (*r_ShowConsoleMsg)(const char *); /* optional diagnostics */

static bool processing = false;
static int action_stereo = 0;
static int action_mono = 0;

static custom_action_register_t action_reg_stereo = {
    0, "MIXOLVE_AFTERFX_STEREO", "mixolve_after-fx: stereo", NULL
};
static custom_action_register_t action_reg_mono = {
    0, "MIXOLVE_AFTERFX_MONO", "mixolve_after-fx: mono", NULL
};

static bool still_valid(ReaProject *project, MediaItem *item) {
    return item && r_ValidatePtr2(project, item, "MediaItem*");
}

/* REAPER SDK: C_LOCK is a bitmask; bit 0 is the item-lock flag. */
static bool is_unlocked(ReaProject *project, MediaItem *item) {
    return still_valid(project, item) &&
           (((int)r_GetMediaItemInfo_Value(item, "C_LOCK") & 1) == 0);
}

/* Retain the take pointers so that cleanup cannot remove the new render. */
typedef struct ItemState {
    MediaItem *item;
    MediaItem_Take *original_active;
    MediaItem_Take *first;
    MediaItem_Take *old_second;
    MediaItem_Take *rendered_take;
    int initial_take_count;
    bool render_ready;
    bool rendered;
    bool cleanup_ready;
} ItemState;

/* Restore the user's item selection, including locked and skipped items. */
static void select_saved_items(ReaProject *project, ItemState *states, int n) {
    r_SelectAllMediaItems(project, false);
    for (int i = 0; i < n; ++i)
        if (still_valid(project, states[i].item))
            r_SetMediaItemSelected(states[i].item, true);
}

static void warn_take_layout(void) {
    if (r_ShowConsoleMsg)
        r_ShowConsoleMsg("mixolve_after-fx: unexpected take order; old takes retained where possible. Review the affected item.\n");
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
    if ((size_t)count > SIZE_MAX / sizeof(ItemState)) return;
    ItemState *states = (ItemState *)malloc((size_t)count * sizeof(*states));
    if (!states) return;

    bool any_supported = false;
    for (int i = 0; i < count; ++i) {
        ItemState *s = &states[i];
        s->item = r_GetSelectedMediaItem(project, i);
        s->original_active = NULL;
        s->first = NULL;
        s->old_second = NULL;
        s->rendered_take = NULL;
        s->initial_take_count = 0;
        s->render_ready = false;
        s->rendered = false;
        s->cleanup_ready = false;
        if (is_unlocked(project, s->item)) {
            int n = r_CountTakes(s->item);
            if (n == 1 || n == 2) any_supported = true;
        }
    }
    if (!any_supported) {
        free(states);
        return;
    }

    processing = true;
    r_Undo_BeginBlock2(project);

    /* PHASE 1: SELECT TAKE #1. Never delete/switch to take #2 here.
       A previously active second take is also switched to take #1.
       Keep old take #2 INTACT until rendering is finished. */
    r_SelectAllMediaItems(project, false);
    for (int i = 0; i < count; ++i) {
        ItemState *s = &states[i];
        if (!is_unlocked(project, s->item)) continue;
        s->initial_take_count = r_CountTakes(s->item);
        if (s->initial_take_count != 1 && s->initial_take_count != 2)
            continue; /* Ignore 0 or 3+ takes. */

        s->original_active = r_GetActiveTake(s->item);
        s->first = r_GetTake(s->item, 0);
        if (s->initial_take_count == 2)
            s->old_second = r_GetTake(s->item, 1);
        if (!s->first || (s->initial_take_count == 2 && !s->old_second))
            continue;

        r_SetActiveTake(s->first);
        if (r_GetActiveTake(s->item) != s->first) {
            /* Inability to select take #1 must never render the wrong take. */
            if (s->original_active &&
                r_ValidatePtr2(project, s->original_active, "MediaItem_Take*"))
                r_SetActiveTake(s->original_active);
            continue;
        }
        s->render_ready = true;
        r_SetMediaItemSelected(s->item, true);
    }

    /* PHASE 2: Render take #1. Old take #2 is still present and untouched.
       REAPER's Apply FX creates a new active take in the selected items. */
    if (r_CountSelectedMediaItems(project) > 0)
        r_Main_OnCommand(apply_action, 0);

    /* PHASE 3: Only select old take #2 for deletion after confirming that
       exactly one new active take was appended. Failed renders preserve both
       old takes, including the previously active take. */
    r_SelectAllMediaItems(project, false);
    for (int i = 0; i < count; ++i) {
        ItemState *s = &states[i];
        if (!s->render_ready || !is_unlocked(project, s->item)) continue;

        int after = r_CountTakes(s->item);
        MediaItem_Take *new_take = r_GetTake(s->item, s->initial_take_count);
        s->rendered = (after == s->initial_take_count + 1 && new_take &&
                       r_GetActiveTake(s->item) == new_take &&
                       r_GetTake(s->item, 0) == s->first &&
                       (s->initial_take_count == 1 ||
                        r_GetTake(s->item, 1) == s->old_second));
        if (!s->rendered) {
            if (s->original_active &&
                r_ValidatePtr2(project, s->original_active, "MediaItem_Take*"))
                r_SetActiveTake(s->original_active);
            if (after != s->initial_take_count) warn_take_layout();
            continue;
        }
        s->rendered_take = new_take;
        if (s->initial_take_count == 1) continue; /* No old #2 to remove. */

        /* Selection for Delete Active Take is separate from render selection. */
        r_SetActiveTake(s->old_second);
        if (r_GetActiveTake(s->item) != s->old_second) {
            r_SetActiveTake(s->first);
            warn_take_layout();
            continue;
        }
        s->cleanup_ready = true;
        r_SetMediaItemSelected(s->item, true);
    }

    /* PHASE 4: Delete ONLY old take #2, AFTER rendering.
       The newly rendered take must never be the deletion target. */
    if (r_CountSelectedMediaItems(project) > 0) {
        r_Main_OnCommand(ACT_DELETE_ACTIVE_TAKE, 0);
        r_Main_OnCommand(ACT_REMOVE_EMPTY_TAKES, 0);
    }

    /* PHASE 5: Make the ORIGINAL first take active in the final result.
       A successful item should have [old first, new rendered] in this order. */
    for (int i = 0; i < count; ++i) {
        ItemState *s = &states[i];
        if (!s->rendered || !is_unlocked(project, s->item)) continue;
        int expected_count = s->initial_take_count == 2 && !s->cleanup_ready
                                 ? 3 : 2;
        if (r_CountTakes(s->item) != expected_count ||
            r_GetTake(s->item, 0) != s->first ||
            r_GetTake(s->item, expected_count - 1) != s->rendered_take)
            warn_take_layout();
        if (r_GetTake(s->item, 0) == s->first)
            r_SetActiveTake(s->first);
        if (s->initial_take_count == 2 && s->cleanup_ready &&
            (r_CountTakes(s->item) != 2 ||
             r_GetTake(s->item, 1) != s->rendered_take))
            warn_take_layout();
    }

    select_saved_items(project, states, count);
    r_Undo_EndBlock2(project, apply_action == ACT_APPLY_FX_MONO
        ? "mixolve_after-fx: mono" : "mixolve_after-fx: stereo", 4);
    r_UpdateArrange();
    processing = false;
    free(states);
}

#include "fast_render.h"

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
    return dispatch_fast_action(command);
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
            unregister_fast_actions();
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
    LOAD(GetMediaItemInfo_Value);
    LOAD(SelectAllMediaItems);
    LOAD(SetMediaItemSelected);
    LOAD(ValidatePtr2);
    LOAD(Main_OnCommand);
    LOAD(GetTake);
    LOAD(GetActiveTake);
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
    register_fast_actions(info);
    register_plugin("ext_name", (void *)"mixolve_after-fx");
    return 1;
fail:
    if (action_mono > 0) register_plugin("-custom_action", (void *)&action_reg_mono);
    if (action_stereo > 0) register_plugin("-custom_action", (void *)&action_reg_stereo);
    register_plugin = NULL;
    action_stereo = action_mono = 0;
    return 0;
}
