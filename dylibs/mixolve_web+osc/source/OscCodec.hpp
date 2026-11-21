// OSC decoder/encoder and REAPER command request router, independently reconstructed.
#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace recovered {
struct OscMessage {
    std::string address;
    std::string typeTags;
    std::vector<int32_t> integers;
    std::vector<float> floats;
    std::vector<std::string> strings;
};
struct OscActionRequest {
    // Numeric action ID, or named-action token (for NamedCommandLookup).
    std::string command;
    // -1: run regardless of toggle state; 0/1: set toggle state to requested value.
    int desiredState = -1;
};

std::optional<OscMessage> parseOsc(const void *data, size_t size);
std::vector<uint8_t> statePacket(const std::string &address, int32_t state);
std::optional<OscActionRequest> actionRequest(const OscMessage &message);
std::optional<int32_t> actionFromMessage(const OscMessage &message);
}
