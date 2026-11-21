#pragma once
#include <sstream>
#include <string>
namespace lc {
struct ItemDragModifier {bool copy=false,ignoreSnap=false;};
inline int mouseModifierFlags(bool shift,bool command,bool option,bool control){return (shift?1:0)|(command?2:0)|(option?4:0)|(control?8:0);}
// REAPER Media item left drag (MM_CTX_ITEM) built-in mouse-action IDs.
// Copy variants include ignoring time selection, vertical and pooled-MIDI
// variants. Containers always create linked children on their parent's track.
inline ItemDragModifier itemDragModifier(const std::string&assignment){
 std::istringstream in(assignment);int id=-1;if(!(in>>id))return {};std::string kind,extra;if(in>>kind){if(kind!="m"||(in>>extra))return {};}
 switch(id){
  case 5:case 18:case 25:case 40:case 42:case 46:return {true,true};
  case 2:case 17:case 24:case 36:case 37:case 39:case 41:case 43:case 44:case 45:return {true,false};
  default:return {};
 }
}
}
