#pragma once
#include "model.hpp"
#include <array>
struct Info {int version;void*hwnd;int(*reg)(const char*,void*);void*(*get)(const char*);};
struct Action {int section;const char*id;const char*name;void*extra;};
struct ProjectConfig {bool(*line)(const char*,void*,bool,ProjectConfig*);void(*save)(void*,bool,ProjectConfig*);void(*load)(bool,ProjectConfig*);void*data;};
namespace engine {
using Ptr=void*;
#define API(ret,name,args) extern ret(*name)args
API(Ptr,EnumProjects,(int,char*,int));API(int,CountMediaItems,(Ptr));API(Ptr,GetMediaItem,(Ptr,int));
API(double,GetMediaItemInfo_Value,(Ptr,const char*));API(bool,SetMediaItemInfo_Value,(Ptr,const char*,double));
API(Ptr,GetSetMediaItemInfo,(Ptr,const char*,Ptr));API(bool,GetSetMediaItemInfo_String,(Ptr,const char*,char*,bool));API(bool,IsMediaItemSelected,(Ptr));API(void,SetMediaItemSelected,(Ptr,bool));
API(bool,ValidatePtr2,(Ptr,Ptr,const char*));API(int,CountTakes,(Ptr));API(Ptr,GetTake,(Ptr,int));API(double,GetMediaItemTakeInfo_Value,(Ptr,const char*));API(bool,SetMediaItemTakeInfo_Value,(Ptr,const char*,double));API(int,TakeFX_GetCount,(Ptr));API(void,TakeFX_Show,(Ptr,int,int));API(Ptr,GetMediaItemTrack,(Ptr));API(bool,MoveMediaItemToTrack,(Ptr,Ptr));API(Ptr,AddMediaItemToTrack,(Ptr));API(bool,DeleteTrackMediaItem,(Ptr,Ptr));
API(bool,GetItemStateChunk,(Ptr,char*,int,bool));API(bool,SetItemStateChunk,(Ptr,const char*,bool));
API(void,InsertTrackInProject,(Ptr,int,int));API(void,TrackList_AdjustWindows,(bool));API(int,CountTracks,(Ptr));API(Ptr,GetTrack,(Ptr,int));API(Ptr,GetSelectedTrack,(Ptr,int));API(double,GetMediaTrackInfo_Value,(Ptr,const char*));
API(bool,GetSetMediaTrackInfo_String,(Ptr,const char*,char*,bool));
API(Ptr,GetTrackGUID,(Ptr));API(void,genGuid,(Ptr));API(void,guidToString,(const void*,char*));
API(int,GetProjExtState,(Ptr,const char*,const char*,char*,int));API(int,SetProjExtState,(Ptr,const char*,const char*,const char*));
API(double,GetCursorPositionEx,(Ptr));API(int,GetProjectStateChangeCount,(Ptr));
API(void,Undo_BeginBlock2,(Ptr));API(void,Undo_EndBlock2,(Ptr,const char*,int));API(int,Undo_GetCurEntry,(Ptr));
API(void,PreventUIRefresh,(int));API(void,UpdateArrange,());API(void,Main_OnCommand,(int,int));API(const char*,kbd_getTextFromCmd,(int,Ptr));
API(double,TimeMap2_timeToBeats,(Ptr,double,int*,int*,double*,int*));API(double,TimeMap2_beatsToTime,(Ptr,double,const int*));
API(int,ShowMessageBox,(const char*,const char*,int));API(double,time_precise,());
API(void,GetMouseModifier,(const char*,int,char*,int));API(Ptr,GetMainHwnd,());API(void,GetSet_ArrangeView2,(Ptr,bool,int,int,double*,double*));API(double,SnapToGrid,(Ptr,double));API(int,GetToggleCommandStateEx,(int,int));
#undef API
struct Item {Ptr ptr=nullptr,track=nullptr;std::string guid,trackId,parent,child,source;double position=0,length=0;bool selected=false;};
struct Box {std::string id,parent;bool child=false;double start=0,end=0,top=0,bottom=0;};
extern Ptr project;extern lc::Manifest manifest;extern std::string selectedContainer;extern bool busy;
bool participates(const Item&,const std::string&);
std::vector<Item>scan();void sync(bool force=false);void action(int which,const std::string& target={});std::vector<Box>boxes();
void selectContainer(const std::string&id,bool containerFocus=true);
bool containerInputFocused();
void beginDrag(const std::string&id,bool copy=false);void dragTo(double position,int targetTrack=-1);void endDrag();
void beginResize(const std::string&id,int edge);void resizeTo(double position);bool resizing();
double minimumContainerEdge(double fixed,int edge);
void toggleChildItemMute(const std::string&,const std::string&);
void tick();void overlayTick();void overlayRemove();
}
