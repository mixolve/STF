/* Continuous per-track rendering for the two fast actions. */
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>

typedef struct MediaTrack MediaTrack;
typedef struct PCM_source PCM_source;

static MediaTrack *(*r_GetMediaItemTrack)(MediaItem *);
static double (*r_GetMediaTrackInfo_Value)(MediaTrack *, const char *);
static bool (*r_SetMediaTrackInfo_Value)(MediaTrack *, const char *, double);
static int (*r_GetTrackNumSends)(MediaTrack *, int);
static int (*r_CountTrackMediaItems)(MediaTrack *);
static int (*r_CountTracks)(ReaProject *);
static MediaTrack *(*r_GetTrack)(ReaProject *, int);
static double (*r_GetProjectLength)(ReaProject *);
static void (*r_GetSet_LoopTimeRange2)(ReaProject *, bool, bool, double *, double *, bool);
static MediaItem *(*r_GetTrackMediaItem)(MediaTrack *, int);
static int (*r_CountSelectedTracks2)(ReaProject *, bool);
static MediaTrack *(*r_GetSelectedTrack2)(ReaProject *, int, bool);
static void (*r_SetOnlyTrackSelected)(MediaTrack *);
static void (*r_SetTrackSelected)(MediaTrack *, bool);
static double (*r_GetSetProjectInfo)(ReaProject *, const char *, double, bool);
static int (*r_projectconfig_var_getoffs)(const char *, int *);
static void *(*r_projectconfig_var_addr)(ReaProject *, int);
static bool (*r_GetSetProjectInfo_String)(ReaProject *, const char *, char *, bool);
static void (*r_GetProjectPathEx)(ReaProject *, char *, int);
static int (*r_RecursiveCreateDirectory)(const char *, size_t);
static PCM_source *(*r_PCM_Source_CreateFromFile)(const char *);
static void (*r_PCM_Source_Destroy)(PCM_source *);
static int (*r_PCM_Source_BuildPeaks)(PCM_source *, int);
static void (*r_UpdateItemInProject)(MediaItem *);
static double (*r_GetMediaSourceLength)(PCM_source *, bool *);
static int (*r_GetMediaSourceNumChannels)(PCM_source *);
static int (*r_GetMediaSourceSampleRate)(PCM_source *);
static PCM_source *(*r_GetMediaItemTake_Source)(MediaItem_Take *);
static bool (*r_SetMediaItemTake_Source)(MediaItem_Take *, PCM_source *);
static MediaItem *(*r_AddMediaItemToTrack)(MediaTrack *);
static bool (*r_DeleteTrackMediaItem)(MediaTrack *, MediaItem *);
static MediaItem_Take *(*r_AddTakeToMediaItem)(MediaItem *);
static bool (*r_GetSetMediaItemInfo_String)(MediaItem *, const char *, char *, bool);
static bool (*r_SetMediaItemTakeInfo_Value)(MediaItem_Take *, const char *, double);
static bool (*r_GetSetMediaItemTakeInfo_String)(MediaItem_Take *, const char *, char *, bool);
static bool (*r_GetItemStateChunk)(MediaItem *, char *, int, bool);
static bool (*r_SetItemStateChunk)(MediaItem *, const char *, bool);
static bool (*r_SetMediaItemInfo_Value)(MediaItem *, const char *, double);

enum {
    ACT_ADD_EMPTY_TAKE_BEFORE = 41351,
    ACT_RENDER_RECENT_AUTO_CLOSE = 42230,
    /* REAPER's render dialog uses 0x3 for Selected tracks (stems).
       Action 42230 falls back to Master mix when this is only 0x2. */
    RENDER_SELECTED_STEMS = 0x3,
    RENDER_PRE_FADER = 8192,
    RENDER_TIME_SELECTION = 2,
    ITEM_CHUNK_SIZE = 1024 * 1024,
    RENDER_STRING_SIZE = 65536
};

static custom_action_register_t fast_actions[] = {
    {0, "MIXOLVE_AFTERFX_FAST_STEREO", "mixolve_after-fx: fast stereo", NULL},
    {0, "MIXOLVE_AFTERFX_FAST_MONO", "mixolve_after-fx: fast mono", NULL}
};
static int fast_action_ids[2];

