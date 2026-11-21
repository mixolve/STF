/*
  mixolve_fake-freeze: native REAPER extension, 1.12 (macOS)

  Uses built-in REAPER action 41719 to render a stereo stem track within the
  exact time selection of the source items without
  invoking the native Freeze action (which conflicts with ARA).

  Original tracks remain in the project with their media and ARA FX
  edits. A GUID-linked state record is stored in REAPER's persistent P_EXT
  track attributes and survives saving/loading .RPP projects.

  Important: not an ARA integration, not a lossless freeze replacement for
  arbitrary routing. Test on a duplicate project first.
*/
#include "reaper_api_min.h"
#include <stddef.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <time.h>

#define MFF_RENDER_SELECTED_AREA_STEREO 41719
#define MFF_MAX_TRACKS 8192
#define MFF_MAX_SELECTION 128
#define MFF_MAX_TAIL_SECONDS 3600.0
#define MFF_GUID_SZ 64
#define MFF_STR_SZ 1024
#define MFF_SOURCE_KEY "P_EXT:MFF_SOURCE_GUID"
#define MFF_STEM_KEY   "P_EXT:MFF_STEM_GUID"
#define MFF_STATE_KEY  "P_EXT:MFF_SAVED_STATE"
#define MFF_PREF_SECTION "MelodyneFakeFreeze"
#define MFF_TAIL_KEY "TailSeconds"

/* Dynamically resolved REAPER API. Signatures from the REAPER SDK API docs. */
static int (*R_CountTracks)(ReaProject *);
static MediaTrack *(*R_GetTrack)(ReaProject *, int);
static int (*R_CountSelectedTracks)(ReaProject *);
static MediaTrack *(*R_GetSelectedTrack)(ReaProject *, int);
static bool (*R_GetSetMediaTrackInfo_String)(MediaTrack *, const char *, char *, bool);
static double (*R_GetMediaTrackInfo_Value)(MediaTrack *, const char *);
static bool (*R_SetMediaTrackInfo_Value)(MediaTrack *, const char *, double);
static int (*R_CountTrackMediaItems)(MediaTrack *);
static MediaItem *(*R_GetTrackMediaItem)(MediaTrack *, int);
static double (*R_GetMediaItemInfo_Value)(MediaItem *, const char *);
static void (*R_GetSet_LoopTimeRange2)(ReaProject *, bool, bool, double *, double *, bool);
static void (*R_Main_OnCommand)(int, int);
static int (*R_GetPlayState)(void);
static void (*R_SetTrackSelected)(MediaTrack *, bool);
static void (*R_DeleteTrack)(MediaTrack *);
static void (*R_TrackList_AdjustWindows)(bool);
static void (*R_UpdateArrange)(void);
static void (*R_Undo_BeginBlock2)(ReaProject *);
static void (*R_Undo_EndBlock2)(ReaProject *, const char *, int);
static int (*R_GetTrackColor)(MediaTrack *);
static void (*R_SetTrackColor)(MediaTrack *, int);
static int (*R_ShowMessageBox)(const char *, const char *, int);
static bool (*R_GetUserInputs)(const char *, int, const char *, char *, int);
static int (*R_GetProjExtState)(ReaProject *, const char *, const char *, char *, int);
static int (*R_SetProjExtState)(ReaProject *, const char *, const char *, const char *);
static void (*R_MarkProjectDirty)(ReaProject *);
static int (*R_TrackFX_GetCount)(MediaTrack *);
static bool (*R_TrackFX_GetEnabled)(MediaTrack *, int);
static void (*R_TrackFX_SetEnabled)(MediaTrack *, int, bool);
static bool (*R_TrackFX_GetOffline)(MediaTrack *, int);
static void (*R_TrackFX_SetOffline)(MediaTrack *, int, bool);
static int (*R_TrackFX_GetChainVisible)(MediaTrack *);
static void (*R_TrackFX_Show)(MediaTrack *, int, int);
static bool (*R_ValidatePtr2)(ReaProject *, void *, const char *);
/* Native TCP F/LI integration, carried over from mixolve_custom-view/freeze.cpp. */
static ReaProject *(*R_EnumProjects)(int, char *, int);
static MediaTrack *(*R_GetMasterTrack)(ReaProject *);
static MediaTrack *(*R_GetTrackFromPoint)(int, int, int *);
static void (*R_GetMousePosition)(int *, int *);
static bool (*R_IsTrackSelected)(MediaTrack *);
static void (*R_SetOnlyTrackSelected)(MediaTrack *);
static bool (*R_SetMediaItemInfo_Value)(MediaItem *, const char *, double);
static const char *(*R_GetLastColorThemeFile)(void);
static const char *(*R_GetResourcePath)(void);
static bool (*R_ThemeLayout_GetLayout)(const char *, int, char *, int);

/* Implemented by mixolve_fake_freeze_tcp.m, built into the same .dylib. */
extern void MFF_TCP_Start(void);
extern void MFF_TCP_Stop(void);
extern void MFF_TCP_ButtonClickNoted(void);


static int (*plugin_register_saved)(const char *, void *);
static int g_toggle_action_id;
static int g_tail_action_id;
static int g_tcp_freeze_action_id;
static int g_tcp_items_lock_action_id;
static bool g_tcp_button_busy;
static bool g_layout_updating;
static double g_last_layout_scan;
static double g_last_theme_probe;
static bool g_theme_supported;
static char g_probed_theme[1024];
static MediaTrack *g_tcp_selected[MFF_MAX_TRACKS];
static bool g_in_action;

static custom_action_register_t g_toggle_action = {
    0, "MFF_MELODYNE_FAKE_FREEZE_TOGGLE",
    "mixolve: Fake Freeze / Unfreeze (ARA-safe stem)", NULL
};
static custom_action_register_t g_tail_action = {
    0, "MFF_MELODYNE_SET_FREEZE_TAIL",
    "mixolve: Set Fake Freeze tail (seconds) [project]", NULL
};
/* These names are referenced by the user's existing WALTER theme.
   They must be registered as actual Main-section custom actions, rather than
   bare command_id records: the theme dispatches real actions by those IDs.
   Keeping the exact IDs avoids any theme edits. */
