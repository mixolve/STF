#pragma once
#include <vector>
namespace ara_filter {
// Main-thread only. Each native take is classified by the engine's current manifest.
using IsChildTake=bool(*)(void*);
using TrackVisible=bool(*)(void*);
void poll(const std::vector<void*>& projects,IsChildTake isChild,TrackVisible visible=nullptr);
void shutdown();
}