typedef struct {
    const char *key;
    double value;
    double saved;
} RenderNumber;

typedef struct {
    const char *key;
    char *value;
    char saved[RENDER_STRING_SIZE];
} RenderString;

static int *get_int_project_config(ReaProject *project, const char *key) {
    int size = 0;
    int offset = r_projectconfig_var_getoffs(key, &size);
    if (offset <= 0 || size != sizeof(int)) return NULL;
    return r_projectconfig_var_addr(project, offset);
}

static bool render_fast_wav(ReaProject *project, char *directory, char *name,
                            double start, double end, int bounds, int channels,
                            const char **failure) {
    int *speed_mode = get_int_project_config(project, "projrenderlimit");
    int *speed_cap = get_int_project_config(project, "projrenderspeedcap");
    if (!speed_mode || !speed_cap) {
        *failure = "could not set full-speed offline rendering";
        return false;
    }

    RenderNumber numbers[] = {
        {"RENDER_SETTINGS", RENDER_SELECTED_STEMS | RENDER_PRE_FADER, 0},
        {"RENDER_BOUNDSFLAG", bounds, 0},
        {"RENDER_STARTPOS", start, 0},
        {"RENDER_ENDPOS", end, 0},
        {"RENDER_CHANNELS", channels, 0},
        {"RENDER_ADDTOPROJ", 0, 0},
        {"RENDER_TAILFLAG", 0, 0},
        {"RENDER_NORMALIZE", 0, 0},
        {"RENDER_DITHER", 16, 0}
    };
    char wav[] = "ZXZhdyAAAA=="; /* REAPER WAV sink, 32-bit floating point. */
    char empty[] = "";
    RenderString strings[] = {
        {"RENDER_FILE", directory, ""},
        {"RENDER_PATTERN", name, ""},
        {"RENDER_FORMAT", wav, ""},
        {"RENDER_FORMAT2", empty, ""}
    };
    const size_t number_count = sizeof(numbers) / sizeof(numbers[0]);
    const size_t string_count = sizeof(strings) / sizeof(strings[0]);
    for (size_t i = 0; i < number_count; ++i)
        numbers[i].saved = r_GetSetProjectInfo(project, numbers[i].key, 0, false);
    for (size_t i = 0; i < string_count; ++i)
        if (!r_GetSetProjectInfo_String(project, strings[i].key, strings[i].saved, false)) {
            *failure = strings[i].key;
            return false;
        }

    for (size_t i = 0; i < number_count; ++i)
        r_GetSetProjectInfo(project, numbers[i].key, numbers[i].value, true);
    bool configured = true;
    for (size_t i = 0; i < string_count; ++i)
        if (!r_GetSetProjectInfo_String(project, strings[i].key, strings[i].value, true)) {
            *failure = strings[i].key;
            configured = false;
        }

    if (configured) {
        const int previous_mode = *speed_mode;
        const int previous_cap = *speed_cap;
        *speed_mode = 0; /* Full-speed offline. */
        *speed_cap = 0;
        r_Main_OnCommand(ACT_RENDER_RECENT_AUTO_CLOSE, 0);
        *speed_mode = previous_mode;
        *speed_cap = previous_cap;
        const int settings = (int)r_GetSetProjectInfo(project, "RENDER_SETTINGS", 0, false);
        if ((settings & 0x3) != RENDER_SELECTED_STEMS) {
            *failure = "REAPER changed the render source away from selected track stems";
            configured = false;
        }
    }

    for (size_t i = 0; i < string_count; ++i)
        r_GetSetProjectInfo_String(project, strings[i].key, strings[i].saved, true);
    for (size_t i = 0; i < number_count; ++i)
        r_GetSetProjectInfo(project, numbers[i].key, numbers[i].saved, true);
    return configured;
}

static const char *const render_item_keys[] = {
    "D_VOL", "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO"
};

typedef struct {
    MediaItem *item;
    MediaTrack *track;
    MediaItem_Take *active;
    MediaItem_Take *first;
    MediaItem_Take *old_second;
    MediaItem_Take *rendered;
    char *chunk;
    double start;
    double end;
    double shared[sizeof(render_item_keys) / sizeof(render_item_keys[0])];
    bool changed;
} FastItem;