static custom_action_register_t g_tcp_freeze_action = {
    0, "MIXOLVE_TCP_FREEZE_TOGGLE", "mixolve: TCP button F (Fake Freeze)", NULL
};
static custom_action_register_t g_tcp_items_lock_action = {
    0, "MIXOLVE_TCP_ITEMS_LOCK_TOGGLE", "mixolve: TCP button LI (Lock items)", NULL
};

typedef struct ActionTask {
    char origin_guid[MFF_GUID_SZ];
    char stem_guid[MFF_GUID_SZ];
    bool unfreeze;
} ActionTask;

static MediaTrack *g_before[MFF_MAX_TRACKS];
static ActionTask g_tasks[MFF_MAX_SELECTION];
static MediaTrack *g_success[MFF_MAX_SELECTION];

/* Locale-independent nonnegative decimal parser: 2.5 and 2,5 are both accepted.
   Prevents huge accidental renders, non-finite values, exponents and trailing junk. */
static bool parse_tail_seconds(const char *text, double *seconds) {
    if (!text || !seconds) return false;
    const unsigned char *p = (const unsigned char *)text;
    while (isspace(*p)) ++p;
    double value = 0.0, fractional_divisor = 1.0;
    bool have_digit = false, after_decimal = false;
    for (; *p; ++p) {
        if (*p >= '0' && *p <= '9') {
            have_digit = true;
            int digit = *p - '0';
            if (!after_decimal) {
                value = value * 10.0 + digit;
                if (value > MFF_MAX_TAIL_SECONDS) return false;
            } else {
                fractional_divisor *= 10.0;
                value += digit / fractional_divisor;
            }
        } else if ((*p == '.' || *p == ',') && !after_decimal) {
            after_decimal = true;
        } else if (isspace(*p)) {
            while (isspace(*p)) ++p;
            if (*p) return false;
            break;
        } else return false;
    }
    if (!have_digit || !isfinite(value) || value > MFF_MAX_TAIL_SECONDS) return false;
    *seconds = value;
    return true;
}

/* Tail setting is PROJECT-local, persisted in the .RPP file.
   A missing value always means 0. An invalid stored value stops Freeze instead
   of silently falling back and rendering the wrong duration. */
static bool read_project_tail(double *seconds) {
    char input[64] = {0};
    int exists = R_GetProjExtState(NULL, MFF_PREF_SECTION, MFF_TAIL_KEY,
                                   input, (int)sizeof(input));
    if (exists <= 0) { *seconds = 0.0; return true; }
    input[sizeof(input) - 1] = 0;
    return parse_tail_seconds(input, seconds);
}

/* Separate Action List command. No per-render dialogs are ever displayed. */
static bool run_set_tail(void) {
    if (g_in_action) return true;
    g_in_action = true;
    double current = 0.0;
    if (!read_project_tail(&current)) {
        R_ShowMessageBox("Stored tail is invalid; enter a new value (0 to 3600).",
                         "mixolve_fake-freeze", 0);
        current = 0.0;
    }
    char input[64];
    snprintf(input, sizeof(input), "%.12g", current);
    if (!R_GetUserInputs("mixolve: Fake Freeze Tail", 1,
                         "Seconds after last item:", input, (int)sizeof(input))) {
        g_in_action = false; /* Cancel: no change to project settings. */
        return true;
    }
    input[sizeof(input) - 1] = 0;
    double seconds = 0.0;
    if (!parse_tail_seconds(input, &seconds)) {
        R_ShowMessageBox("Enter a number from 0 to 3600 seconds (e.g. 2.5).",
                         "mixolve: Fake Freeze - invalid tail", 0);
        g_in_action = false;
        return true;
    }
    char persisted[64];
    snprintf(persisted, sizeof(persisted), "%.12g", seconds);
    if (R_SetProjExtState(NULL, MFF_PREF_SECTION, MFF_TAIL_KEY, persisted) <= 0) {
        R_ShowMessageBox("Could not save tail seconds in current project.",
                         "mixolve_fake-freeze", 0);
    } else {
        R_MarkProjectDirty(NULL);
    }
    g_in_action = false;
    return true;
}

static bool text_same(const char *a, const char *b) { return strcmp(a, b) == 0; }

static bool get_string(MediaTrack *track, const char *key, char *out, size_t outsize) {
    if (!track || !out || outsize == 0) return false;
    out[0] = 0;
    /* REAPER API assumes the caller provides a large-enough buffer. */
    bool ok = R_GetSetMediaTrackInfo_String(track, key, out, false);
    out[outsize - 1] = 0;
    return ok;
}

static bool set_string(MediaTrack *track, const char *key, const char *value) {
    if (!track || !value) return false;
    char buf[MFF_STR_SZ];
    size_t n = strlen(value);
    if (n >= sizeof(buf)) return false;
    memcpy(buf, value, n + 1);
    return R_GetSetMediaTrackInfo_String(track, key, buf, true);
}

static bool get_guid(MediaTrack *track, char *out) {
    return get_string(track, "GUID", out, MFF_GUID_SZ) && out[0] == '{';
}

static MediaTrack *find_guid(const char *guid) {
    if (!guid || guid[0] != '{') return NULL;
    int n = R_CountTracks(NULL);
    for (int i = 0; i < n; ++i) {
        MediaTrack *track = R_GetTrack(NULL, i);
        char id[MFF_GUID_SZ];
        if (get_guid(track, id) && text_same(id, guid)) return track;
    }
    return NULL;
}

static bool valid(MediaTrack *track) {
    return track && R_ValidatePtr2(NULL, track, "MediaTrack*");
}

static void clear_selection(void) {
    int n = R_CountTracks(NULL);
    for (int i = 0; i < n; ++i) R_SetTrackSelected(R_GetTrack(NULL, i), false);
}

static bool snapshot_tracks(int *out_count) {
    int n = R_CountTracks(NULL);
    if (n < 0 || n >= MFF_MAX_TRACKS) return false;
    for (int i = 0; i < n; ++i) g_before[i] = R_GetTrack(NULL, i);
    *out_count = n;
    return true;
}

static MediaTrack *find_only_new_track(int before_count) {
    int after = R_CountTracks(NULL);
    if (after != before_count + 1) return NULL;
    MediaTrack *new_one = NULL;
    for (int i = 0; i < after; ++i) {
        MediaTrack *t = R_GetTrack(NULL, i);
        bool existed = false;
        for (int j = 0; j < before_count; ++j) {
            if (g_before[j] == t) { existed = true; break; }
        }
        if (!existed) {
            if (new_one) return NULL;
            new_one = t;
        }
    }
    return new_one;
}

