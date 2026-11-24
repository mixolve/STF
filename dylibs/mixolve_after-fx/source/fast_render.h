/* Continuous per-track rendering for the two fast actions. */
#include <dirent.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

typedef struct MediaTrack MediaTrack;
typedef struct PCM_source PCM_source;

static MediaTrack *(*r_GetMediaItemTrack)(MediaItem *);
static double (*r_GetMediaTrackInfo_Value)(MediaTrack *, const char *);
static bool (*r_SetMediaTrackInfo_Value)(MediaTrack *, const char *, double);
static int (*r_GetTrackNumSends)(MediaTrack *, int);
static int (*r_CountTrackMediaItems)(MediaTrack *);
static MediaItem *(*r_GetTrackMediaItem)(MediaTrack *, int);
static int (*r_CountSelectedTracks2)(ReaProject *, bool);
static MediaTrack *(*r_GetSelectedTrack2)(ReaProject *, int, bool);
static void (*r_SetOnlyTrackSelected)(MediaTrack *);
static void (*r_SetTrackSelected)(MediaTrack *, bool);
static double (*r_GetSetProjectInfo)(ReaProject *, const char *, double, bool);
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
static MediaItem_Take *(*r_AddTakeToMediaItem)(MediaItem *);
static bool (*r_SetMediaItemTakeInfo_Value)(MediaItem_Take *, const char *, double);
static bool (*r_GetSetMediaItemTakeInfo_String)(MediaItem_Take *, const char *, char *, bool);
static bool (*r_GetItemStateChunk)(MediaItem *, char *, int, bool);
static bool (*r_SetItemStateChunk)(MediaItem *, const char *, bool);
static bool (*r_SetMediaItemInfo_Value)(MediaItem *, const char *, double);