static int compare_fast_items(const void *left, const void *right) {
    const FastItem *a = left;
    const FastItem *b = right;
    if (a->track != b->track)
        return (uintptr_t)a->track < (uintptr_t)b->track ? -1 : 1;
    return (a->start > b->start) - (a->start < b->start);
}

static bool set_fast_item_playback(FastItem *item, bool neutral) {
    bool ok = true;
    for (size_t i = 0; i < sizeof(item->shared) / sizeof(item->shared[0]); ++i) {
        if (neutral)
            item->shared[i] = r_GetMediaItemInfo_Value(item->item, render_item_keys[i]);
        const double value = neutral ? (i == 0 ? 1 : 0) : item->shared[i];
        if (!r_SetMediaItemInfo_Value(item->item, render_item_keys[i], value))
            ok = false;
    }
    return ok;
}

static bool validate_fast_wav(const char *path, double duration, int channels) {
    PCM_source *source = r_PCM_Source_CreateFromFile(path);
    if (!source) return false;

    bool quarter_notes = false;
    double length = r_GetMediaSourceLength(source, &quarter_notes);
    int rate = r_GetMediaSourceSampleRate(source);
    int file_channels = r_GetMediaSourceNumChannels(source);
    /* REAPER can round the two render boundaries to the output sample grid. */
    bool valid = !quarter_notes && rate > 0 && file_channels == channels &&
                 isfinite(length) && length > 0 && length >= duration - 2.0 / rate;
    /* Build the shared source's waveform once, before opening it in each take. */
    if (valid && r_PCM_Source_BuildPeaks(source, 0) != 0) {
        while (r_PCM_Source_BuildPeaks(source, 1) > 0) {}
        r_PCM_Source_BuildPeaks(source, 2);
    }
    r_PCM_Source_Destroy(source);
    if (!valid && r_ShowConsoleMsg) {
        char message[256];
        snprintf(message, sizeof(message),
                 "mixolve_after-fx: WAV has %d channel(s) at %d Hz, %.6f s; expected %d channel(s), at least %.6f s.\n",
                 file_channels, rate, length, channels, duration);
        r_ShowConsoleMsg(message);
    }
    return valid;
}

static bool attach_fast_take(FastItem *item, const char *path, double start) {
    PCM_source *source = r_PCM_Source_CreateFromFile(path);
    if (!source) return false;

    /* Preserve the actual empty take slot on generated stem items. */
    item->rendered = !item->first && item->old_second
        ? item->old_second : r_AddTakeToMediaItem(item->item);
    if (!item->rendered) {
        r_PCM_Source_Destroy(source);
        return false;
    }
    item->changed = true;
    PCM_source *old_source = r_GetMediaItemTake_Source(item->rendered);
    if (!r_SetMediaItemTake_Source(item->rendered, source)) {
        r_PCM_Source_Destroy(source);
        return false;
    }
    if (old_source) r_PCM_Source_Destroy(old_source);

    char name[] = "After FX (fast)";
    r_GetSetMediaItemTakeInfo_String(item->rendered, "P_NAME", name, true);
    return r_SetMediaItemTakeInfo_Value(item->rendered, "D_STARTOFFS", item->start - start);
}

static const char stem_item_key[] = "P_EXT:mixolve_after_fx_stem";

static bool is_fast_stem_item(MediaItem *item) {
    char marker[RENDER_STRING_SIZE] = "";
    return r_GetSetMediaItemInfo_String(item, stem_item_key, marker, false) &&
           strcmp(marker, "1") == 0;
}

static bool activate_fast_first_take(const FastItem *item) {
    if (item->first) {
        r_SetActiveTake(item->first);
    } else if (!r_SetMediaItemInfo_Value(item->item, "I_CURTAKE", 0)) {
        return false;
    }
    return r_GetActiveTake(item->item) == item->first &&
           r_GetMediaItemInfo_Value(item->item, "I_CURTAKE") == 0;
}