/*
  State v5: mute; TCP visibility; mixer visibility; chain enabled;
            TCP height override; TCP height lock;
            per-FX enabled bits; per-FX offline bits.
  Decode v4 and earlier state as well, so existing frozen stems can unfreeze.
*/
static bool save_state(MediaTrack *src) {
    char state[MFF_STR_SZ];
    int mute = (int)R_GetMediaTrackInfo_Value(src, "B_MUTE");
    int tcp = (int)R_GetMediaTrackInfo_Value(src, "B_SHOWINTCP");
    int mixer = (int)R_GetMediaTrackInfo_Value(src, "B_SHOWINMIXER");
    int fx = R_GetMediaTrackInfo_Value(src, "I_FXEN") != 0;
    double raw_height = R_GetMediaTrackInfo_Value(src, "I_HEIGHTOVERRIDE");
    if (!isfinite(raw_height) || raw_height < 0 || raw_height > 1000000) return false;
    int height_override = (int)raw_height;
    int height_lock = R_GetMediaTrackInfo_Value(src, "B_HEIGHTLOCK") != 0;
    int fx_count = R_TrackFX_GetCount(src);
    if (fx_count < 0) return false;
    int len = snprintf(state, sizeof(state), "v5;%d;%d;%d;%d;%d;%d;",
                       mute, tcp, mixer, fx, height_override, height_lock);
    /* Two FX bitmaps plus a separator and terminating NUL. */
    if (len <= 0 || (size_t)len + 2 * (size_t)fx_count + 2 > sizeof(state))
        return false;
    for (int i = 0; i < fx_count; ++i)
        state[len + i] = R_TrackFX_GetEnabled(src, i) ? '1' : '0';
    state[len + fx_count] = ';';
    for (int i = 0; i < fx_count; ++i)
        state[len + fx_count + 1 + i] = R_TrackFX_GetOffline(src, i) ? '1' : '0';
    state[len + 2 * fx_count + 1] = 0;
    return set_string(src, MFF_STATE_KEY, state);
}

static bool valid_bits(const char *bits, int count) {
    if (!bits || count < 0 || strlen(bits) != (size_t)count) return false;
    for (int i = 0; i < count; ++i)
        if (bits[i] != '0' && bits[i] != '1') return false;
    return true;
}

static bool restore_state(MediaTrack *src) {
    char data[MFF_STR_SZ];
    if (!get_string(src, MFF_STATE_KEY, data, sizeof(data)) || !data[0]) return false;
    int mute = -1, tcp = -1, mixer = -1, fxen = 1;
    int height_override = 0, height_lock = 0;
    bool saved_height_present = false;
    bool fx_bits_present = false;
    const char *enabled_bits = NULL;
    const char *offline_bits = NULL;
    if (strncmp(data, "v5;", 3) == 0) {
        int offset = 0;
        if (sscanf(data, "v5;%d;%d;%d;%d;%d;%d;%n", &mute, &tcp, &mixer,
                   &fxen, &height_override, &height_lock, &offset) != 6 || offset <= 0)
            return false;
        char *sep = strchr(data + offset, ';');
        if (!sep) return false;
        *sep = 0;
        enabled_bits = data + offset;
        offline_bits = sep + 1;
        fx_bits_present = true;
        saved_height_present = true;
    } else if (strncmp(data, "v4;", 3) == 0) {
        int offset = 0;
        if (sscanf(data, "v4;%d;%d;%d;%d;%n", &mute, &tcp, &mixer, &fxen, &offset) != 4 || offset <= 0)
            return false;
        char *sep = strchr(data + offset, ';');
        if (!sep) return false;
        *sep = 0;
        enabled_bits = data + offset;
        offline_bits = sep + 1;
        fx_bits_present = true;
    } else if (strncmp(data, "v3;", 3) == 0) {
        if (sscanf(data, "v3;%d;%d;%d;%d;", &mute, &tcp, &mixer, &fxen) != 4)
            return false;
        char *bits = data;
        int sep = 0;
        while (*bits && sep < 5) { if (*bits == ';') ++sep; ++bits; }
        if (sep != 5) return false;
        enabled_bits = bits;
        fx_bits_present = true;
    } else if (strncmp(data, "v2;", 3) == 0) {
        if (sscanf(data, "v2;%d;%d;%d;%d", &mute, &tcp, &mixer, &fxen) != 4)
            return false;
    } else {
        /* Compatibility with older Lua state: mute;tcp;mixer;fxbits */
        if (sscanf(data, "%d;%d;%d;", &mute, &tcp, &mixer) != 3)
            return false;
        char *bits = data;
        int sep = 0;
        while (*bits && sep < 3) { if (*bits == ';') ++sep; ++bits; }
        if (sep != 3) return false;
        enabled_bits = bits;
        fx_bits_present = true;
    }
    if ((mute != 0 && mute != 1) || (tcp != 0 && tcp != 1) ||
        (mixer != 0 && mixer != 1) || (fxen != 0 && fxen != 1) ||
        (saved_height_present && (height_override < 0 || height_override > 1000000 ||
                                  (height_lock != 0 && height_lock != 1))))
        return false;

    int n = R_TrackFX_GetCount(src);
    /* Validate the full metadata BEFORE touching the original track. */
    if (n < 0 || (fx_bits_present && !valid_bits(enabled_bits, n)) ||
        (offline_bits && !valid_bits(offline_bits, n)))
        return false;
    if (offline_bits) {
        for (int i = 0; i < n; ++i)
            R_TrackFX_SetOffline(src, i, offline_bits[i] == '1');
    }
    if (fx_bits_present) {
        for (int i = 0; i < n; ++i)
            R_TrackFX_SetEnabled(src, i, enabled_bits[i] == '1');
    }
    R_SetMediaTrackInfo_Value(src, "I_FXEN", fxen);
    R_SetMediaTrackInfo_Value(src, "B_MUTE", mute);
    R_SetMediaTrackInfo_Value(src, "B_SHOWINTCP", tcp);
    R_SetMediaTrackInfo_Value(src, "B_SHOWINMIXER", mixer);
    if (saved_height_present) {
        /* The height lock must be cleared before changing the override. */
        R_SetMediaTrackInfo_Value(src, "B_HEIGHTLOCK", 0);
        R_SetMediaTrackInfo_Value(src, "I_HEIGHTOVERRIDE", height_override);
        R_SetMediaTrackInfo_Value(src, "B_HEIGHTLOCK", height_lock);
    }
    /* Do not delete the rendered track unless the offline flags are restored. */
    if (offline_bits) {
        for (int i = 0; i < n; ++i)
            if (R_TrackFX_GetOffline(src, i) != (offline_bits[i] == '1'))
                return false;
    }
    return true;
}

