#include "OscCodec.hpp"
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace recovered {
namespace {
std::optional<std::string> readString(const uint8_t *buffer, size_t size, size_t &offset) {
    if (offset >= size || offset % 4 != 0) return std::nullopt;
    size_t end = offset;
    while (end < size && buffer[end]) ++end;
    if (end == size) return std::nullopt;
    const size_t padded = (end + 4u) & ~size_t(3u);
    if (padded > size || padded <= end) return std::nullopt;
    for (size_t i = end; i < padded; ++i)
        if (buffer[i] != 0) return std::nullopt;
    std::string result(reinterpret_cast<const char *>(buffer + offset), end - offset);
    offset = padded;
    return result;
}
std::optional<uint32_t> readBE32(const uint8_t *buffer, size_t size, size_t &offset) {
    if (offset > size || size - offset < 4) return std::nullopt;
    const uint32_t value = (uint32_t(buffer[offset]) << 24) |
        (uint32_t(buffer[offset + 1]) << 16) | (uint32_t(buffer[offset + 2]) << 8) |
        uint32_t(buffer[offset + 3]);
    offset += 4;
    return value;
}
void appendString(std::vector<uint8_t> &buffer, const std::string &text) {
    buffer.insert(buffer.end(), text.begin(), text.end());
    buffer.push_back(0);
    while (buffer.size() % 4) buffer.push_back(0);
}
void appendBE32(std::vector<uint8_t> &buffer, uint32_t value) {
    buffer.push_back(uint8_t(value >> 24));
    buffer.push_back(uint8_t(value >> 16));
    buffer.push_back(uint8_t(value >> 8));
    buffer.push_back(uint8_t(value));
}
std::optional<int32_t> decimalAction(const std::string &text) {
    if (text.empty()) return std::nullopt;
    errno = 0;
    char *end = nullptr;
    const long value = std::strtol(text.c_str(), &end, 10);
    if (errno || end == text.c_str() || !end || *end || value <= 0 || value > INT_MAX)
        return std::nullopt;
    return static_cast<int32_t>(value);
}
bool validCommand(const std::string &text) {
    // REAPER named actions use an underscore prefix, as in _RSabc123.
    if (!text.empty() && text[0] == '_') {
        if (text.size() <= 1 || text.size() > 255) return false;
        for (char c : text) {
            if (!(c == '_' || (c >= '0' && c <= '9') ||
                  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
        }
        return true;
    }
    return decimalAction(text).has_value();
}
}

std::optional<OscMessage> parseOsc(const void *data, size_t size) {
    if (!data || size < 8 || size > 65536 || size % 4 != 0) return std::nullopt;
    const auto *bytes = static_cast<const uint8_t *>(data);
    size_t offset = 0;
    OscMessage message;
    auto address = readString(bytes, size, offset);
    auto tags = readString(bytes, size, offset);
    if (!address || !tags || address->size() < 2 || (*address)[0] != '/' ||
        tags->empty() || (*tags)[0] != ',' || tags->size() > 32) return std::nullopt;
    message.address = std::move(*address);
    message.typeTags = std::move(*tags);
    for (size_t i = 1; i < message.typeTags.size(); ++i) {
        switch (message.typeTags[i]) {
            case 'i': {
                auto value = readBE32(bytes, size, offset);
                if (!value) return std::nullopt;
                message.integers.push_back(static_cast<int32_t>(*value));
                break;
            }
            case 'f': {
                auto value = readBE32(bytes, size, offset);
                if (!value) return std::nullopt;
                float floating;
                const uint32_t bits = *value;
                std::memcpy(&floating, &bits, sizeof(floating));
                if (!std::isfinite(floating)) return std::nullopt;
                message.floats.push_back(floating);
                break;
            }
            case 's': {
                auto value = readString(bytes, size, offset);
                if (!value) return std::nullopt;
                message.strings.push_back(std::move(*value));
                break;
            }
            default: return std::nullopt;
        }
    }
    if (offset != size) return std::nullopt;
    return message;
}

std::vector<uint8_t> statePacket(const std::string &address, int32_t state) {
    std::vector<uint8_t> buffer;
    buffer.reserve(address.size() + 12);
    appendString(buffer, address);
    appendString(buffer, ",i");
    appendBE32(buffer, static_cast<uint32_t>(state));
    return buffer;
}

std::optional<OscActionRequest> actionRequest(const OscMessage &m) {
    if (m.address == "/reaper/str" && m.typeTags == ",s" &&
        m.strings.size() == 1 && validCommand(m.strings.front()))
        return OscActionRequest{m.strings.front(), -1};
    if (m.address == "/reaper" && m.typeTags == ",i" &&
        m.integers.size() == 1 && m.integers[0] > 0)
        return OscActionRequest{std::to_string(m.integers[0]), -1};
    if (m.address.compare(0, 8, "/reaper/") != 0) return std::nullopt;
    const auto command = m.address.substr(8);
    if (!validCommand(command)) return std::nullopt;
    if (m.typeTags == ",i" && m.integers.size() == 1 &&
        (m.integers[0] == 0 || m.integers[0] == 1))
        return OscActionRequest{command, m.integers[0]};
    if (m.typeTags == ",f" && m.floats.size() == 1 &&
        (m.floats[0] == 0.0f || m.floats[0] == 1.0f))
        return OscActionRequest{command, static_cast<int>(m.floats[0])};
    return std::nullopt;
}

std::optional<int32_t> actionFromMessage(const OscMessage &m) {
    auto request = actionRequest(m);
    return request ? decimalAction(request->command) : std::nullopt;
}
}
