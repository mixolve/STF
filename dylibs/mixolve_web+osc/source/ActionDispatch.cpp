#include "ActionDispatch.hpp"
#include <charconv>

namespace recovered {
int dispatchAction(const OscActionRequest &request,
                   const RecoveredReaperCallbacks &callbacks) {
    if (!callbacks.runAction || request.command.empty() ||
        (request.desiredState != -1 && request.desiredState != 0 && request.desiredState != 1))
        return 0;

    int command = 0;
    if (request.command[0] == '_') {
        if (!callbacks.namedCommandLookup) return 0;
        command = callbacks.namedCommandLookup(request.command.c_str());
    } else {
        auto first = request.command.data();
        auto end = first + request.command.size();
        auto result = std::from_chars(first, end, command, 10);
        if (result.ec != std::errc() || result.ptr != end) return 0;
    }
    if (command <= 0) return 0;
    if (request.desiredState >= 0 && callbacks.getToggleState) {
        int current = callbacks.getToggleState(command);
        if (current == request.desiredState || (current < 0 && request.desiredState == 0))
            return command;
    }
    callbacks.runAction(command);
    return command;
}
}