static bool create_fast_stem_takes(MediaItem *item, double position, double length,
                                   const char *path, double source_start) {
    char marker[] = "1";
    if (!r_SetMediaItemInfo_Value(item, "D_POSITION", position) ||
        !r_SetMediaItemInfo_Value(item, "D_LENGTH", length) ||
        !r_SetMediaItemInfo_Value(item, "B_LOOPSRC", 0) ||
        !r_GetSetMediaItemInfo_String(item, stem_item_key, marker, true))
        return false;

    FastItem stem = {.item = item, .start = position};
    if (!attach_fast_take(&stem, path, source_start)) return false;
    r_SetActiveTake(stem.rendered);
    if (r_CountTakes(item) != 1 || r_GetActiveTake(item) != stem.rendered) return false;
    r_SetMediaItemSelected(item, true);
    r_Main_OnCommand(ACT_ADD_EMPTY_TAKE_BEFORE, 0);
    if (r_CountTakes(item) != 2 || r_GetTake(item, 0) ||
        r_GetTake(item, 1) != stem.rendered || !activate_fast_first_take(&stem))
        return false;

    r_UpdateItemInProject(item);
    return true;
}

static bool finish_fast_takes(ReaProject *project, FastItem *items, int count) {
    r_SelectAllMediaItems(project, false);
    bool has_old_takes = false;
    for (int i = 0; i < count; ++i) {
        FastItem *item = &items[i];
        if (!is_unlocked(project, item->item) || r_GetTake(item->item, 0) != item->first)
            return false;
        const bool replacing = item->first && item->old_second;
        if (r_CountTakes(item->item) != (replacing ? 3 : 2) ||
            r_GetTake(item->item, replacing ? 2 : 1) != item->rendered)
            return false;
        if (!replacing) continue;
        if (r_GetTake(item->item, 1) != item->old_second) return false;
        r_SetActiveTake(item->old_second);
        if (r_GetActiveTake(item->item) != item->old_second) return false;
        r_SetMediaItemSelected(item->item, true);
        has_old_takes = true;
    }
    if (has_old_takes) {
        r_Main_OnCommand(ACT_DELETE_ACTIVE_TAKE, 0);
        r_Main_OnCommand(ACT_REMOVE_EMPTY_TAKES, 0);
    }
    for (int i = 0; i < count; ++i) {
        FastItem *item = &items[i];
        if (r_CountTakes(item->item) != 2 || r_GetTake(item->item, 0) != item->first ||
            r_GetTake(item->item, 1) != item->rendered)
            return false;
        if (!activate_fast_first_take(item)) return false;
        r_UpdateItemInProject(item->item);
    }
    return true;
}

/* Folder depth changes identify the contiguous subtree, including nested folders. */
static bool get_child_item_bounds(ReaProject *project, MediaTrack *folder,
                                  double *start, double *end) {
    int depth = (int)r_GetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH");
    int first = (int)r_GetMediaTrackInfo_Value(folder, "IP_TRACKNUMBER");
    const int tracks = r_CountTracks(project);
    *start = INFINITY;
    *end = -INFINITY;
    for (int i = first; depth > 0 && i < tracks; ++i) {
        MediaTrack *child = r_GetTrack(project, i);
        if (!child) return false;
        int item_count = r_CountTrackMediaItems(child);
        for (int j = 0; j < item_count; ++j) {
            MediaItem *item = r_GetTrackMediaItem(child, j);
            if (!item) continue;
            const double position = r_GetMediaItemInfo_Value(item, "D_POSITION");
            const double length = r_GetMediaItemInfo_Value(item, "D_LENGTH");
            if (!isfinite(position) || !isfinite(position + length) || length <= 0)
                continue;
            *start = fmin(*start, position);
            *end = fmax(*end, position + length);
        }
        depth += (int)r_GetMediaTrackInfo_Value(child, "I_FOLDERDEPTH");
    }
    return *end > *start;
}