enum {
    ACT_RENDER_RECENT_AUTO_CLOSE = 42230,
    RENDER_SELECTED_STEMS = 2,
    RENDER_PRE_FADER = 8192,
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

static bool render_fast_wav(ReaProject *project, char *directory,
                            double start, double end, int channels,
                            const char **failure) {
    RenderNumber numbers[] = {
        {"RENDER_SETTINGS", RENDER_SELECTED_STEMS | RENDER_PRE_FADER, 0},
        {"RENDER_BOUNDSFLAG", 0, 0},
        {"RENDER_STARTPOS", start, 0},
        {"RENDER_ENDPOS", end, 0},
        {"RENDER_CHANNELS", channels, 0},
        {"RENDER_ADDTOPROJ", 0, 0},
        {"RENDER_TAILFLAG", 0, 0},
        {"RENDER_NORMALIZE", 0, 0},
        {"RENDER_DITHER", 16, 0}
    };
    char name[] = "After FX";
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

    if (configured)
        r_Main_OnCommand(ACT_RENDER_RECENT_AUTO_CLOSE, 0);

    for (size_t i = 0; i < string_count; ++i)
        r_GetSetProjectInfo_String(project, strings[i].key, strings[i].saved, true);
    for (size_t i = 0; i < number_count; ++i)
        r_GetSetProjectInfo(project, numbers[i].key, numbers[i].saved, true);
    return configured;
}

static bool find_fast_wav(const char *directory, char *path, size_t size) {
    DIR *files = opendir(directory);
    if (!files) return false;
    bool found = false;
    struct dirent *entry;
    while ((entry = readdir(files))) {
        const char *name = entry->d_name;
        size_t length = strlen(name);
        if (length < 5 || strcasecmp(name + length - 4, ".wav") != 0)
            continue;
        if (found) {
            found = false;
            break;
        }
        int written = snprintf(path, size, "%s/%s", directory, name);
        if (written < 0 || (size_t)written >= size || access(path, R_OK) != 0)
            break;
        found = true;
    }
    closedir(files);
    if (!found) path[0] = '\0';
    return found;
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
                 isfinite(length) && length >= duration - 2.0 / rate;
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

    item->rendered = r_AddTakeToMediaItem(item->item);
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

static bool finish_fast_takes(ReaProject *project, FastItem *items, int count) {
    r_SelectAllMediaItems(project, false);
    bool has_old_takes = false;
    for (int i = 0; i < count; ++i) {
        FastItem *item = &items[i];
        if (!is_unlocked(project, item->item) || r_GetTake(item->item, 0) != item->first ||
            r_CountTakes(item->item) != (item->old_second ? 3 : 2) ||
            r_GetTake(item->item, item->old_second ? 2 : 1) != item->rendered)
            return false;
        if (!item->old_second) continue;
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
        r_SetActiveTake(item->first);
        if (r_GetActiveTake(item->item) != item->first) return false;
        r_UpdateItemInProject(item->item);
    }
    return true;
}

static bool render_fast_track(ReaProject *project, FastItem *items, int count,
                              int channels, char *chunk_buffer, const char **failure) {
    MediaTrack *track = items[0].track;
    if (r_GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0) {
        *failure = "the track is a folder parent";
        return false;
    }
    if (r_GetMediaTrackInfo_Value(track, "B_MUTE")) {
        *failure = "the track is muted";
        return false;
    }
    if (r_GetTrackNumSends(track, -1) > 0) {
        *failure = "the track has receives";
        return false;
    }

    for (int i = 0; i < count; ++i) {
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

    *failure = "could not create a render folder in the project media path";
    char media_path[PATH_MAX] = "";
    r_GetProjectPathEx(project, media_path, sizeof(media_path));
    if (!media_path[0]) return false;
    r_RecursiveCreateDirectory(media_path, 0);

    char directory[PATH_MAX];
    int written = snprintf(directory, sizeof(directory), "%s/Mixolve After FX-XXXXXX", media_path);
    if (written < 0 || (size_t)written >= sizeof(directory) || !mkdtemp(directory))
        return false;
    char path[PATH_MAX] = "";

    *failure = "could not prepare track items";
    int track_item_count = r_CountTrackMediaItems(track);
    MediaItem **muted = calloc((size_t)track_item_count, sizeof(*muted));
    if (!muted) {
        rmdir(directory);
        return false;
    }
    int muted_count = 0;
    r_SelectAllMediaItems(project, false);
    r_SetOnlyTrackSelected(track);
    bool ready = true;
    for (int i = 0; i < count; ++i) {
        FastItem *item = &items[i];
        r_SetActiveTake(item->first);
        if (r_GetActiveTake(item->item) != item->first ||
            !is_unlocked(project, item->item))
            ready = false;
        if (!set_fast_item_playback(item, true)) ready = false;
        r_SetMediaItemSelected(item->item, true);
    }
    /* Use whole-second render boundaries so the WAV origin is exactly on
       the sample grid. Leave room past the final item for REAPER's rounding. */
    const double start = floor(items[0].start);
    const double required_end = items[count - 1].end;
    const double end = ceil(required_end + 0.01);
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
    bool success = ready && render_fast_wav(project, directory, start, end, channels, failure);
    if (override_volume &&
        (!r_ValidatePtr2(project, track, "MediaTrack*") ||
         !r_SetMediaTrackInfo_Value(track, "D_VOL", track_volume))) {
        *failure = "could not restore the track fader";
        success = false;
    }
    if (success) {
        *failure = "REAPER did not produce a single readable WAV in the render folder";
        success = find_fast_wav(directory, path, sizeof(path));
    }
    if (success) {
        *failure = "could not verify the rendered WAV";
        success = validate_fast_wav(path, required_end - start, channels);
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
    if (success) {
        *failure = "could not attach the WAV as a new take";
        for (int i = 0; success && i < count; ++i)
            success = attach_fast_take(&items[i], path, start);
    }
    if (success) {
        *failure = "could not replace the old second take or restore the first as active";
        success = finish_fast_takes(project, items, count);
    }
    if (success) return true;

    bool restored = true;
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
        if (path[0]) unlink(path);
        rmdir(directory);
    } else if (r_ShowConsoleMsg) {
        r_ShowConsoleMsg("mixolve_after-fx: could not restore an item. Use Undo to inspect the result.\n");
    }
    return false;
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
    if (!candidate_count) {
        if (r_ShowConsoleMsg)
            r_ShowConsoleMsg(target_tracks
                ? "mixolve_after-fx: selected tracks contain no items.\n"
                : "mixolve_after-fx: select media items or one or more tracks.\n");
        return;
    }

    MediaTrack **track_selection = calloc((size_t)selected_tracks + 1, sizeof(*track_selection));
    FastItem *items = calloc((size_t)candidate_count, sizeof(*items));
    MediaItem **candidates = calloc((size_t)candidate_count, sizeof(*candidates));
    char *chunk_buffer = malloc(ITEM_CHUNK_SIZE);
    if (!track_selection || !items || !candidates || !chunk_buffer) goto cleanup;
    for (int i = 0; i < selected_tracks; ++i)
        track_selection[i] = r_GetSelectedTrack2(project, i, true);
    for (int i = 0; i < selected; ++i)
        candidates[i] = r_GetSelectedMediaItem(project, i);

    /* Item selection takes precedence. A track selection supplies targets
       only when no media items are selected in the project. */
    int next = selected;
    for (int i = 0; i < target_tracks; ++i) {
        MediaTrack *track = r_GetSelectedTrack2(project, i, false);
        if (!track) continue;
        int track_items = r_CountTrackMediaItems(track);
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
        if (entry.track && entry.first && (takes == 1 || entry.old_second) &&
            isfinite(entry.start) && isfinite(entry.end) && entry.end > entry.start)
            items[count++] = entry;
    }

    if (!count) goto cleanup;

    qsort(items, (size_t)count, sizeof(*items), compare_fast_items);
    processing = true;
    r_Undo_BeginBlock2(project);
    for (int first = 0; first < count;) {
        int end = first + 1;
        while (end < count && items[end].track == items[first].track) ++end;
        const char *failure;
        if (!render_fast_track(project, items + first, end - first, channels, chunk_buffer, &failure)) {
            if (r_ShowConsoleMsg) {
                char message[256];
                int track_number = (int)r_GetMediaTrackInfo_Value(items[first].track, "IP_TRACKNUMBER");
                snprintf(message, sizeof(message), "mixolve_after-fx: track %d, fast render stopped: %s.\n",
                         track_number, failure);
                r_ShowConsoleMsg(message);
            }
        }
        first = end;
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
    LOAD_FAST(GetTrackMediaItem);
    LOAD_FAST(CountSelectedTracks2);
    LOAD_FAST(GetSelectedTrack2);
    LOAD_FAST(SetOnlyTrackSelected);
    LOAD_FAST(SetTrackSelected);
    LOAD_FAST(GetSetProjectInfo);
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
    LOAD_FAST(AddTakeToMediaItem);
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