/* Compute the occupied region, including gaps. Caller extends the end by the
   user-requested tail; REAPER may append additional render tails if enabled. */
static bool item_time_bounds(MediaTrack *src, double *out_start, double *out_end) {
    int n = R_CountTrackMediaItems(src);
    bool found = false;
    double first = 0.0, last = 0.0;
    if (n <= 0) return false;
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(src, i);
        if (!item) return false;
        double pos = R_GetMediaItemInfo_Value(item, "D_POSITION");
        double len = R_GetMediaItemInfo_Value(item, "D_LENGTH");
        if (!isfinite(pos) || !isfinite(len) || len <= 0.0 || !isfinite(pos + len))
            return false;
        if (!found || pos < first) first = pos;
        if (!found || pos + len > last) last = pos + len;
        found = true;
    }
    if (!found || last <= first) return false;
    *out_start = first;
    *out_end = last;
    return true;
}

/* Close the UI of FX #1 before rendering. A floating editor can remain visible
   even after the plug-in is bypassed. The FX chain window is closed only when
   it is displaying FX #1; the other FX editors are left alone. */
static void close_first_fx_window(MediaTrack *src) {
    if (R_TrackFX_GetCount(src) <= 0) return;
    R_TrackFX_Show(src, 0, 2); /* Hide floating window for first FX. */
    if (R_TrackFX_GetChainVisible(src) == 0)
        R_TrackFX_Show(src, 0, 0); /* Hide chain if first FX is shown. */
}

/* After the stem is rendered, always bypass the first FX without leaving it
   offline (regardless of plug-in type). All subsequent top-level FX go offline.
   Original enabled/offline flags are saved in v4 state for exact Unfreeze. */
static bool deactivate_fx_after_freeze(MediaTrack *src) {
    int n = R_TrackFX_GetCount(src);
    if (n < 0) return false;
    if (n > 0) {
        R_TrackFX_SetOffline(src, 0, false);
        R_TrackFX_SetEnabled(src, 0, false);
    }
    for (int i = 1; i < n; ++i)
        R_TrackFX_SetOffline(src, i, true);

    if (n > 0 && (R_TrackFX_GetOffline(src, 0) ||
                  R_TrackFX_GetEnabled(src, 0))) return false;
    for (int i = 1; i < n; ++i)
        if (!R_TrackFX_GetOffline(src, i)) return false;
    return true;
}

/* Activate LI on the *rendered stem* by locking every rendered item.
   Preserve all other C_LOCK flags, and leave source item states unchanged.
   TCP's layout updater reads this lock bit and shows LI as active. */
static bool lock_rendered_stem_items(MediaTrack *stem) {
    int n = R_CountTrackMediaItems(stem);
    if (n <= 0) return false;
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(stem, i);
        if (!item) return false;
        int flags = (int)R_GetMediaItemInfo_Value(item, "C_LOCK");
        if (!(flags & 1) &&
            !R_SetMediaItemInfo_Value(item, "C_LOCK", (double)(flags | 1)))
            return false;
    }
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(stem, i);
        if (!item || !((int)R_GetMediaItemInfo_Value(item, "C_LOCK") & 1))
            return false;
    }
    return true;
}