static bool render_fast_track(ReaProject *project, MediaTrack *track, FastItem *items,
                              int count, int channels, char *chunk_buffer,
                              const char **failure) {
    if (r_GetMediaTrackInfo_Value(track, "B_MUTE")) {
        *failure = "the track is muted";
        return false;
    }
    const bool has_receives = count && r_GetTrackNumSends(track, -1) > 0;
    for (int i = 0; i < count; ++i) {
        if (has_receives && items[i].first) {
            *failure = "the track has receives";
            return false;
        }
        if (i > 0 && items[i].start < items[i - 1].end - 1e-9) {
            *failure = "selected items overlap";
            return false;
        }
        *failure = "could not save the original item state";
        if (!r_GetItemStateChunk(items[i].item, chunk_buffer, ITEM_CHUNK_SIZE, false))
            return false;
        items[i].chunk = strdup(chunk_buffer);
        if (!items[i].chunk) return false;
    }

    double start = 0;
    double required_end = 0;
    int bounds = 0;
    if (count) {
        start = items[0].start;
        required_end = items[count - 1].end;
    } else {
        r_GetSet_LoopTimeRange2(project, false, false, &start, &required_end, false);
        if (required_end > start) {
            bounds = RENDER_TIME_SELECTION;
        } else if (!get_child_item_bounds(project, track, &start, &required_end)) {
            start = 0;
            required_end = r_GetProjectLength(project);
        }
        if (!isfinite(start) || !isfinite(required_end) || required_end <= start) {
            *failure = "there is no time range to render";
            return false;
        }
    }

    const double item_start = start;
    /* Item offsets use a sample-aligned origin. Allow REAPER to round the end
       without cutting into the last item. Explicit time selections use native bounds. */
    if (count) start = floor(start);
    if (!count && !bounds) start = floor(start * 1000.0) / 1000.0;
    double end = required_end;
    if (count) end = ceil(required_end + 0.01);
    if (!count && !bounds) end = ceil(required_end * 1000.0) / 1000.0;

    *failure = "could not create a unique render path in the project media directory";
    char media_path[PATH_MAX] = "";
    r_GetProjectPathEx(project, media_path, sizeof(media_path));
    if (!media_path[0]) return false;
    r_RecursiveCreateDirectory(media_path, 0);

    /* Put renders beside the project's other media so REAPER can clean them up. */
    uuid_t id;
    char suffix[37];
    uuid_generate_random(id);
    uuid_unparse_lower(id, suffix);
    char name[sizeof("Mixolve After FX-") + sizeof(suffix) - 1];
    snprintf(name, sizeof(name), "Mixolve After FX-%s", suffix);
    char path[PATH_MAX];
    int written = snprintf(path, sizeof(path), "%s/%s.wav", media_path, name);
    struct stat existing;
    if (written < 0 || (size_t)written >= sizeof(path) ||
        lstat(path, &existing) == 0 || errno != ENOENT)
        return false;

    *failure = "could not prepare track items";
    int track_item_count = count ? r_CountTrackMediaItems(track) : 0;
    MediaItem **muted = track_item_count ? calloc((size_t)track_item_count, sizeof(*muted)) : NULL;
    if (track_item_count && !muted) return false;
    int muted_count = 0;
    r_SelectAllMediaItems(project, false);
    r_SetOnlyTrackSelected(track);
    bool ready = true;
    for (int i = 0; i < count; ++i) {
        FastItem *item = &items[i];
        if (!is_unlocked(project, item->item) || !activate_fast_first_take(item))
            ready = false;
        if (!set_fast_item_playback(item, true)) ready = false;
        r_SetMediaItemSelected(item->item, true);
    }
    for (int i = 0; ready && i < track_item_count; ++i) {
        MediaItem *item = r_GetTrackMediaItem(track, i);
        if (!item || r_GetMediaItemInfo_Value(item, "B_UISEL") ||
            r_GetMediaItemInfo_Value(item, "B_MUTE"))
            continue;
        double position = r_GetMediaItemInfo_Value(item, "D_POSITION");
        if (position >= end || position + r_GetMediaItemInfo_Value(item, "D_LENGTH") <= start)
            continue;
        muted[muted_count++] = item;
        ready = r_SetMediaItemInfo_Value(item, "B_MUTE", 1);
    }
    /* The render action can apply track trim even with pre-fader stems set. */
    const double track_volume = r_GetMediaTrackInfo_Value(track, "D_VOL");
    const bool override_volume = ready && track_volume != 1.0;
    if (override_volume && !r_SetMediaTrackInfo_Value(track, "D_VOL", 1.0)) {
        *failure = "could not set the track fader to unity for rendering";
        ready = false;
    }
    bool success = ready && render_fast_wav(project, media_path, name, start, end, bounds, channels, failure);
    if (override_volume &&
        (!r_ValidatePtr2(project, track, "MediaTrack*") ||
         !r_SetMediaTrackInfo_Value(track, "D_VOL", track_volume))) {
        *failure = "could not restore the track fader";
        success = false;
    }
    if (success) {
        *failure = "REAPER did not produce the expected WAV in the project media directory";
        success = access(path, R_OK) == 0;
    }
    if (success) {
        *failure = "could not verify the rendered WAV";
        const double required_length = required_end - start - (count ? 0 : 0.002);
        success = validate_fast_wav(path, required_length, channels);
    }

    for (int i = 0; i < muted_count; ++i) {
        if (!still_valid(project, muted[i]) || !r_SetMediaItemInfo_Value(muted[i], "B_MUTE", 0)) {
            success = false;
            if (r_ShowConsoleMsg)
                r_ShowConsoleMsg("mixolve_after-fx: could not restore an item's mute state. Use Undo to inspect the result.\n");
        }
    }
    free(muted);

    for (int i = 0; i < count; ++i) {
        if (!set_fast_item_playback(&items[i], false)) {
            items[i].changed = true;
            success = false;
        }
    }
    if (success && count) {
        *failure = "could not attach the WAV as a new take";
        for (int i = 0; success && i < count; ++i)
            success = attach_fast_take(&items[i], path, start);
    }
    if (success && count) {
        *failure = "could not replace the old second take or restore the first as active";
        success = finish_fast_takes(project, items, count);
    }
    MediaItem *new_item = NULL;
    if (success && !count) {
        *failure = "could not create the item with an empty first take and a rendered second take";
        new_item = r_AddMediaItemToTrack(track);
        success = new_item && create_fast_stem_takes(new_item, item_start,
                                                     required_end - item_start, path, start);
    }
    if (success) return true;

    bool restored = !new_item || r_DeleteTrackMediaItem(track, new_item);
    for (int i = 0; i < count; ++i) {
        FastItem *item = &items[i];
        if (item->changed) {
            if (!still_valid(project, item->item) ||
                !r_SetItemStateChunk(item->item, item->chunk, false))
                restored = false;
        } else if (item->active && still_valid(project, item->item) &&
                   r_ValidatePtr2(project, item->active, "MediaItem_Take*")) {
            r_SetActiveTake(item->active);
        }
    }
    if (restored) {
        unlink(path);
        char peak_path[sizeof(path) + sizeof(".reapeaks") - 1];
        snprintf(peak_path, sizeof(peak_path), "%s.reapeaks", path);
        unlink(peak_path);
    } else if (r_ShowConsoleMsg) {
        r_ShowConsoleMsg("mixolve_after-fx: could not restore an item. Use Undo to inspect the result.\n");
    }
    return false;
}

