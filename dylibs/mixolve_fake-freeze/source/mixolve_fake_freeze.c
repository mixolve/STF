/*
  mixolve_fake-freeze: native REAPER extension, 1.9.1 (macOS)

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

#define MFF_RENDER_SELECTED_AREA_STEREO 41719
#define MFF_MAX_TRACKS 8192
#define MFF_MAX_SELECTION 128
#define MFF_MAX_TAIL_SECONDS 3600.0
#define MFF_GUID_SZ 64
#define MFF_STR_SZ 1024
#define MFF_SOURCE_KEY "P_EXT:MFF_SOURCE_GUID"
#define MFF_STEM_KEY   "P_EXT:MFF_STEM_GUID"
#define MFF_STATE_KEY  "P_EXT:MFF_SAVED_STATE"
#define MFF_ITEM_LOCK_KEY "P_EXT:MFF_FAKE_FREEZE_ORIG_LOCK"
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
static bool (*R_SetMediaItemInfo_Value)(MediaItem *, const char *, double);
static bool (*R_GetSetMediaItemInfo_String)(MediaItem *, const char *, char *, bool);
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
static int (*plugin_register_saved)(const char *, void *);
static int g_toggle_action_id;
static int g_tail_action_id;
static bool g_in_action;

static custom_action_register_t g_toggle_action = {
    0, "MIXOLVE_FAKE_FREEZE_TOGGLE",
    "mixolve_fake-freeze: fake freeze / unfreeze (ara-safe stem)", NULL
};
static custom_action_register_t g_tail_action = {
    0, "MIXOLVE_FAKE_FREEZE_SET_TAIL",
    "mixolve_fake-freeze: set fake freeze tail (seconds) [project]", NULL
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

/* REAPER's C_LOCK is a bit field: bit 0 means locked. Retain all other
   bits, restoring the exact original value on Unfreeze. Persistent P_EXT item
   data stores original values across REAPER sessions. */
static char g_lock_error[192];

static void lock_error(const char *stage, int item_index) {
    if (item_index >= 0)
        snprintf(g_lock_error, sizeof(g_lock_error),
                 "Could not restore item %d locks (%s); stem was not deleted.",
                 item_index + 1, stage);
    else
        snprintf(g_lock_error, sizeof(g_lock_error),
                 "Could not restore original item locks (%s); stem was not deleted.",
                 stage);
}

static bool item_lock_flags(MediaItem *item, int *flags) {
    if (!item || !flags) return false;
    double value = R_GetMediaItemInfo_Value(item, "C_LOCK");
    if (!isfinite(value) || value < -128 || value > 255 || value != (int)value)
        return false;
    *flags = (int)value;
    return true;
}

/* REAPER P_EXT setter return values alone cannot establish whether the
   requested change took effect. In particular, clearing an ext field with
   an empty string can return false even when the field is now empty.
   Always inspect the value returned by a new GET instead. */
static bool write_item_snapshot(MediaItem *item, const char *value) {
    if (!item || !value) return false;
    char written[MFF_STR_SZ];
    size_t n = strlen(value);
    if (n >= sizeof(written)) return false;
    memcpy(written, value, n + 1);
    (void)R_GetSetMediaItemInfo_String(item, MFF_ITEM_LOCK_KEY, written, true);
    char check[MFF_STR_SZ] = {0};
    (void)R_GetSetMediaItemInfo_String(item, MFF_ITEM_LOCK_KEY, check, false);
    check[sizeof(check) - 1] = 0;
    return strcmp(check, value) == 0;
}

/* A setter may report false despite applying a lock change. A readback is
   what determines whether continuing (or deleting a linked stem) is safe. */
static bool write_item_lock(MediaItem *item, int flags) {
    if (!item) return false;
    (void)R_SetMediaItemInfo_Value(item, "C_LOCK", (double)flags);
    int actual = 0;
    return item_lock_flags(item, &actual) && actual == flags;
}

static bool read_item_lock_snapshot(MediaItem *item, const char *track_guid,
                                    int *original, bool *found) {
    if (!item || !track_guid || !original || !found) return false;
    char buf[MFF_STR_SZ] = {0};
    bool ok = R_GetSetMediaItemInfo_String(item, MFF_ITEM_LOCK_KEY, buf, false);
    buf[sizeof(buf) - 1] = 0;
    if (!ok && buf[0]) return false;
    char prefix[MFF_GUID_SZ + 8];
    int len = snprintf(prefix, sizeof(prefix), "v1;%s;", track_guid);
    if (len <= 0 || (size_t)len >= sizeof(prefix)) return false;
    if (strncmp(buf, prefix, (size_t)len) != 0) {
        *found = false;
        return true; /* Older frozen projects or items added since Freeze. */
    }
    int lock = 0, consumed = 0;
    if (sscanf(buf + len, "%d%n", &lock, &consumed) != 1 ||
        consumed <= 0 || buf[len + consumed] != 0 ||
        lock < -128 || lock > 255)
        return false;
    *original = lock;
    *found = true;
    return true;
}