static const char *do_freeze(MediaTrack *src, double tail_seconds, MediaTrack **out) {
    char other[MFF_GUID_SZ], guid[MFF_GUID_SZ];
    get_string(src, MFF_STEM_KEY, other, sizeof(other));
    if (other[0]) return "Track is already Fake Frozen.";
    if ((int)R_GetMediaTrackInfo_Value(src, "I_FOLDERDEPTH") != 0)
        return "Folder boundary tracks are not supported.";
    if ((int)R_GetMediaTrackInfo_Value(src, "B_MUTE") != 0)
        return "Source track is muted. Unmute it first.";
    if ((int)R_GetMediaTrackInfo_Value(src, "I_SOLO") != 0)
        return "Source track is soloed. Unsolo it before rendering.";
    if ((int)R_GetMediaTrackInfo_Value(src, "I_RECARM") != 0)
        return "Source track is record-armed. Disarm it before rendering.";
    if ((int)R_GetMediaTrackInfo_Value(src, "I_AUTOMODE") > 1)
        return "Source automation is in write/touch/latch mode. Use trim/read.";
    if ((int)R_GetMediaTrackInfo_Value(src, "I_FXEN") == 0)
        return "Source track FX chain is bypassed. Enable it first.";
    if ((int)R_GetMediaTrackInfo_Value(src, "I_NCHAN") > 2)
        return "Track has more than two channels. Stereo stem would downmix it.";
    double render_start = 0.0, render_end = 0.0;
    if (!item_time_bounds(src, &render_start, &render_end))
        return "No valid media item time range on source track.";
    render_end += tail_seconds;
    if (!isfinite(render_end) || render_end <= render_start)
        return "Invalid render end after adding tail.";
    if (!get_guid(src, guid)) return "Cannot read source track GUID.";

    /* Capture the visible TCP height BEFORE REAPER creates the stem: the new
       stem otherwise receives REAPER's default track height. I_TCPH is the
       displayed height (read-only), I_HEIGHTOVERRIDE is a manual override. */
    double raw_tcp_height = R_GetMediaTrackInfo_Value(src, "I_TCPH");
    double raw_override = R_GetMediaTrackInfo_Value(src, "I_HEIGHTOVERRIDE");
    int height_px = 0;
    if (isfinite(raw_tcp_height) && raw_tcp_height > 0 && raw_tcp_height <= 1000000)
        height_px = (int)(raw_tcp_height + 0.5);
    else if (isfinite(raw_override) && raw_override > 0 && raw_override <= 1000000)
        height_px = (int)(raw_override + 0.5);
    int height_locked = R_GetMediaTrackInfo_Value(src, "B_HEIGHTLOCK") != 0;

    /* Persist metadata before invoking the native render. */
    if (!save_state(src)) return "Cannot save track state.";
    int before_count = 0;
    if (!snapshot_tracks(&before_count)) {
        set_string(src, MFF_STATE_KEY, "");
        return "Too many tracks in the project.";
    }

    /* The selected-area stem action respects the time selection. Keep and restore
       the user's existing selection even when rendering produces no stem. */
    double old_start = 0.0, old_end = 0.0;
    R_GetSet_LoopTimeRange2(NULL, false, false, &old_start, &old_end, false);
    clear_selection();
    R_SetTrackSelected(src, true);
    R_GetSet_LoopTimeRange2(NULL, true, false, &render_start, &render_end, false);
    close_first_fx_window(src); /* Must happen before the native render. */
    R_Main_OnCommand(MFF_RENDER_SELECTED_AREA_STEREO, 0);
    R_GetSet_LoopTimeRange2(NULL, true, false, &old_start, &old_end, false);
    MediaTrack *stem = find_only_new_track(before_count);
    if (!stem || R_CountTrackMediaItems(stem) == 0) {
        /* Restore mute (REAPER's stem renderer may have changed it). */
        restore_state(src);
        set_string(src, MFF_STATE_KEY, "");
        /* Intentionally do not delete any orphan render track. */
        return "Render failed or no single stem created. No track was deleted.";
    }

    char stem_guid[MFF_GUID_SZ];
    if (!get_guid(stem, stem_guid)) {
        restore_state(src);
        set_string(src, MFF_STATE_KEY, "");
        return "Cannot read rendered stem GUID; orphan render was left untouched.";
    }

    /* Preserve exactly the source track name: no [FROZEN] suffix. */
    char name[MFF_STR_SZ];
    get_string(src, "P_NAME", name, sizeof(name));
    set_string(stem, "P_NAME", name);
    int color = R_GetTrackColor(src);
    if (color) R_SetTrackColor(stem, color);
    if (height_px > 0) {
        /* Copy the original's visible size and its height-lock preference. */
        R_SetMediaTrackInfo_Value(stem, "B_HEIGHTLOCK", 0);
        R_SetMediaTrackInfo_Value(stem, "I_HEIGHTOVERRIDE", height_px);
        R_SetMediaTrackInfo_Value(stem, "B_HEIGHTLOCK", height_locked);
    }

    /* Unlike native Freeze, render-stem items start unlocked. Lock them now
       so the existing TCP LI button displays its active state immediately
       after the next layout refresh. The original items remain untouched. */
    if (!lock_rendered_stem_items(stem)) {
        restore_state(src);
        set_string(src, MFF_STATE_KEY, "");
        return "Could not lock rendered stem items; source restored, render left untouched.";
    }

    if (!set_string(src, MFF_STEM_KEY, stem_guid) ||
        !set_string(stem, MFF_SOURCE_KEY, guid)) {
        set_string(src, MFF_STEM_KEY, "");
        set_string(stem, MFF_SOURCE_KEY, "");
        restore_state(src);
        set_string(src, MFF_STATE_KEY, "");
        return "Could not save origin/stem links. Rendered track left intact.";
    }

    /* The renderer may have bypassed FX; restore their enabled state first. */
    if (!restore_state(src) || !deactivate_fx_after_freeze(src)) {
        set_string(src, MFF_STEM_KEY, "");
        set_string(stem, MFF_SOURCE_KEY, "");
        restore_state(src);
        set_string(src, MFF_STATE_KEY, "");
        return "Could not set FX bypass/offline; source restored and stem left untouched.";
    }
    R_SetMediaTrackInfo_Value(src, "B_MUTE", 1);
    R_SetMediaTrackInfo_Value(src, "B_SHOWINTCP", 0);
    R_SetMediaTrackInfo_Value(src, "B_SHOWINMIXER", 0);
    *out = stem;
    return NULL;
}

static const char *do_unfreeze(MediaTrack *source, MediaTrack *stem, MediaTrack **out) {
    if (!valid(source) || !valid(stem)) return "Source or stem has been removed.";
    char expected_stem[MFF_GUID_SZ], expected_source[MFF_GUID_SZ];
    char actual_source[MFF_GUID_SZ], actual_stem[MFF_GUID_SZ];
    get_string(source, MFF_STEM_KEY, expected_stem, sizeof(expected_stem));
    get_string(stem, MFF_SOURCE_KEY, expected_source, sizeof(expected_source));
    if (!get_guid(source, actual_source) || !get_guid(stem, actual_stem))
        return "Could not verify GUIDs; nothing deleted.";
    if (!text_same(expected_stem, actual_stem) ||
        !text_same(expected_source, actual_source))
        return "Source/stem link mismatch; nothing deleted.";
    char state[MFF_STR_SZ];
    get_string(source, MFF_STATE_KEY, state, sizeof(state));
    if (!state[0]) return "Saved source state missing; nothing deleted.";

    /* The rendered track is the user's visible, editable name while frozen.
       Read it before deleting the stem, and transfer it to the original only
       after the linked tracks and saved source state have been validated.
       An empty name is valid (an unnamed track). */
    char stem_name[MFF_STR_SZ];
    if (!get_string(stem, "P_NAME", stem_name, sizeof(stem_name)))
        return "Could not read frozen track name; nothing deleted.";
    if (!restore_state(source)) return "Saved source state invalid; nothing deleted.";
    if (!set_string(source, "P_NAME", stem_name))
        return "Could not synchronize frozen track name; stem was not deleted.";

    /* Only now that restoration and name sync succeeded do we delete the stem. */
    set_string(source, MFF_STEM_KEY, "");
    set_string(source, MFF_STATE_KEY, "");
    R_DeleteTrack(stem);
    *out = source;
    return NULL;
}

