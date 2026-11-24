#include "model.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <locale>
#include <sstream>
#include <string>

namespace {
constexpr double defaultStepDb = 0.5;
constexpr char defaultStepText[] = "0.5";
constexpr char stateSection[] = "mixolve_custom-view";
constexpr char stepKey[] = "take_volume_step_db";
constexpr char stepDialogTitle[] = "Take volume step";

struct Action {
    int section;
    const char *id;
    const char *name;
};

Action downAction = {0, "MIXOLVE_CUSTOMVIEW_TAKE_VOLUME_DOWN",
                     "mixolve_custom-view: take volume down"};
Action upAction = {0, "MIXOLVE_CUSTOMVIEW_TAKE_VOLUME_UP",
                   "mixolve_custom-view: take volume up"};

Action stepAction = {0, "MIXOLVE_CUSTOMVIEW_TAKE_VOLUME_SET_STEP",
                     "mixolve_custom-view: set take volume step"};

Action unityAction = {0, "MIXOLVE_CUSTOMVIEW_TAKE_VOLUME_SET_ZERO_DB",
                      "mixolve_custom-view: set take volume to 0 dB"};
Action silenceAction = {0, "MIXOLVE_CUSTOMVIEW_TAKE_VOLUME_SET_NEG_INF",
                        "mixolve_custom-view: set take volume to -inf"};

struct TakeVolumeAPI {
    int (*reg)(const char *, void *) = nullptr;
    int (*countSelectedItems)(void *) = nullptr;
    void *(*selectedItem)(void *, int) = nullptr;
    void *(*activeTake)(void *) = nullptr;
    bool (*isMIDI)(void *) = nullptr;
    double (*getTakeValue)(void *, const char *) = nullptr;
    bool (*setTakeValue)(void *, const char *, double) = nullptr;
    void (*preventRefresh)(int) = nullptr;
    void (*updateArrange)() = nullptr;
    void (*undoItemChange)(void *, const char *) = nullptr;
    bool (*getUserInputs)(const char *, int, const char *, char *, int) = nullptr;
    int (*showMessageBox)(const char *, const char *, int) = nullptr;
    const char *(*getExtState)(const char *, const char *) = nullptr;
    void (*setExtState)(const char *, const char *, const char *, bool) = nullptr;
};

TakeVolumeAPI api;
int downID = 0;
int upID = 0;
int stepID = 0;
int unityID = 0;
int silenceID = 0;
double stepDb = defaultStepDb;
std::string stepText = defaultStepText;
bool hook1 = false;
bool hook2 = false;

bool parseStep(std::string &text, double &value) {
    constexpr char whitespace[] = " \t\r\n";
    const auto first = text.find_first_not_of(whitespace);
    if (first == std::string::npos) return false;
    text = text.substr(first, text.find_last_not_of(whitespace) - first + 1);
    std::replace(text.begin(), text.end(), ',', '.');

    std::istringstream input(text);
    input.imbue(std::locale::classic());
    return (input >> value) && input.eof() && std::isfinite(value) && value > 0.0 &&
           std::isfinite(std::pow(10.0, value / 20.0));
}

void promptForStep() {
    char buffer[128];
    std::snprintf(buffer, sizeof(buffer), "%s", stepText.c_str());
    if (!api.getUserInputs(stepDialogTitle, 1, "Step (dB),separator=|", buffer, sizeof(buffer))) return;

    std::string entered = buffer;
    double value;
    if (!parseStep(entered, value)) {
        api.showMessageBox("Enter a positive step in dB, for example 0.25.", stepDialogTitle, 0);
        return;
    }
    stepDb = value;
    stepText = entered;
    api.setExtState(stateSection, stepKey, stepText.c_str(), true);
}

bool onCommand(int command, int) {
    if (command <= 0) return false;
    if (command == stepID) {
        promptForStep();
        return true;
    }
    const bool setUnity = command == unityID;
    const bool setSilence = command == silenceID;
    const bool absolute = setUnity || setSilence;
    if (!absolute && command != downID && command != upID) return false;

    const double factor = absolute ? 1.0 : std::pow(10.0, (command == upID ? stepDb : -stepDb) / 20.0);
    const double magnitude = setUnity ? 1.0 : 0.0;
    bool changed = false;
    api.preventRefresh(1);
    for (int i = 0, count = api.countSelectedItems(nullptr); i < count; ++i) {
        void *item = api.selectedItem(nullptr, i);
        void *take = item ? api.activeTake(item) : nullptr;
        if (!take || api.isMIDI(take)) continue;
        const double gain = api.getTakeValue(take, "D_VOL");
        // REAPER stores take polarity in the sign of D_VOL.
        const double adjusted = absolute ? std::copysign(magnitude, gain) : gain * factor;
        if (!std::isfinite(adjusted) || (absolute && adjusted == gain)) continue;
        if (api.setTakeValue(take, "D_VOL", adjusted)) changed = true;
    }
    api.preventRefresh(-1);
    if (absolute && changed) {
        api.undoItemChange(nullptr, setUnity ? "Set take volume to 0 dB" : "Set take volume to -inf");
    }
    api.updateArrange();
    return true;
}

bool onCommand2(void *, int command, int, int, int, void *) {
    return onCommand(command, 0);
}

void stop() {
    if (!api.reg) return;
    if (hook2) api.reg("-hookcommand2", reinterpret_cast<void *>(onCommand2));
    if (hook1) api.reg("-hookcommand", reinterpret_cast<void *>(onCommand));
    if (silenceID > 0) api.reg("-custom_action", &silenceAction);
    if (unityID > 0) api.reg("-custom_action", &unityAction);
    if (stepID > 0) api.reg("-custom_action", &stepAction);
    if (upID > 0) api.reg("-custom_action", &upAction);
    if (downID > 0) api.reg("-custom_action", &downAction);
    api = {};
    silenceID = unityID = stepID = upID = downID = 0;
    stepDb = defaultStepDb;
    stepText = defaultStepText;
    hook1 = hook2 = false;
}
} // namespace

