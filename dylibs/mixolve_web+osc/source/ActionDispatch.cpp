#include "ActionDispatch.hpp"
#include <charconv>
#include <climits>

namespace recovered {
bool dispatchAction(const OscActionRequest &request,
                    const RecoveredReaperCallbacks &callbacks) {
    if (!callbacks.runAction || request.command.empty() ||
        (request.desiredState != -1 && request.desiredState != 0 && request.desiredState != 1))
        return false;

    int command = 0;
    if (request.command[0] == '_') {
        if (!callbacks.namedCommandLookup) return false;
        command = callbacks.namedCommandLookup(request.command.c_str());
    } else {
        auto first = request.command.data();
        auto end = first + request.command.size();
        auto result = std::from_chars(first, end, command, 10);
        if (result.ec != std::errc() || result.ptr != end) return false;
    }
    if (command <= 0) return false;
    if (request.desiredState >= 0 && callbacks.getToggleState) {
        int current = callbacks.getToggleState(command);
        if (current == request.desiredState || (current < 0 && request.desiredState == 0))
            return false;
    }
    callbacks.runAction(command);
    return true;
}
}