static void report_fast_failure(ReaProject *project, MediaTrack *track, const char *failure) {
    if (!r_ShowConsoleMsg) return;
    char message[256];
    int track_number = r_ValidatePtr2(project, track, "MediaTrack*")
        ? (int)r_GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") : 0;
    snprintf(message, sizeof(message), "mixolve_after-fx: track %d, fast render stopped: %s.\n",
             track_number, failure);
    r_ShowConsoleMsg(message);
}

static void run_fast_after_fx(int channels) {
    if (processing) return;
    ReaProject *project = r_EnumProjects(-1, NULL, 0);
    if (!project) return;
    const int selected = r_CountSelectedMediaItems(project);
    const int selected_tracks = r_CountSelectedTracks2(project, true);
    const int target_tracks = selected ? 0 : r_CountSelectedTracks2(project, false);
    int candidate_count = selected;
    for (int i = 0; i < target_tracks; ++i) {
        MediaTrack *track = r_GetSelectedTrack2(project, i, false);
        if (!track) continue;
        int track_items = r_CountTrackMediaItems(track);
        if (track_items > INT_MAX - candidate_count) return;
        candidate_count += track_items;
    }
    if (!candidate_count && !target_tracks) {
        if (r_ShowConsoleMsg)
            r_ShowConsoleMsg("mixolve_after-fx: select media items or one or more tracks.\n");
        return;
    }

    MediaTrack **track_selection = calloc((size_t)selected_tracks + 1, sizeof(*track_selection));
    FastItem *items = candidate_count ? calloc((size_t)candidate_count, sizeof(*items)) : NULL;
    MediaItem **candidates = candidate_count ? calloc((size_t)candidate_count, sizeof(*candidates)) : NULL;
    char *chunk_buffer = candidate_count ? malloc(ITEM_CHUNK_SIZE) : NULL;
    if (!track_selection || (candidate_count && (!items || !candidates || !chunk_buffer)))
        goto cleanup;
    for (int i = 0; i < selected_tracks; ++i)
        track_selection[i] = r_GetSelectedTrack2(project, i, true);
    for (int i = 0; i < selected; ++i)
        candidates[i] = r_GetSelectedMediaItem(project, i);

    /* Item selection takes precedence. A track selection supplies targets
       only when no media items are selected in the project. */
    int next = selected;
    bool has_stem_only = false;
    for (int i = 0; i < target_tracks; ++i) {
        MediaTrack *track = r_GetSelectedTrack2(project, i, false);
        if (!track) continue;
        int track_items = r_CountTrackMediaItems(track);
        if (!track_items) has_stem_only = true;
        for (int j = 0; j < track_items; ++j)
            candidates[next++] = r_GetTrackMediaItem(track, j);
    }

    int count = 0;
    for (int i = 0; i < candidate_count; ++i) {
        MediaItem *item = candidates[i];
        if (!is_unlocked(project, item) || r_GetMediaItemInfo_Value(item, "B_MUTE") ||
            r_GetMediaItemInfo_Value(item, "B_ALLTAKESPLAY"))
            continue;
        int takes = r_CountTakes(item);
        if (takes != 1 && takes != 2) continue;
        FastItem entry = {
            .item = item,
            .track = r_GetMediaItemTrack(item),
            .active = r_GetActiveTake(item),
            .first = r_GetTake(item, 0),
            .old_second = takes == 2 ? r_GetTake(item, 1) : NULL,
            .start = r_GetMediaItemInfo_Value(item, "D_POSITION")
        };
        entry.end = entry.start + r_GetMediaItemInfo_Value(item, "D_LENGTH");
        bool has_first = entry.first || (entry.old_second && is_fast_stem_item(item));
        if (entry.track && has_first && (takes == 1 || entry.old_second) &&
            isfinite(entry.start) && isfinite(entry.end) && entry.end > entry.start)
            items[count++] = entry;
    }

    if (!count && !has_stem_only) goto cleanup;

    if (count > 1) qsort(items, (size_t)count, sizeof(*items), compare_fast_items);
    processing = true;
    r_Undo_BeginBlock2(project);
    for (int first = 0; first < count;) {
        MediaTrack *track = items[first].track;
        int end = first + 1;
        while (end < count && items[end].track == track) ++end;
        const char *failure;
        if (!render_fast_track(project, track, items + first, end - first, channels,
                               chunk_buffer, &failure))
            report_fast_failure(project, track, failure);
        first = end;
    }

    for (int i = 0; has_stem_only && i < selected_tracks; ++i) {
        MediaTrack *track = track_selection[i];
        if (!track || !r_ValidatePtr2(project, track, "MediaTrack*") ||
            r_GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") <= 0 ||
            r_CountTrackMediaItems(track) != 0)
            continue;
        const char *failure;
        if (!render_fast_track(project, track, NULL, 0, channels, NULL, &failure))
            report_fast_failure(project, track, failure);
    }

    for (int i = r_CountSelectedTracks2(project, true) - 1; i >= 0; --i) {
        MediaTrack *track = r_GetSelectedTrack2(project, i, true);
        if (track) r_SetTrackSelected(track, false);
    }
    for (int i = 0; i < selected_tracks; ++i)
        if (track_selection[i] && r_ValidatePtr2(project, track_selection[i], "MediaTrack*"))
            r_SetTrackSelected(track_selection[i], true);
    r_SelectAllMediaItems(project, false);
    for (int i = 0; i < selected; ++i)
        if (still_valid(project, candidates[i]))
            r_SetMediaItemSelected(candidates[i], true);
    r_Undo_EndBlock2(project, channels == 1 ? fast_actions[1].name : fast_actions[0].name, 4);
    r_UpdateArrange();
    processing = false;
    for (int i = 0; i < count; ++i) free(items[i].chunk);

cleanup:
    free(track_selection);
    free(chunk_buffer);
    free(candidates);
    free(items);
}