extern "C" bool MixolveTakeVolumeEntry(ep::Info *info) {
    if (!info) {
        stop();
        return true;
    }
    if (api.reg) return true;

    TakeVolumeAPI loaded;
    loaded.reg = info->reg;
    loaded.countSelectedItems = reinterpret_cast<decltype(loaded.countSelectedItems)>(info->get("CountSelectedMediaItems"));
    loaded.selectedItem = reinterpret_cast<decltype(loaded.selectedItem)>(info->get("GetSelectedMediaItem"));
    loaded.activeTake = reinterpret_cast<decltype(loaded.activeTake)>(info->get("GetActiveTake"));
    loaded.isMIDI = reinterpret_cast<decltype(loaded.isMIDI)>(info->get("TakeIsMIDI"));
    loaded.getTakeValue = reinterpret_cast<decltype(loaded.getTakeValue)>(info->get("GetMediaItemTakeInfo_Value"));
    loaded.setTakeValue = reinterpret_cast<decltype(loaded.setTakeValue)>(info->get("SetMediaItemTakeInfo_Value"));
    loaded.preventRefresh = reinterpret_cast<decltype(loaded.preventRefresh)>(info->get("PreventUIRefresh"));
    loaded.updateArrange = reinterpret_cast<decltype(loaded.updateArrange)>(info->get("UpdateArrange"));
    loaded.undoItemChange = reinterpret_cast<decltype(loaded.undoItemChange)>(info->get("Undo_OnStateChange2"));
    loaded.getUserInputs = reinterpret_cast<decltype(loaded.getUserInputs)>(info->get("GetUserInputs"));
    loaded.showMessageBox = reinterpret_cast<decltype(loaded.showMessageBox)>(info->get("ShowMessageBox"));
    loaded.getExtState = reinterpret_cast<decltype(loaded.getExtState)>(info->get("GetExtState"));
    loaded.setExtState = reinterpret_cast<decltype(loaded.setExtState)>(info->get("SetExtState"));
    if (!loaded.reg || !loaded.countSelectedItems || !loaded.selectedItem || !loaded.activeTake ||
        !loaded.isMIDI || !loaded.getTakeValue || !loaded.setTakeValue ||
        !loaded.preventRefresh || !loaded.updateArrange || !loaded.undoItemChange || !loaded.getUserInputs ||
        !loaded.showMessageBox || !loaded.getExtState || !loaded.setExtState) return false;

    api = loaded;
    if (const char *saved = api.getExtState(stateSection, stepKey)) {
        std::string text = saved;
        double value;
        if (text.size() < 128 && parseStep(text, value)) {
            stepDb = value;
            stepText = text;
        }
    }
    downID = api.reg("custom_action", &downAction);
    if (downID > 0) upID = api.reg("custom_action", &upAction);
    if (upID > 0) stepID = api.reg("custom_action", &stepAction);
    if (stepID > 0) unityID = api.reg("custom_action", &unityAction);
    if (unityID > 0) silenceID = api.reg("custom_action", &silenceAction);
    if (silenceID > 0) {
        hook2 = api.reg("hookcommand2", reinterpret_cast<void *>(onCommand2)) != 0;
        if (!hook2) hook1 = api.reg("hookcommand", reinterpret_cast<void *>(onCommand)) != 0;
    }
    if (hook1 || hook2) return true;
    stop();
    return false;
}