static bool run_toggle(void) {
    if (g_in_action) return true;
    g_in_action = true;
    if (R_GetPlayState() != 0) {
        R_ShowMessageBox("Stop playback/recording before Fake Freeze.", "mixolve_fake-freeze", 0);
        g_in_action = false; return true;
    }
    int count = R_CountSelectedTracks(NULL);
    if (count <= 0) {
        R_ShowMessageBox("Select source tracks to freeze or rendered stems to restore.",
                         "mixolve_fake-freeze", 0);
        g_in_action = false; return true;
    }
    if (count > MFF_MAX_SELECTION) {
        R_ShowMessageBox("Select 128 tracks or fewer at once.", "mixolve_fake-freeze", 0);
        g_in_action = false; return true;
    }

    int task_count = 0;
    for (int i = 0; i < count; ++i) {
        MediaTrack *selected = R_GetSelectedTrack(NULL, i);
        char source_guid[MFF_GUID_SZ], stem_guid[MFF_GUID_SZ];
        char own_guid[MFF_GUID_SZ];
        get_string(selected, MFF_SOURCE_KEY, source_guid, sizeof(source_guid));
        get_string(selected, MFF_STEM_KEY, stem_guid, sizeof(stem_guid));
        if (!get_guid(selected, own_guid)) continue;
        ActionTask task = { {0}, {0}, false };
        if (source_guid[0] == '{') {
            snprintf(task.origin_guid, sizeof(task.origin_guid), "%s", source_guid);
            snprintf(task.stem_guid, sizeof(task.stem_guid), "%s", own_guid);
            task.unfreeze = true;
        } else if (stem_guid[0] == '{') {
            snprintf(task.origin_guid, sizeof(task.origin_guid), "%s", own_guid);
            snprintf(task.stem_guid, sizeof(task.stem_guid), "%s", stem_guid);
            task.unfreeze = true;
        } else {
            snprintf(task.origin_guid, sizeof(task.origin_guid), "%s", own_guid);
        }
        bool duplicate = false;
        for (int j = 0; j < task_count; ++j) {
            if (text_same(task.origin_guid, g_tasks[j].origin_guid)) duplicate = true;
        }
        if (!duplicate) {
            g_tasks[task_count++] = task;
        }
    }

    if (!task_count) {
        R_ShowMessageBox("No eligible selected tracks.", "mixolve_fake-freeze", 0);
        g_in_action = false; return true;
    }

    /* Only Freeze needs the saved tail; Unfreeze never prompts or reads it. */
    double tail_seconds = 0.0;
    bool has_freeze = false;
    for (int i = 0; i < task_count; ++i)
        if (!g_tasks[i].unfreeze) { has_freeze = true; break; }
    if (has_freeze && !read_project_tail(&tail_seconds)) {
        R_ShowMessageBox("The project's stored tail is invalid. Run the Set Fake Freeze tail action.",
                         "mixolve_fake-freeze", 0);
        g_in_action = false;
        return true;
    }

    int ok_count = 0, error_count = 0;
    char errors[4096] = {0};
    R_Undo_BeginBlock2(NULL);
    for (int i = 0; i < task_count; ++i) {
        const ActionTask *task = &g_tasks[i];
        MediaTrack *origin = find_guid(task->origin_guid);
        MediaTrack *output = NULL;
        const char *err = NULL;
        if (task->unfreeze) {
            err = do_unfreeze(origin, find_guid(task->stem_guid), &output);
        } else if (valid(origin)) {
            err = do_freeze(origin, tail_seconds, &output);
        } else {
            err = "Source track no longer exists.";
        }
        if (!err && valid(output)) g_success[ok_count++] = output;
        else if (err) {
            ++error_count;
            size_t len = strlen(errors);
            if (len + strlen(err) + 4 < sizeof(errors)) {
                strcat(errors, "- "); strcat(errors, err); strcat(errors, "\n");
            }
        }
    }
    if (ok_count > 0) {
        clear_selection();
        for (int i = 0; i < ok_count; ++i)
            if (valid(g_success[i])) R_SetTrackSelected(g_success[i], true);
    }
    R_TrackList_AdjustWindows(false);
    R_UpdateArrange();
    R_Undo_EndBlock2(NULL, "mixolve: Fake Freeze / Unfreeze", -1);

    if (error_count) R_ShowMessageBox(errors[0] ? errors : "Some tracks could not be processed.",
                                      "mixolve: Fake Freeze - warnings", 0);
    g_in_action = false;
    return true;
}

/* All state/layout logic below was ported from the supplied custom-view
   freeze.cpp. Unlike native I_FREEZECOUNT, F now watches our GUID-linked stem. */