static bool dispatch_fast_action(int command) {
    for (size_t i = 0; i < sizeof(fast_action_ids) / sizeof(fast_action_ids[0]); ++i) {
        if (fast_action_ids[i] > 0 && command == fast_action_ids[i]) {
            run_fast_after_fx(i == 0 ? 2 : 1);
            return true;
        }
    }
    return false;
}

static void unregister_fast_actions(void) {
    for (size_t i = 0; i < sizeof(fast_action_ids) / sizeof(fast_action_ids[0]); ++i) {
        if (fast_action_ids[i] > 0)
            register_plugin("-custom_action", (void *)&fast_actions[i]);
        fast_action_ids[i] = 0;
    }
}

static void register_fast_actions(reaper_plugin_info_t *info) {
#define LOAD_FAST(name) do { \
    r_##name = (__typeof__(r_##name))info->GetFunc(#name); \
    if (!r_##name) return; \
} while (0)
    LOAD_FAST(GetMediaItemTrack);
    LOAD_FAST(GetMediaTrackInfo_Value);
    LOAD_FAST(SetMediaTrackInfo_Value);
    LOAD_FAST(GetTrackNumSends);
    LOAD_FAST(CountTrackMediaItems);
    LOAD_FAST(CountTracks);
    LOAD_FAST(GetTrack);
    LOAD_FAST(GetProjectLength);
    LOAD_FAST(GetSet_LoopTimeRange2);
    LOAD_FAST(GetTrackMediaItem);
    LOAD_FAST(CountSelectedTracks2);
    LOAD_FAST(GetSelectedTrack2);
    LOAD_FAST(SetOnlyTrackSelected);
    LOAD_FAST(SetTrackSelected);
    LOAD_FAST(GetSetProjectInfo);
    LOAD_FAST(projectconfig_var_getoffs);
    LOAD_FAST(projectconfig_var_addr);
    LOAD_FAST(GetSetProjectInfo_String);
    LOAD_FAST(GetProjectPathEx);
    LOAD_FAST(RecursiveCreateDirectory);
    LOAD_FAST(PCM_Source_CreateFromFile);
    LOAD_FAST(PCM_Source_Destroy);
    LOAD_FAST(PCM_Source_BuildPeaks);
    LOAD_FAST(UpdateItemInProject);
    LOAD_FAST(GetMediaSourceLength);
    LOAD_FAST(GetMediaSourceNumChannels);
    LOAD_FAST(GetMediaSourceSampleRate);
    LOAD_FAST(GetMediaItemTake_Source);
    LOAD_FAST(SetMediaItemTake_Source);
    LOAD_FAST(AddMediaItemToTrack);
    LOAD_FAST(DeleteTrackMediaItem);
    LOAD_FAST(AddTakeToMediaItem);
    LOAD_FAST(GetSetMediaItemInfo_String);
    LOAD_FAST(SetMediaItemTakeInfo_Value);
    LOAD_FAST(GetSetMediaItemTakeInfo_String);
    LOAD_FAST(GetItemStateChunk);
    LOAD_FAST(SetItemStateChunk);
    LOAD_FAST(SetMediaItemInfo_Value);
#undef LOAD_FAST
    for (size_t i = 0; i < sizeof(fast_action_ids) / sizeof(fast_action_ids[0]); ++i) {
        fast_action_ids[i] = register_plugin("custom_action", (void *)&fast_actions[i]);
        if (fast_action_ids[i] <= 0) {
            unregister_fast_actions();
            return;
        }
    }
}
