#pragma once
#include <cstdint>
// Narrow ABI declaration from Cockos reaper_plugin.h ProjectStateContext.
// Keep virtual method order identical to the SDK (including the destructor).
class ProjectStateContext {
public:
 virtual ~ProjectStateContext(){};
 virtual void AddLine(const char*format,...)=0;
 virtual int GetLine(char*buffer,int size)=0;
 virtual int64_t GetOutputSize()=0;
 virtual int GetTempFlag()=0;
 virtual void SetTempFlag(int flag)=0;
};