static double tcp_clock(void) {
    struct timespec t = {0, 0};
    return clock_gettime(CLOCK_MONOTONIC, &t) == 0
         ? (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0 : 0;
}

static bool tcp_strip(char *s, const char *prefix) {
    size_t n = strlen(prefix);
    if (strncmp(s, prefix, n)) return false;
    memmove(s, s + n, strlen(s + n) + 1);
    return true;
}

static bool tcp_supported_base(const char *name) {
    if (!name[0]) return true;
    static const char *sizes[] = {"", "50%_", "75%_", "150%_", "200%_", "default_"};
    for (int i = 0; i < 6; ++i) {
        for (char letter = 'A'; letter <= 'C'; ++letter) {
            char variant[40];
            snprintf(variant, sizeof(variant), "%s%c", sizes[i], letter);
            if (!strcmp(name, variant)) return true;
        }
    }
    return false;
}

static bool tcp_theme_supported(double now) {
    const char *theme = R_GetLastColorThemeFile();
    const char *res = R_GetResourcePath();
    if (!theme || !res) return false;
    char expected_a[1024], expected_b[1024];
    snprintf(expected_a, sizeof(expected_a), "%s/ColorThemes/deftweaked.ReaperTheme", res);
    snprintf(expected_b, sizeof(expected_b), "%s/ColorThemes/Default_7.0.ReaperThemeZip", res);
    if (!strcmp(theme, expected_a) || !strcmp(theme, expected_b)) return true;
    if (strcmp(theme, g_probed_theme) || now - g_last_theme_probe >= 1.0) {
        snprintf(g_probed_theme, sizeof(g_probed_theme), "%s", theme);
        g_last_theme_probe = now;
        bool frozen = false, locked = false, closed = false;
        for (int i = 0; i < 4096; ++i) {
            char name[1024] = {0};
            if (!R_ThemeLayout_GetLayout("tcp", i, name, (int)sizeof(name))) break;
            if (!strcmp(name, "CharonFrozen_default_A")) frozen = true;
            if (!strcmp(name, "CharonItemsLocked_default_A")) locked = true;
            if (!strcmp(name, "CharonClosed_default_A")) closed = true;
            if (frozen && locked && closed) break;
        }
        g_theme_supported = frozen && locked && closed;
    }
    return g_theme_supported;
}

static bool tcp_is_fake_frozen(MediaTrack *track) {
    char guid[MFF_GUID_SZ] = {0};
    return (get_string(track, MFF_SOURCE_KEY, guid, sizeof(guid)) && guid[0] == '{') ||
           (get_string(track, MFF_STEM_KEY, guid, sizeof(guid)) && guid[0] == '{');
}

/* REAPER calls the registered "timer" callback on the main thread. */
static void tcp_update_layouts(void) {
    if (g_tcp_button_busy || g_in_action || g_layout_updating) return;
    double now = tcp_clock();
    if (now - g_last_layout_scan < 0.05) return;
    g_last_layout_scan = now;
    ReaProject *owner = R_EnumProjects(-1, NULL, 0);
    if (!owner || !R_GetResourcePath() || !R_GetLastColorThemeFile()) return;
    bool supported = tcp_theme_supported(now);
    char default_name[1024] = {0};
    R_ThemeLayout_GetLayout("tcp", -1, default_name, (int)sizeof(default_name));
    size_t len = strlen(default_name);
    char letter = len && default_name[len - 1] >= 'A' && default_name[len - 1] <= 'C'
                ? default_name[len - 1] : 'A';

    g_layout_updating = true;
    bool changed = false;
    int count = R_CountTracks(owner);
    for (int i = 0; i < count; ++i) {
        MediaTrack *track = R_GetTrack(owner, i);
        char old[1024] = {0}, base[1024] = {0};
        if (!get_string(track, "P_TCP_LAYOUT", old, sizeof(old))) continue;
        snprintf(base, sizeof(base), "%s", old);
        bool was_locked = tcp_strip(base, "CharonItemsLocked_");
        bool was_frozen = tcp_strip(base, "CharonFrozen_");
        bool was_closed = tcp_strip(base, "CharonClosed_");
        if (!tcp_supported_base(base)) continue; /* Respect unrelated custom layouts. */
        if ((was_locked || was_frozen || was_closed) && !strncmp(base, "default_", 8))
            base[0] = 0;
        bool closed = supported && (int)R_GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1 &&
                      R_GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT") > 0;
        bool frozen = supported && tcp_is_fake_frozen(track);
        bool locked = false;
        if (supported) {
            int items = R_CountTrackMediaItems(track);
            locked = items > 0;
            for (int j = 0; j < items && locked; ++j) {
                MediaItem *item = R_GetTrackMediaItem(track, j);
                locked = item && (((int)R_GetMediaItemInfo_Value(item, "C_LOCK")) & 1);
            }
        }
        char wanted[1024] = {0};
        const char *stem = base;
        char default_variant[24];
        if (closed || frozen || locked) {
            if (!base[0]) {
                snprintf(default_variant, sizeof(default_variant), "default_%c", letter);
                stem = default_variant;
            }
        }
        snprintf(wanted, sizeof(wanted), "%s%s%s%s",
                 locked ? "CharonItemsLocked_" : "",
                 frozen ? "CharonFrozen_" : "",
                 closed ? "CharonClosed_" : "", stem);
        if (strcmp(old, wanted) && set_string(track, "P_TCP_LAYOUT", wanted)) changed = true;
    }
    if (changed) {
        R_TrackList_AdjustWindows(false);
        R_UpdateArrange();
    }
    g_layout_updating = false;
}

static MediaTrack *tcp_target_track(ReaProject *owner) {
    int x = 0, y = 0;
    R_GetMousePosition(&x, &y);
    MediaTrack *track = R_GetTrackFromPoint(x, y, NULL);
    if (!track) track = R_GetSelectedTrack(owner, 0);
    if (!track || track == R_GetMasterTrack(owner) || !R_ValidatePtr2(owner, track, "MediaTrack*"))
        return NULL;
    return track;
}

/* LI is read-only while Fake Freeze is active: its stem items are locked
   by do_freeze(), and clicking LI must never unlock them. The hidden original
   is guarded as well, so accidental mouse targeting cannot change its locks.
   This affects our TCP LI action only, not REAPER's built-in lock commands. */
static void tcp_toggle_item_locks(ReaProject *owner, MediaTrack *track) {
    if (tcp_is_fake_frozen(track)) return;
    int n = R_CountTrackMediaItems(track);
    if (n <= 0) return;
    bool all_locked = true;
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        if (!item || !(((int)R_GetMediaItemInfo_Value(item, "C_LOCK")) & 1)) {
            all_locked = false;
            break;
        }
    }
    R_Undo_BeginBlock2(owner);
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        if (!item) continue;
        int flags = (int)R_GetMediaItemInfo_Value(item, "C_LOCK");
        int requested = all_locked ? (flags & ~1) : (flags | 1);
        if (requested != flags) R_SetMediaItemInfo_Value(item, "C_LOCK", (double)requested);
    }
    R_Undo_EndBlock2(owner, all_locked ? "mixolve: Unlock track items" : "mixolve: Lock track items", 4);
    R_UpdateArrange();
}

/* F uses the fake-freeze engine, one mouse-targeted track only; it preserves
   the user's selection just as the original custom-view button did. */
static bool tcp_button_command(bool is_lock) {
    if (g_tcp_button_busy || g_in_action) return true;
    ReaProject *owner = R_EnumProjects(-1, NULL, 0);
    if (!owner) return true;
    MediaTrack *track = tcp_target_track(owner);
    if (!track) return true;
    MFF_TCP_ButtonClickNoted();
    g_tcp_button_busy = true;
    if (is_lock) {
        tcp_toggle_item_locks(owner, track);
    } else {
        int saved_count = 0;
        int tracks = R_CountTracks(owner);
        for (int i = 0; i < tracks && saved_count < MFF_MAX_TRACKS; ++i) {
            MediaTrack *candidate = R_GetTrack(owner, i);
            if (candidate && R_IsTrackSelected(candidate)) g_tcp_selected[saved_count++] = candidate;
        }
        MediaTrack *master = R_GetMasterTrack(owner);
        bool master_selected = master && R_IsTrackSelected(master);
        if (master) R_SetTrackSelected(master, false);
        clear_selection();
        R_SetTrackSelected(track, true);
        run_toggle();
        /* Rendering may have removed the original stem and changed track count.
           Only restore pointers known to be valid in the SAME open project. */
        bool same_open = false;
        for (int i = 0; ; ++i) {
            ReaProject *candidate = R_EnumProjects(i, NULL, 0);
            if (!candidate) break;
            if (candidate == owner) { same_open = true; break; }
        }
        if (same_open) {
            int current_count = R_CountTracks(owner);
            for (int i = 0; i < current_count; ++i)
                R_SetTrackSelected(R_GetTrack(owner, i), false);
            if (master && R_ValidatePtr2(owner, master, "MediaTrack*"))
                R_SetTrackSelected(master, master_selected);
            for (int i = 0; i < saved_count; ++i)
                if (R_ValidatePtr2(owner, g_tcp_selected[i], "MediaTrack*"))
                    R_SetTrackSelected(g_tcp_selected[i], true);
            R_UpdateArrange();
        }
    }
    g_tcp_button_busy = false;
    g_last_layout_scan = 0;
    g_last_theme_probe = 0;
    g_probed_theme[0] = 0;
    tcp_update_layouts();
    return true;
}