/* Prevalidate before changing ANY lock flags. Newly created items without
   a matching snapshot keep their current lock state. */
static bool validate_item_lock_snapshots(MediaTrack *track) {
    char guid[MFF_GUID_SZ];
    if (!get_guid(track, guid)) return false;
    int n = R_CountTrackMediaItems(track);
    if (n < 0) return false;
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        int original = 0, current = 0;
        bool found = false;
        if (!item || !item_lock_flags(item, &current) ||
            !read_item_lock_snapshot(item, guid, &original, &found))
            return false;
    }
    return true;
}

/* Restore original lock values, then remove their snapshots. Every mutation
   is read back before allowing stem deletion. If a genuine write fails,
   keep the stem and surviving metadata so Unfreeze can be retried safely. */
static bool restore_item_locks(MediaTrack *track) {
    g_lock_error[0] = 0;
    if (!validate_item_lock_snapshots(track)) {
        lock_error("invalid saved item data", -1);
        return false;
    }
    char guid[MFF_GUID_SZ];
    if (!get_guid(track, guid)) {
        lock_error("missing track GUID", -1);
        return false;
    }
    int n = R_CountTrackMediaItems(track);
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        int original = 0;
        bool found = false;
        if (!read_item_lock_snapshot(item, guid, &original, &found)) {
            lock_error("invalid lock snapshot", i);
            return false;
        }
        int current = 0;
        if (found && (!item_lock_flags(item, &current) ||
                      (current != original && !write_item_lock(item, original)))) {
            lock_error("C_LOCK write/readback failed", i);
            return false;
        }
    }
    /* All required lock flags were restored. Clear only snapshots belonging
       to this source track. An empty P_EXT setter return is not an error if
       a following getter confirms that the value is empty. */
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        int original = 0;
        bool found = false;
        if (!read_item_lock_snapshot(item, guid, &original, &found)) {
            lock_error("snapshot read during cleanup failed", i);
            return false;
        }
        if (found && !write_item_snapshot(item, "") &&
            !write_item_snapshot(item, "v2;restored")) {
            /* Some REAPER builds may reject empty P_EXT writes. A verified
               nonempty sentinel is equivalent: it cannot be interpreted as
               an active lock snapshot and a later Freeze can overwrite it. */
            lock_error("snapshot cleanup/readback failed", i);
            return false;
        }
    }
    return true;
}

static bool lock_track_items(MediaTrack *track) {
    char guid[MFF_GUID_SZ];
    if (!get_guid(track, guid)) return false;
    int n = R_CountTrackMediaItems(track);
    if (n <= 0) return false;
    /* Reject stale snapshots rather than overwriting an original value. */
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        int original = 0, current = 0;
        bool found = false;
        if (!item || !item_lock_flags(item, &current) ||
            !read_item_lock_snapshot(item, guid, &original, &found) || found)
            return false;
    }
    for (int i = 0; i < n; ++i) {
        MediaItem *item = R_GetTrackMediaItem(track, i);
        int original = 0;
        char state[MFF_GUID_SZ + 32];
        if (!item_lock_flags(item, &original)) goto rollback;
        int len = snprintf(state, sizeof(state), "v1;%s;%d", guid, original);
        if (len <= 0 || (size_t)len >= sizeof(state) ||
            !write_item_snapshot(item, state) ||
            !write_item_lock(item, original | 1))
            goto rollback;
    }
    for (int i = 0; i < n; ++i) {
        int current = 0;
        if (!item_lock_flags(R_GetTrackMediaItem(track, i), &current) ||
            !(current & 1)) goto rollback;
    }
    return true;