/* hookcommand runs for all Main-section commands, including WALTER
   custom buttons clicked with the mouse. hookcommand2 is only for actions
   triggered by key/MIDI events and does not cover these mouse clicks. */
static bool hook_command(int command, int flag) {
    (void)flag;
    if (command == g_toggle_action_id) return run_toggle();
    if (command == g_tail_action_id) return run_set_tail();
    if (command == g_tcp_freeze_action_id) return tcp_button_command(false);
    if (command == g_tcp_items_lock_action_id) return tcp_button_command(true);
    return false;
}

/* macOS REAPER native extension entrypoint. Called with rec==NULL on unload. */
__attribute__((visibility("default")))
int ReaperPluginEntry(void *hInstance, reaper_plugin_info_t *rec) {
    (void)hInstance;
    if (!rec) {
        if (plugin_register_saved) {
            MFF_TCP_Stop();
            plugin_register_saved("-timer", (void *)tcp_update_layouts);
            plugin_register_saved("-hookcommand", (void *)hook_command);
            plugin_register_saved("-custom_action", (void *)&g_tcp_items_lock_action);
            plugin_register_saved("-custom_action", (void *)&g_tcp_freeze_action);
            plugin_register_saved("-custom_action", (void *)&g_tail_action);
            plugin_register_saved("-custom_action", (void *)&g_toggle_action);
        }
        g_toggle_action_id = 0;
        g_tail_action_id = 0;
        g_tcp_freeze_action_id = 0;
        g_tcp_items_lock_action_id = 0;
        plugin_register_saved = NULL;
        return 0;
    }
    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->Register || !rec->GetFunc)
        return 0;

    /* No dynamic linker dependency on REAPER SDK or third-party extensions. */
#define LOAD(fn) do { R_##fn = (__typeof__(R_##fn))rec->GetFunc(#fn); if (!R_##fn) return 0; } while (0)
    LOAD(CountTracks); LOAD(GetTrack); LOAD(CountSelectedTracks); LOAD(GetSelectedTrack);
    LOAD(GetSetMediaTrackInfo_String); LOAD(GetMediaTrackInfo_Value);
    LOAD(SetMediaTrackInfo_Value); LOAD(CountTrackMediaItems); LOAD(GetTrackMediaItem);
    LOAD(GetMediaItemInfo_Value); LOAD(GetSet_LoopTimeRange2); LOAD(Main_OnCommand);
    LOAD(GetPlayState); LOAD(SetTrackSelected);
    LOAD(DeleteTrack); LOAD(TrackList_AdjustWindows); LOAD(UpdateArrange);
    LOAD(Undo_BeginBlock2); LOAD(Undo_EndBlock2); LOAD(GetTrackColor);
    LOAD(SetTrackColor); LOAD(ShowMessageBox); LOAD(GetUserInputs);
    LOAD(GetProjExtState); LOAD(SetProjExtState); LOAD(MarkProjectDirty);
    LOAD(TrackFX_GetCount);
    LOAD(TrackFX_GetEnabled); LOAD(TrackFX_SetEnabled);
    LOAD(TrackFX_GetOffline); LOAD(TrackFX_SetOffline); LOAD(ValidatePtr2);
    LOAD(TrackFX_Show); LOAD(TrackFX_GetChainVisible);
    LOAD(EnumProjects); LOAD(GetMasterTrack); LOAD(GetTrackFromPoint);
    LOAD(GetMousePosition); LOAD(IsTrackSelected); LOAD(SetOnlyTrackSelected);
    LOAD(SetMediaItemInfo_Value); LOAD(GetLastColorThemeFile);
    LOAD(GetResourcePath); LOAD(ThemeLayout_GetLayout);
#undef LOAD
    plugin_register_saved = rec->Register;
    g_toggle_action_id = plugin_register_saved("custom_action", &g_toggle_action);
    if (g_toggle_action_id <= 0) return 0;
    g_tail_action_id = plugin_register_saved("custom_action", &g_tail_action);
    if (g_tail_action_id <= 0) goto fail_tail;
    g_tcp_freeze_action_id = plugin_register_saved("custom_action", &g_tcp_freeze_action);
    if (g_tcp_freeze_action_id <= 0) goto fail_freeze;
    g_tcp_items_lock_action_id = plugin_register_saved("custom_action", &g_tcp_items_lock_action);
    if (g_tcp_items_lock_action_id <= 0) goto fail_lock;
    if (!plugin_register_saved("hookcommand", (void *)hook_command)) goto fail_hook;
    if (!plugin_register_saved("timer", (void *)tcp_update_layouts)) goto fail_timer;
    MFF_TCP_Start();
    tcp_update_layouts();
    plugin_register_saved("ext_name", (void *)"mixolve_fake-freeze");
    return 1;
fail_timer:
    plugin_register_saved("-hookcommand", (void *)hook_command);
fail_hook:
    plugin_register_saved("-custom_action", &g_tcp_items_lock_action);
fail_lock:
    plugin_register_saved("-custom_action", &g_tcp_freeze_action);
fail_freeze:
    plugin_register_saved("-custom_action", &g_tail_action);
fail_tail:
    plugin_register_saved("-custom_action", &g_toggle_action);
    g_tcp_freeze_action_id = g_tcp_items_lock_action_id = 0;
    g_toggle_action_id = g_tail_action_id = 0;
    plugin_register_saved = NULL;
    return 0;
}