rollback:
    (void)restore_item_locks(track);
    return false;
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

    /* Keep the source track name without a generated freeze suffix. */
    char name[MFF_STR_SZ];
    get_string(src, "P_NAME", name, sizeof(name));
    set_string(stem, "P_NAME", name[0] ? name : "Track");
    int color = R_GetTrackColor(src);
    if (color) R_SetTrackColor(stem, color);
    if (height_px > 0) {
        /* Copy the original's visible size and its height-lock preference. */
        R_SetMediaTrackInfo_Value(stem, "B_HEIGHTLOCK", 0);
        R_SetMediaTrackInfo_Value(stem, "I_HEIGHTOVERRIDE", height_px);
        R_SetMediaTrackInfo_Value(stem, "B_HEIGHTLOCK", height_locked);
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
    /* Lock both the retained source items and the visible rendered stem.
       On failure restore both sets of locks and undo the source-state change;
       the unlinked rendered track is left in the project for inspection. */
    bool source_items_locked = lock_track_items(src);
    bool stem_items_locked = source_items_locked && lock_track_items(stem);
    if (!source_items_locked || !stem_items_locked) {
        /* A failed lock_track_items() already rolls back its own writes. */
        if (source_items_locked) restore_item_locks(src);
        set_string(src, MFF_STEM_KEY, "");
        set_string(stem, MFF_SOURCE_KEY, "");
        restore_state(src);
        set_string(src, MFF_STATE_KEY, "");
        return "Could not lock the source/stem items; source restored, render kept.";
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
    if (!validate_item_lock_snapshots(source))
        return "Saved item lock state invalid; nothing deleted.";
    if (!restore_state(source)) return "Saved source state invalid; nothing deleted.";
    if (!restore_item_locks(source))
        return g_lock_error[0] ? g_lock_error :
               "Could not restore original item locks; stem was not deleted.";

    /* Only now that restoration succeeded do we delete the linked stem. */
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

static bool hook_command(KbdSectionInfo *section, int command,
                         int val, int valhw, int relmode, void *hwnd) {
    (void)section; (void)val; (void)valhw; (void)relmode; (void)hwnd;
    if (command == g_toggle_action_id) return run_toggle();
    if (command == g_tail_action_id) return run_set_tail();
    return false;
}

/* macOS REAPER native extension entrypoint. Called with rec==NULL on unload. */
__attribute__((visibility("default")))
int ReaperPluginEntry(void *hInstance, reaper_plugin_info_t *rec) {
    (void)hInstance;
    if (!rec) {
        if (plugin_register_saved) {
            plugin_register_saved("-hookcommand2", (void *)hook_command);
            plugin_register_saved("-custom_action", (void *)&g_tail_action);
            plugin_register_saved("-custom_action", (void *)&g_toggle_action);
        }
        g_toggle_action_id = 0;
        g_tail_action_id = 0;
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
    LOAD(GetMediaItemInfo_Value); LOAD(SetMediaItemInfo_Value);
    LOAD(GetSetMediaItemInfo_String); LOAD(GetSet_LoopTimeRange2); LOAD(Main_OnCommand);
    LOAD(GetPlayState); LOAD(SetTrackSelected);
    LOAD(DeleteTrack); LOAD(TrackList_AdjustWindows); LOAD(UpdateArrange);
    LOAD(Undo_BeginBlock2); LOAD(Undo_EndBlock2); LOAD(GetTrackColor);
    LOAD(SetTrackColor); LOAD(ShowMessageBox); LOAD(GetUserInputs);
    LOAD(GetProjExtState); LOAD(SetProjExtState); LOAD(MarkProjectDirty);
    LOAD(TrackFX_GetCount);
    LOAD(TrackFX_GetEnabled); LOAD(TrackFX_SetEnabled);
    LOAD(TrackFX_GetOffline); LOAD(TrackFX_SetOffline); LOAD(ValidatePtr2);
    LOAD(TrackFX_Show); LOAD(TrackFX_GetChainVisible);
#undef LOAD
    plugin_register_saved = rec->Register;
    g_toggle_action_id = plugin_register_saved("custom_action", &g_toggle_action);
    if (g_toggle_action_id <= 0) return 0;
    g_tail_action_id = plugin_register_saved("custom_action", &g_tail_action);
    if (g_tail_action_id <= 0) {
        plugin_register_saved("-custom_action", &g_toggle_action);
        g_toggle_action_id = 0;
        return 0;
    }
    if (!plugin_register_saved("hookcommand2", (void *)hook_command)) {
        plugin_register_saved("-custom_action", &g_tail_action);
        plugin_register_saved("-custom_action", &g_toggle_action);
        g_toggle_action_id = 0;
        g_tail_action_id = 0;
        return 0;
    }
    plugin_register_saved("ext_name", (void *)"mixolve_fake-freeze");
    return 1;
}
