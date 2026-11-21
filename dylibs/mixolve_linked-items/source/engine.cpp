#include "engine.hpp"
#include "ara_filter.hpp"
#include "project_state.hpp"
#include <cstring>
#include <cstdio>
#include <limits>
#include <unordered_map>
namespace engine {
#define API(ret,name,args) ret(*name)args=nullptr
API(int,GetCursorContext2,(bool));API(void,SetCursorContext,(int,Ptr));API(Ptr,GetCurrentProjectInLoadSave,());API(Ptr,EnumProjects,(int,char*,int));API(int,CountMediaItems,(Ptr));API(Ptr,GetMediaItem,(Ptr,int));
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
constexpr const char *parentKey="P_EXT:LC2_PARENT",*childKey="P_EXT:LC2_CHILD",*sourceKey="P_EXT:LC2_SOURCE",*hashKey="P_EXT:LC2_HASH",*contentKey="P_EXT:LC2_CONTENT",*payloadKey="P_EXT:LC2_PAYLOAD";
Ptr project=nullptr;lc::Manifest manifest;std::string selectedContainer;bool busy=false;
bool containerSelectionCleared=false,containerOperationFocus=false;
std::set<Ptr>selectionAtClear;
std::set<Ptr>nativeSelection(){std::set<Ptr>out;if(project&&CountMediaItems&&GetMediaItem&&IsMediaItemSelected)for(int n=0;n<CountMediaItems(project);n++){Ptr item=GetMediaItem(project,n);if(item&&IsMediaItemSelected(item))out.insert(item);}return out;}
void selectContainer(const std::string&id,bool containerFocus){selectedContainer=id;containerOperationFocus=!id.empty()&&containerFocus;if(containerOperationFocus&&SetCursorContext)SetCursorContext(1,nullptr);containerSelectionCleared=id.empty();if(containerSelectionCleared)selectionAtClear=nativeSelection();else selectionAtClear.clear();}
Info hostStorage{};Info*host=nullptr;
bool reset=true,forwarding=false;int lastState=-1,lastUndo=-1;bool sceneChanged=false;double lastTick=0;
std::map<Ptr,std::string>undoManifests;
std::string persisted,error;bool unknownManifest=false,containerDragActive=false;
uint64_t quickState=0;
std::vector<Item>viewItems;
uint64_t quick(){uint64_t h=1469598103934665603ULL;
 auto hash=[&](double d){uint64_t bits=0;std::memcpy(&bits,&d,sizeof(bits));h^=bits;h*=1099511628211ULL;};
 const char*keys[]={"D_POSITION","D_LENGTH","D_VOL","D_FADEINLEN","D_FADEOUTLEN","D_FADEINDIR_NEW","D_FADEOUTDIR_NEW","D_FADEINDIR2_NEW","D_FADEOUTDIR2_NEW","D_FADEINLEN_AUTO","D_FADEOUTLEN_AUTO","C_LOCK","I_GROUPID"};
 // Linked pointers are refreshed after topology/state changes, before this
 // property poll. Unlinked items incur no native property calls.
 for(auto&i:viewItems)if(manifest.parents.count(i.parent)||manifest.children.count(i.child)){
  if(!ValidatePtr2(project,i.ptr,"MediaItem*"))return h^0x9e3779b97f4a7c15ULL;
  for(auto k:keys)hash(GetMediaItemInfo_Value(i.ptr,k));
  int count=CountTakes(i.ptr);hash(count);for(int t=0;t<count;t++)if(Ptr take=GetTake(i.ptr,t))hash(GetMediaItemTakeInfo_Value(take,"D_VOL"));
 }
 return h;
}

struct Cache {std::string signature;std::map<std::string,std::string>chunks;};
std::map<std::string,Cache>cache;
std::string readString(Ptr i,const char*k){
 if(!std::strncmp(k,"P_EXT:",6)){const char*s=static_cast<const char*>(GetSetMediaItemInfo(i,k,nullptr));if(!s)return {};size_t n=strnlen(s,256);return n<256?std::string(s,n):std::string{};}
 char b[64]{};GetSetMediaItemInfo_String(i,k,b,false);return b;
}
void writeString(Ptr i,const char*k,const std::string&v){std::vector<char>b(v.begin(),v.end());b.push_back(0);GetSetMediaItemInfo_String(i,k,b.data(),true);}
std::string trackId(Ptr t){char b[64]{};if(t)guidToString(GetTrackGUID(t),b);return b;}
std::string uuid(){std::array<unsigned char,16>g{};char b[64]{};genGuid(g.data());guidToString(g.data(),b);return b;}
Ptr track(const std::string&id){for(int n=0;n<CountTracks(project);++n){Ptr t=GetTrack(project,n);if(trackId(t)==id)return t;}return nullptr;}
int trackIndex(Ptr t){return t?static_cast<int>(GetMediaTrackInfo_Value(t,"IP_TRACKNUMBER"))-1:-1;}
// REAPER returns false for a same-track no-op. Test the postcondition instead
// of asking it to perform a move that is not needed.
bool ensureTrack(Ptr item,Ptr destination){
 if(!item||!destination)return false;
 if(GetMediaItemTrack(item)==destination)return true;
 if(!MoveMediaItemToTrack(item,destination))return false;
 return GetMediaItemTrack(item)==destination;
}
std::string getChunk(Ptr i){for(size_t n=4096;n<=64*1024*1024;n*=2){std::vector<char>b(n);if(GetItemStateChunk(i,b.data(),(int)n,false))return b.data();}return {};}
std::string readManifest(Ptr owner=nullptr){if(!owner)owner=project;for(int n=4096;n<=16*1024*1024;n*=2){std::vector<char>b(n);GetProjExtState(owner,"LINKED_CONTAINERS","MANIFEST_V2",b.data(),n);if(std::strlen(b.data())<static_cast<size_t>(n-1))return b.data();}error="Container metadata exceeds the supported size.";return {};}
void saveManifest(){if(manifest.parents.empty()&&manifest.children.empty()&&persisted.empty())return;auto s=lc::encode(manifest);if(s!=persisted){SetProjExtState(project,"LINKED_CONTAINERS","MANIFEST_V2",s.c_str());persisted=s;}}
std::vector<Item>scan(){std::vector<Item>v;for(int n=0;n<CountMediaItems(project);++n){Ptr i=GetMediaItem(project,n);if(!i)continue;
 Item a;a.ptr=i;a.track=GetMediaItemTrack(i);a.guid=readString(i,"GUID");a.trackId=trackId(a.track);
 a.parent=readString(i,parentKey);a.child=readString(i,childKey);a.source=readString(i,sourceKey);
 a.position=GetMediaItemInfo_Value(i,"D_POSITION");a.length=GetMediaItemInfo_Value(i,"D_LENGTH");a.selected=IsMediaItemSelected(i);v.push_back(std::move(a));}return v;}
bool participates(const Item&i,const std::string&id){auto p=manifest.parents.find(id);return p!=manifest.parents.end()&&i.parent==id&&i.child.empty()&&!p->second.tracks.empty()&&i.trackId==p->second.tracks.front()&&i.position>=p->second.start-1e-9&&i.position+i.length<=p->second.end+1e-9;}
int nextGroup(const std::vector<Item>&items){int max=0;for(auto&i:items)max=std::max(max,static_cast<int>(GetMediaItemInfo_Value(i.ptr,"I_GROUPID")));return max==std::numeric_limits<int>::max()?0:max+1;}
std::string selection(const std::vector<Item>&items){if(manifest.parents.count(selectedContainer)||manifest.children.count(selectedContainer))return selectedContainer;std::set<std::string>ids;bool any=false;for(auto&i:items)if(i.selected){any=true;if(manifest.children.count(i.child))ids.insert(i.child);else if(manifest.parents.count(i.parent))ids.insert(i.parent);}
 if(ids.size()==1)return *ids.begin();if(any)return {};if(!selectedContainer.empty()&&(manifest.parents.count(selectedContainer)||manifest.children.count(selectedContainer)))return selectedContainer;return {};}
bool ensureTrackCount(int count){
 bool added=false;while(CountTracks(project)<count){int before=CountTracks(project);InsertTrackInProject(project,before,1);if(CountTracks(project)<=before)return false;added=true;}
 if(added)TrackList_AdjustWindows(false);return true;
}

struct Gain {double item=1;std::vector<double>takes;};
Gain gains(Ptr item){Gain g;g.item=GetMediaItemInfo_Value(item,"D_VOL");for(int n=0;n<CountTakes(item);n++)g.takes.push_back(GetTake(item,n)?GetMediaItemTakeInfo_Value(GetTake(item,n),"D_VOL"):NAN);return g;}
std::string gainKey(const Gain&g){std::ostringstream o;o<<std::setprecision(17)<<g.item;for(auto v:g.takes)o<<' '<<v;return o.str();}
bool sameGains(Ptr item,const Gain&g){auto actual=gains(item);if(actual.takes.size()!=g.takes.size()||std::abs(actual.item-g.item)>1e-12)return false;for(size_t n=0;n<g.takes.size();n++){if(std::isnan(actual.takes[n])!=std::isnan(g.takes[n]))return false;if(!std::isnan(g.takes[n])&&std::abs(actual.takes[n]-g.takes[n])>1e-12)return false;}return true;}
bool applyGains(Ptr item,const Gain&g){if(CountTakes(item)!=(int)g.takes.size())return false;if(!SetMediaItemInfo_Value(item,"D_VOL",g.item))return false;for(size_t n=0;n<g.takes.size();n++){Ptr take=GetTake(item,(int)n);if(std::isnan(g.takes[n])){if(take)return false;}else if(!take||!SetMediaItemTakeInfo_Value(take,"D_VOL",g.takes[n]))return false;}return true;}
void hideChildFxWindows(Ptr item){
 for(int n=0;n<CountTakes(item);n++)if(Ptr take=GetTake(item,n)){
  TakeFX_Show(take,0,0);for(int fx=0;fx<TakeFX_GetCount(take);fx++)TakeFX_Show(take,fx,2);
 }
}
struct Source {Item item;std::string chunk;Gain gain;};
bool rebuild(lc::Child&child,const lc::Parent&parent,const std::vector<Source>&input,const std::vector<Item>&items){
 auto sources=input;for(auto&s:sources)if(child.muted.count(s.item.guid))s.chunk=lc::mutedChunk(s.chunk);
 std::vector<std::string>hashes,contents,payloads;std::string signature;
 for(auto&s:sources){auto slot=std::find(parent.tracks.begin(),parent.tracks.end(),s.item.trackId);
  std::string destination=slot!=parent.tracks.end()&&static_cast<size_t>(slot-parent.tracks.begin())<child.tracks.size()?child.tracks[slot-parent.tracks.begin()]:"-";
  auto payload=lc::mappedGuid(child.id,lc::volumeIndependent(s.chunk));payloads.push_back(payload);
  auto content=lc::mappedGuid(child.id,payload+gainKey(s.gain));contents.push_back(content);
  std::ostringstream location;location<<std::setprecision(17)<<s.item.position+child.offset;
  auto hash=lc::mappedGuid(child.id,s.item.guid+content+destination+location.str()+std::to_string(child.group));hashes.push_back(hash);signature+=hash;
 }
 signature=lc::mappedGuid(child.id,signature);
 std::vector<Item>current;std::map<std::string,Item>bySource;bool duplicate=false;
 for(auto&i:items)if(i.child==child.id){current.push_back(i);if(!bySource.emplace(i.source,i).second)duplicate=true;}
 bool loadedMatch=!duplicate&&current.size()==sources.size();
 for(size_t n=0;n<sources.size();++n){auto found=bySource.find(sources[n].item.guid);if(found==bySource.end()||readString(found->second.ptr,hashKey)!=hashes[n])loadedMatch=false;}
 bool cached=cache.count(child.id)&&cache[child.id].signature==signature;
 if((cached||loadedMatch)&&!duplicate&&current.size()==sources.size()){
  bool same=true;std::map<std::string,std::string>actual;
  for(auto&i:current){auto content=getChunk(i.ptr);if(content.empty()){error="Could not read child item state.";return false;}actual[i.guid]=lc::canonical(content);
   if(cached&&cache[child.id].chunks[i.guid]!=actual[i.guid])same=false;
   if(GetMediaItemInfo_Value(i.ptr,"C_LOCK")!=1){SetMediaItemInfo_Value(i.ptr,"C_LOCK",1);sceneChanged=true;}
   if(GetMediaItemInfo_Value(i.ptr,"I_GROUPID")!=child.group){SetMediaItemInfo_Value(i.ptr,"I_GROUPID",child.group);sceneChanged=true;}}
  for(auto&s:sources){auto f=bySource.find(s.item.guid);if(f==bySource.end()||f->second.track!=s.item.track||std::abs(f->second.position-(s.item.position+child.offset))>1e-9||!sameGains(f->second.ptr,s.gain))same=false;}
  if(same){cache[child.id]={signature,std::move(actual)};return true;}
 }
 std::vector<Ptr>targets;
 for(auto&s:sources){auto it=std::find(parent.tracks.begin(),parent.tracks.end(),s.item.trackId);if(it==parent.tracks.end())return false;
  size_t n=static_cast<size_t>(it-parent.tracks.begin());Ptr t=n<child.tracks.size()?track(child.tracks[n]):nullptr;
  if(!t){error="A destination track is missing. Move the container to existing tracks first.";return false;}
  if(s.item.position+child.offset<0){error="The linked copy would start before project zero.";return false;}targets.push_back(t);}
 struct Restore {Ptr item,track;std::string chunk;};std::vector<Restore>restore;std::vector<Ptr>created;std::set<Ptr>keep;
 bool ok=true;std::string failure;
 for(size_t n=0;n<sources.size();++n){auto&s=sources[n];auto found=bySource.find(s.item.guid);Ptr dst=nullptr;bool selected=false;
  bool contentUnchanged=false;
  if(found!=bySource.end()){
   dst=found->second.ptr;selected=found->second.selected;auto old=getChunk(dst);if(old.empty()){ok=false;break;}
   bool intact=!cache.count(child.id)||cache[child.id].chunks[found->second.guid]==lc::canonical(old);
   if(intact&&sameGains(dst,s.gain)&&readString(dst,hashKey)==hashes[n]&&found->second.track==targets[n]&&std::abs(found->second.position-(s.item.position+child.offset))<1e-9){SetMediaItemInfo_Value(dst,"C_LOCK",1);SetMediaItemInfo_Value(dst,"I_GROUPID",child.group);keep.insert(dst);continue;}
   contentUnchanged=intact&&(readString(dst,contentKey)==contents[n]||readString(dst,payloadKey)==payloads[n]);
   restore.push_back({dst,found->second.track,old});
  }else {dst=AddMediaItemToTrack(targets[n]);if(!dst){ok=false;break;}created.push_back(dst);}
  auto chunk=lc::cloneChunk(s.chunk,child.id+"|"+s.item.guid);
  bool wroteChunk=!contentUnchanged;
  if(wroteChunk&&!SetItemStateChunk(dst,chunk.c_str(),false)){failure="REAPER rejected the copied item state.";ok=false;break;}
  if(!applyGains(dst,s.gain)){failure="Could not apply the live item/take gain.";ok=false;break;}
  if(!ensureTrack(dst,targets[n])){failure="REAPER could not move the copied item to its destination track.";ok=false;break;}
  writeString(dst,"GUID",lc::mappedGuid(child.id,s.item.guid));writeString(dst,parentKey,"");writeString(dst,childKey,child.id);writeString(dst,sourceKey,s.item.guid);writeString(dst,hashKey,hashes[n]);writeString(dst,contentKey,contents[n]);writeString(dst,payloadKey,payloads[n]);writeString(dst,"P_EXT:LINKED_ITEMS_V1","");
  SetMediaItemInfo_Value(dst,"D_POSITION",s.item.position+child.offset);SetMediaItemInfo_Value(dst,"C_LOCK",1);SetMediaItemInfo_Value(dst,"I_GROUPID",child.group);SetMediaItemSelected(dst,selected);if(wroteChunk)hideChildFxWindows(dst);keep.insert(dst);
 }
 if(!ok){for(auto&r:restore){SetItemStateChunk(r.item,r.chunk.c_str(),false);ensureTrack(r.item,r.track);}for(auto i:created)DeleteTrackMediaItem(GetMediaItemTrack(i),i);error=(failure.empty()?"Could not update a linked copy.":failure)+std::string(" The previous copy was preserved.");return false;}
 for(auto&i:current)if(!keep.count(i.ptr)){DeleteTrackMediaItem(i.track,i.ptr);sceneChanged=true;}
 if(!restore.empty()||!created.empty())sceneChanged=true;
 Cache c;c.signature=signature;for(auto&i:scan())if(i.child==child.id){auto content=getChunk(i.ptr);if(!content.empty())c.chunks[i.guid]=lc::canonical(content);}cache[child.id]=std::move(c);return true;
}
void sync(bool force){
 if(busy)return;Ptr p=EnumProjects(-1,nullptr,0);if(!p)return;
 if(p!=project){if(containerDragActive)endDrag();project=p;reset=true;selectedContainer.clear();containerSelectionCleared=false;}
 // Undo restores extension state through ProjectStateContext, not through
 // SetProjExtState's file-persistence store. Apply only after native item/track
 // restoration is finished, before synchronization can recreate any children.
 auto restored=undoManifests.find(p);if(restored!=undoManifests.end()){
  SetProjExtState(p,"LINKED_CONTAINERS","MANIFEST_V2",restored->second.c_str());undoManifests.erase(restored);reset=true;selectedContainer.clear();containerSelectionCleared=false;selectionAtClear.clear();
 }
 bool justLoaded=reset;
 if(reset){persisted=readManifest();unknownManifest=!persisted.empty()&&persisted.rfind("LC2\n",0)!=0;manifest=unknownManifest?lc::Manifest{}:lc::decode(persisted);cache.clear();reset=false;}
 if(unknownManifest){error="Unsupported container metadata version. Project data was not changed.";return;}
 busy=true;error.clear();sceneChanged=false;PreventUIRefresh(1);
 auto items=scan();if(justLoaded){viewItems=items;for(auto&i:items)if(manifest.children.count(i.child))hideChildFxWindows(i.ptr);}
 // One physical row per container. Keep off-row originals intact; only the
 // anchor track participates. Historical multi-row metadata is normalized.
 for(auto&[_,parent]:manifest.parents)if(parent.tracks.size()>1)parent.tracks.resize(1);
 std::map<std::string,Item>prior;for(auto&i:viewItems)prior[i.guid]=i;
 // Items created/split inside exactly one existing parent window join it.
 // Explicit parent tags survive ordinary REAPER splits; window discovery also
 // handles host operations that create a new item without copying extension data.
 for(auto&i:items)if(i.parent.empty()&&i.child.empty()&&readString(i.ptr,"P_EXT:LC2_EXCLUDED")!="1"){
  std::vector<std::string>matches;for(auto&[id,parent]:manifest.parents)if(i.position>=parent.start-1e-8&&i.position+i.length<=parent.end+1e-8&&std::find(parent.tracks.begin(),parent.tracks.end(),i.trackId)!=parent.tracks.end()){
   auto old=prior.find(i.guid);bool alreadyInside=old!=prior.end()&&old->second.parent.empty()&&old->second.child.empty()&&old->second.position>=parent.start-1e-8&&old->second.position+old->second.length<=parent.end+1e-8&&std::find(parent.tracks.begin(),parent.tracks.end(),old->second.trackId)!=parent.tracks.end();
   if(!alreadyInside)matches.push_back(id);
  }
  if(matches.size()==1){i.parent=matches.front();writeString(i.ptr,parentKey,i.parent);writeString(i.ptr,"P_EXT:LINKED_ITEMS_V1","");SetMediaItemInfo_Value(i.ptr,"I_GROUPID",manifest.parents[i.parent].group);}
 }
 std::map<std::string,std::vector<Source>>source;
 for(auto&i:items)if(manifest.parents.count(i.parent)&&i.child.empty()){
  auto chunk=getChunk(i.ptr);if(chunk.empty()){error="Could not read parent item state; linked copies were not changed.";PreventUIRefresh(-1);busy=false;return;}source[i.parent].push_back({i,std::move(chunk),gains(i.ptr)});
 }
 for(auto&[id,parent]:manifest.parents){auto&s=source[id];if(!s.empty()){
  // The frame is a persistent container window, not the current bounding box
  // of the remaining fragments. Deleting/trimming edge pieces leaves silence.
  bool whole=!containerDragActive;double delta=0;int rows=0;size_t oldCount=0;
  for(auto&[_,old]:prior)if(old.parent==id&&old.child.empty())oldCount++;
  whole&=oldCount==s.size();bool first=true;
  for(auto&i:s){auto old=prior.find(i.item.guid);if(old==prior.end()){whole=false;break;}
   double d=i.item.position-old->second.position;int r=trackIndex(i.item.track)-trackIndex(old->second.track);
   if(first){delta=d;rows=r;first=false;}else if(std::abs(delta-d)>1e-8||rows!=r)whole=false;
   if(std::abs(i.item.length-old->second.length)>1e-8)whole=false;
  }
  if(whole&&(std::abs(delta)>1e-9||rows)){
   double earliest=parent.start;for(auto&[_,child]:manifest.children)if(child.parent==id)earliest=std::min(earliest,parent.start+child.offset);
   double allowed=std::max(delta,-earliest);
   std::string requestedTrack=parent.tracks.front();int destination=trackIndex(track(requestedTrack))+rows;
   if(rows&&destination>=0&&ensureTrackCount(destination+1))requestedTrack=trackId(GetTrack(project,destination));
   bool correctedTime=std::abs(allowed-delta)>1e-9;
   for(auto&i:s){
    if(correctedTime){i.item.position+=allowed-delta;SetMediaItemInfo_Value(i.item.ptr,"D_POSITION",i.item.position);}
    if(i.item.trackId!=requestedTrack){ensureTrack(i.item.ptr,track(requestedTrack));i.item.track=track(requestedTrack);i.item.trackId=requestedTrack;}
    // Source chunks must reflect corrected position/track before mirroring.
    if(correctedTime)i.chunk=getChunk(i.item.ptr);
   }
   parent.start+=allowed;parent.end+=allowed;parent.tracks={requestedTrack};
  }
  std::sort(s.begin(),s.end(),[](auto&a,auto&b){return a.item.guid<b.item.guid;});
 }}
 for(auto&[_,child]:manifest.children){auto it=manifest.parents.find(child.parent);if(it!=manifest.parents.end()){
  auto visible=source[child.parent];auto&window=it->second;
  // Track placement belongs to the parent; copies only own a time offset.
  child.tracks=window.tracks;
  visible.erase(std::remove_if(visible.begin(),visible.end(),[&](const Source&s){return s.item.trackId!=window.tracks.front()||s.item.position<window.start-1e-9||s.item.position+s.item.length>window.end+1e-9;}),visible.end());
  rebuild(child,window,visible,items);
 }}
 saveManifest();viewItems=scan();lastState=GetProjectStateChangeCount(project);lastUndo=Undo_GetCurEntry(project);quickState=quick();
 PreventUIRefresh(-1);busy=false;if(force||sceneChanged)UpdateArrange();
}
std::vector<Box>boxes(){std::vector<Box>out;for(auto&[id,p]:manifest.parents){
 if(p.tracks.empty())continue;Ptr tr=track(p.tracks.front());if(!tr)continue;
 double y=GetMediaTrackInfo_Value(tr,"I_TCPY"),h=GetMediaTrackInfo_Value(tr,"I_TCPH");if(h<=0)continue;
 Box b;b.id=id;b.parent=id;b.start=p.start;b.end=p.end;b.top=y;b.bottom=y+h;out.push_back(b);
 for(auto&[cid,c]:manifest.children)if(c.parent==id){Box cb=b;cb.id=cid;cb.child=true;cb.start+=c.offset;cb.end+=c.offset;out.push_back(cb);}
 }return out;}
Action actions[]={
 {0,"mixolve_linked_items_copy","mixolve_linked-items: create linked copy at edit cursor",nullptr},
 {0,"mixolve_linked_items_select_parent","mixolve_linked-items: select parent",nullptr},
 {0,"mixolve_linked_items_move","mixolve_linked-items: move selected container to edit cursor",nullptr},
 {0,"mixolve_linked_items_detach","mixolve_linked-items: detach selected child container",nullptr},
 {0,"mixolve_linked_items_delete","mixolve_linked-items: delete selected container",nullptr},
 {0,"mixolve_linked_items_add","mixolve_linked-items: add selected items to parent container",nullptr},
 {0,"mixolve_linked_items_duplicate_next","mixolve_linked-items: duplicate selected container immediately after itself",nullptr},
 {0,"mixolve_linked_items_deselect","mixolve_linked-items: deselect container",nullptr}};
constexpr int actionCount=8;
int commands[actionCount]{};
void detachItem(const Item&i){writeString(i.ptr,childKey,"");writeString(i.ptr,sourceKey,"");writeString(i.ptr,hashKey,"");writeString(i.ptr,contentKey,"");writeString(i.ptr,payloadKey,"");writeString(i.ptr,"P_EXT:LC2_EXCLUDED","1");SetMediaItemInfo_Value(i.ptr,"C_LOCK",0);SetMediaItemInfo_Value(i.ptr,"I_GROUPID",0);}
void deleteContainer(const std::string&id){
 auto items=scan();bool parent=manifest.parents.count(id),child=manifest.children.count(id);if(!parent&&!child)return;
 Undo_BeginBlock2(project);busy=true;PreventUIRefresh(1);
 std::vector<std::string>detach;for(auto&[cid,c]:manifest.children)if(parent&&c.parent==id)detach.push_back(cid);
 for(auto&i:items){
  if((child&&i.child==id)||(parent&&participates(i,id)))DeleteTrackMediaItem(i.track,i.ptr);
  else if(parent&&std::find(detach.begin(),detach.end(),i.child)!=detach.end())detachItem(i);
  else if(parent&&i.parent==id){writeString(i.ptr,parentKey,"");writeString(i.ptr,"P_EXT:LC2_EXCLUDED","1");SetMediaItemInfo_Value(i.ptr,"I_GROUPID",0);}
 }
 for(auto&cid:detach){manifest.children.erase(cid);cache.erase(cid);}if(child){manifest.children.erase(id);cache.erase(id);}if(parent)manifest.parents.erase(id);
 selectContainer({});saveManifest();PreventUIRefresh(-1);busy=false;sync(true);Undo_EndBlock2(project,"Linked containers: Delete container",1|4|8);overlayTick();
}
void action(int which,const std::string&target){
 if(which==7){endDrag();selectContainer({});UpdateArrange();overlayTick();return;}
 endDrag();sync();if(!project)return;if(unknownManifest){ShowMessageBox(error.c_str(),"Linked containers",0);return;}auto items=scan();std::string id=(manifest.parents.count(target)||manifest.children.count(target))?target:selection(items);
 bool duplicateNext=which==6;
 if(duplicateNext&&target.empty()&&containerSelectionCleared){if(nativeSelection()==selectionAtClear)return;containerSelectionCleared=false;}
 if(duplicateNext&&id.empty()&&(manifest.parents.count(selectedContainer)||manifest.children.count(selectedContainer)))id=selectedContainer;
 if(duplicateNext&&id.empty())return;
 double duplicateStart=0;
 if(duplicateNext){auto child=manifest.children.find(id);auto parent=manifest.parents.find(child==manifest.children.end()?id:child->second.parent);if(parent==manifest.parents.end())return;duplicateStart=parent->second.end+(child==manifest.children.end()?0:child->second.offset);}
 if(which==1){if(manifest.children.count(id))id=manifest.children[id].parent;if(!manifest.parents.count(id))return;for(auto&i:items)SetMediaItemSelected(i.ptr,participates(i,id));selectContainer(id);UpdateArrange();return;}
 if(which==2){if(id.empty())return;double pos=GetCursorPositionEx(project);beginDrag(id);dragTo(pos);endDrag();return;}
 if(which==5){
  if(!manifest.parents.count(id)){ShowMessageBox("Select a parent item and the ordinary items to add.","Linked containers",0);return;}
  for(auto&i:items)if(i.selected&&i.child.empty()&&(i.parent.empty()||i.parent==id)&&i.trackId!=manifest.parents[id].tracks.front()){
   ShowMessageBox("Only items on the parent track can be added.","Linked containers",0);return;
  }
  Undo_BeginBlock2(project);busy=true;PreventUIRefresh(1);
  for(auto&i:items)if(i.selected&&i.child.empty()&&(i.parent.empty()||i.parent==id)){
   manifest.parents[id].start=std::min(manifest.parents[id].start,i.position);manifest.parents[id].end=std::max(manifest.parents[id].end,i.position+i.length);
   writeString(i.ptr,parentKey,id);writeString(i.ptr,"P_EXT:LC2_EXCLUDED","");writeString(i.ptr,"P_EXT:LINKED_ITEMS_V1","");SetMediaItemInfo_Value(i.ptr,"I_GROUPID",0);
  }
  PreventUIRefresh(-1);busy=false;sync(true);Undo_EndBlock2(project,actions[5].name,1|4|8);return;
 }
 if(which==4){deleteContainer(id);return;}
 if(which==3){auto it=manifest.children.find(id);if(it==manifest.children.end())return;Undo_BeginBlock2(project);busy=true;PreventUIRefresh(1);
  for(auto&i:items)if(i.child==id){{writeString(i.ptr,childKey,"");writeString(i.ptr,sourceKey,"");writeString(i.ptr,hashKey,"");writeString(i.ptr,contentKey,"");writeString(i.ptr,payloadKey,"");writeString(i.ptr,"P_EXT:LC2_EXCLUDED","1");SetMediaItemInfo_Value(i.ptr,"C_LOCK",0);SetMediaItemInfo_Value(i.ptr,"I_GROUPID",0);}}
  manifest.children.erase(id);cache.erase(id);selectedContainer.clear();saveManifest();PreventUIRefresh(-1);busy=false;Undo_EndBlock2(project,actions[which].name,1|4|8);sync(true);return;}
 std::vector<Item>selected;for(auto&i:items)if(i.selected)selected.push_back(i);
 bool newParent=!manifest.parents.count(id)&&!manifest.children.count(id);
 if(newParent&&selected.empty())return;
 if(newParent)for(auto&i:selected)if(!i.parent.empty()||!i.child.empty()){ShowMessageBox("Select items from one parent container, or select ordinary items to create a parent.","Linked containers",0);return;}
 if(newParent)for(auto&i:selected)if(i.track!=selected.front().track){ShowMessageBox("Select source items on one track.","Linked containers",0);return;}
 lc::Parent parent;
 if(newParent){parent.id=uuid();parent.group=0;parent.start=1e15;
  std::map<int,std::string>tracks;for(auto&i:selected){parent.start=std::min(parent.start,i.position);parent.end=std::max(parent.end,i.position+i.length);tracks[trackIndex(i.track)]=i.trackId;}
  if(!tracks.empty())for(int n=tracks.begin()->first;n<=tracks.rbegin()->first;n++)parent.tracks.push_back(trackId(GetTrack(project,n)));
 }else {if(manifest.children.count(id))id=manifest.children[id].parent;parent=manifest.parents[id];}
 if(newParent)parent.end=std::max(parent.end,minimumContainerEdge(parent.start,1));
 Ptr destination=track(parent.tracks.front());
 double offset=(duplicateNext?duplicateStart:GetCursorPositionEx(project))-parent.start;
 if(!destination||trackIndex(destination)<0||!std::isfinite(offset)||!nextGroup(items)){ShowMessageBox("The parent track or linked-copy position is invalid.","Linked containers",0);return;}
 auto oldManifest=manifest;std::vector<std::pair<Ptr,std::string>>oldSources;
 if(newParent)for(auto&i:items)if(i.selected||(i.parent.empty()&&i.child.empty()&&i.position>=parent.start-1e-8&&i.position+i.length<=parent.end+1e-8&&std::find(parent.tracks.begin(),parent.tracks.end(),i.trackId)!=parent.tracks.end())){
  auto chunk=getChunk(i.ptr);if(chunk.empty()){ShowMessageBox("Could not read source item state.","Linked containers",0);return;}oldSources.emplace_back(i.ptr,std::move(chunk));}
 Undo_BeginBlock2(project);busy=true;PreventUIRefresh(1);
 if(newParent){manifest.parents[parent.id]=parent;for(auto&i:selected){writeString(i.ptr,parentKey,parent.id);writeString(i.ptr,"P_EXT:LC2_EXCLUDED","");writeString(i.ptr,"P_EXT:LINKED_ITEMS_V1","");SetMediaItemInfo_Value(i.ptr,"I_GROUPID",parent.group);}}
 lc::Child child;child.id=uuid();child.parent=parent.id;child.offset=offset;child.tracks=parent.tracks;child.group=nextGroup(scan());manifest.children[child.id]=child;
 saveManifest();PreventUIRefresh(-1);busy=false;sync(true);
 if(!error.empty()){std::string message=error;busy=true;
  for(auto&i:scan())if(i.child==child.id)DeleteTrackMediaItem(i.track,i.ptr);
  for(auto&[ptr,chunk]:oldSources)SetItemStateChunk(ptr,chunk.c_str(),false);
  manifest=std::move(oldManifest);cache.erase(child.id);saveManifest();busy=false;
  ShowMessageBox(message.c_str(),"Linked containers",0);
 }else{
  selectContainer(child.id);for(auto&i:scan())SetMediaItemSelected(i.ptr,i.child==child.id);
 }
 Undo_EndBlock2(project,actions[duplicateNext?6:0].name,1|4|8);overlayTick();
}
void toggleChildItemMute(const std::string&id,const std::string&source){
 endDrag();sync();auto child=manifest.children.find(id);if(child==manifest.children.end())return;
 bool exists=false;for(auto&i:scan())if(i.child==id&&i.source==source){exists=true;break;}if(!exists)return;
 auto before=manifest;Undo_BeginBlock2(project);
 if(!child->second.muted.erase(source))child->second.muted.insert(source);
 saveManifest();sync(true);
 if(!error.empty()){auto failure=error;manifest=before;saveManifest();sync(true);ShowMessageBox(failure.c_str(),"Linked containers",0);}
 Undo_EndBlock2(project,"Linked containers: Toggle local item mute",1|4|8);overlayTick();
}
struct Drag {bool active=false,changed=false,copy=false,copyFailed=false;std::string copyId,failure;int edge=0;Ptr owner=nullptr;std::string id,parent;double origin=0,offset=0,end=0;std::vector<Item>items;std::vector<std::string>tracks;std::set<Ptr>members;};Drag drag;
void beginDrag(const std::string&id,bool copy){if(drag.active)endDrag();sync();auto ci=manifest.children.find(id);std::string pid=ci==manifest.children.end()?id:ci->second.parent;if(!manifest.parents.count(pid))return;
 drag={};drag.active=true;drag.copy=copy;drag.owner=project;drag.id=id;drag.parent=pid;drag.items=scan();drag.origin=manifest.parents[pid].start+(ci!=manifest.children.end()?ci->second.offset:0);drag.offset=ci!=manifest.children.end()?ci->second.offset:0;drag.tracks=ci!=manifest.children.end()?ci->second.tracks:manifest.parents[pid].tracks;drag.end=manifest.parents[pid].end;for(auto&i:drag.items)if(participates(i,pid))drag.members.insert(i.ptr);containerDragActive=true;selectContainer(id);Undo_BeginBlock2(project);}
void dragTo(double position,int targetTrack){if(!drag.active||!std::isfinite(position))return;if(EnumProjects(-1,nullptr,0)!=drag.owner){endDrag();return;}double delta=std::max(0.0,position)-drag.origin;
 if(drag.copy){
  if(drag.copyFailed||(!drag.changed&&std::abs(delta)<1e-9))return;
  auto&parent=manifest.parents[drag.parent];
  double accepted=std::max(0.0,position);
  if(drag.copyId.empty()){int group=nextGroup(scan());if(!group){drag.copyFailed=true;drag.failure="No item group is available for the linked copy.";return;}
   lc::Child c;c.id=uuid();c.parent=drag.parent;c.tracks=parent.tracks;c.group=group;drag.copyId=c.id;manifest.children[c.id]=c;}
  manifest.children[drag.copyId].offset=accepted-parent.start;drag.changed=true;saveManifest();sync(true);
  if(!error.empty()){drag.failure=error;drag.copyFailed=true;busy=true;for(auto&i:scan())if(i.child==drag.copyId)DeleteTrackMediaItem(i.track,i.ptr);manifest.children.erase(drag.copyId);cache.erase(drag.copyId);saveManifest();busy=false;drag.changed=false;sync(true);}
  else selectContainer(drag.copyId);
  return;
 }
if(std::abs(delta)>1e-9||targetTrack>=0)drag.changed=true;auto child=manifest.children.find(drag.id);
 busy=true;PreventUIRefresh(1);
 if(child!=manifest.children.end()){
  double earliest=drag.origin;for(auto&i:drag.items)if(i.child==drag.id)earliest=std::min(earliest,i.position);delta=std::max(delta,-earliest);
  child->second.offset=drag.offset+delta;
  child->second.tracks=manifest.parents[drag.parent].tracks;
 }else {
  auto&parent=manifest.parents[drag.parent];double earliest=drag.origin;
  for(auto&i:drag.items)if(drag.members.count(i.ptr))earliest=std::min(earliest,i.position);
  for(auto&[_,c]:manifest.children)if(c.parent==drag.parent){earliest=std::min(earliest,drag.origin+c.offset);for(auto&i:drag.items)if(drag.members.count(i.ptr))earliest=std::min(earliest,i.position+c.offset);}
  delta=std::max(delta,-earliest);
  int base=drag.tracks.empty()?-1:trackIndex(track(drag.tracks.front()));bool canMove=targetTrack>=0&&base>=0;
  auto translate=[&](const std::vector<std::string>&ids,int amount){std::vector<std::string>out;for(auto&t:ids){int n=trackIndex(track(t))+amount;if(n<0||!ensureTrackCount(n+1))return std::vector<std::string>{};out.push_back(trackId(GetTrack(project,n)));}return out;};
  auto nextTracks=canMove?translate(drag.tracks,targetTrack-base):std::vector<std::string>{};canMove&=!nextTracks.empty();
  parent.start=drag.origin+delta;parent.end=drag.end+delta;
  int acceptedTrack=canMove?trackIndex(track(nextTracks.front())):-1;
  for(auto&i:drag.items)if(drag.members.count(i.ptr)){
   SetMediaItemInfo_Value(i.ptr,"D_POSITION",i.position+delta);
   if(canMove&&acceptedTrack>=0)ensureTrack(i.ptr,GetTrack(project,acceptedTrack));}
  if(canMove)parent.tracks=std::move(nextTracks);
 }
 saveManifest();PreventUIRefresh(-1);busy=false;sync(true);
}
double minimumContainerEdge(double fixed,int edge){
 int beatsPerBar=4;
 // At a left-resize fixed end exactly on a meter change, use the bar on
 // the container's inside (immediately before that end).
 double inside=edge<0?std::max(0.0,std::nextafter(fixed,-INFINITY)):fixed;
 TimeMap2_timeToBeats(project,inside,nullptr,&beatsPerBar,nullptr,nullptr);
 double beat=TimeMap2_timeToBeats(project,fixed,nullptr,nullptr,nullptr,nullptr);
 return TimeMap2_beatsToTime(project,beat+edge*std::max(1,beatsPerBar),nullptr);
}
void beginResize(const std::string&id,int edge){
 endDrag();sync();if(!manifest.parents.count(id)||(edge!=-1&&edge!=1))return;
 beginDrag(id);if(drag.active)drag.edge=edge;
}
bool resizing(){return drag.active&&drag.edge!=0;}
void resizeTo(double position){
 if(!resizing()||!std::isfinite(position))return;
 if(EnumProjects(-1,nullptr,0)!=drag.owner){endDrag();return;}
 if(GetToggleCommandStateEx(0,1157)==1)position=SnapToGrid(project,position);
 if(!std::isfinite(position))return;
 double widthLimit=minimumContainerEdge(drag.edge<0?drag.end:drag.origin,drag.edge);
 position=drag.edge<0?std::min(position,widthLimit):std::max(position,widthLimit);
 auto&parent=manifest.parents[drag.parent];double minimum=0;
 for(auto&[_,child]:manifest.children)if(child.parent==drag.parent)minimum=std::max(minimum,-child.offset);
 if(drag.edge<0){if(position<minimum||position>=drag.end-1e-9)return;if(std::abs(parent.start-position)<1e-9)return;parent.start=position;parent.end=drag.end;}
 else {if(position<=drag.origin+1e-9)return;if(std::abs(parent.end-position)<1e-9)return;parent.start=drag.origin;parent.end=position;}
 drag.changed=true;saveManifest();sync(true);overlayTick();
}

void endDrag(){if(!drag.active)return;
 if(EnumProjects(-1,nullptr,0)==drag.owner)sync(true);
 bool open=false;for(int n=0;n<10000;++n){Ptr p=EnumProjects(n,nullptr,0);if(!p)break;if(p==drag.owner){open=true;break;}}
 if(open)Undo_EndBlock2(drag.owner,drag.copy?"Linked containers: Duplicate linked container":drag.edge?"Linked containers: Resize parent container":"Linked containers: Move container",drag.changed?1|4|8:0);
 std::string failure=drag.failure;drag={};containerDragActive=false;if(!failure.empty())ShowMessageBox(failure.c_str(),"Linked containers",0);
}
Ptr(*araTakeItem)(Ptr)=nullptr;
bool araChild(Ptr take){Ptr item=araTakeItem?araTakeItem(take):nullptr;return item&&!readString(item,childKey).empty();}
bool araVisible(Ptr track){return GetMediaTrackInfo_Value(track,"B_SHOWINTCP")!=0||GetMediaTrackInfo_Value(track,"B_SHOWINMIXER")!=0;}
void araTick(){if(!araTakeItem)return;std::vector<Ptr>projects;for(int n=0;n<10000;n++){Ptr p=EnumProjects(n,nullptr,0);if(!p)break;projects.push_back(p);}ara_filter::poll(projects,araChild,araVisible);}
void tick(){if(busy)return;double t=time_precise();if(t-lastTick<1.0/60.0)return;lastTick=t;
 Ptr p=EnumProjects(-1,nullptr,0);if(p!=project||reset||GetProjectStateChangeCount(p)!=lastState||(!manifest.parents.empty()&&(quick()!=quickState||!error.empty())))sync();araTick();overlayTick();}
bool nativeContainerDelete(int id){
 if(forwarding||busy||!containerOperationFocus||selectedContainer.empty()||!containerInputFocused())return false;
 bool item=id==40006,contextual=id==40184;
 if(!item&&!contextual)return false;if(contextual&&GetCursorContext2(true)!=1)return false;
 auto target=selectedContainer;endDrag();sync();if(!manifest.parents.count(target)&&!manifest.children.count(target))return false;deleteContainer(target);return true;
}
// Native track duplication copies P_EXT item tags verbatim. Isolate the whole
// operation from sync, then give each duplicated track its own container family.
// Temporary provenance fields exist only within this single undo transaction.
bool duplicateTracks(int commandID,int flags){
 sync();if(!project||manifest.parents.empty())return false;
 const char *trackMarker="P_EXT:MIXOLVE_DUPLICATE_TRACK_SOURCE",*itemMarker="P_EXT:MIXOLVE_DUPLICATE_ITEM_SOURCE";
 auto trackText=[&](Ptr t,const std::string&text,bool set){char buffer[4096]{};if(set)std::snprintf(buffer,sizeof(buffer),"%s",text.c_str());GetSetMediaTrackInfo_String(t,trackMarker,buffer,set);return std::string(buffer);};
 struct Origin {Ptr ptr;std::string marker;};std::map<std::string,Origin>origins;
 bool relevant=false;
 for(int n=0;;n++){Ptr t=GetSelectedTrack(project,n);if(!t)break;auto id=trackId(t);origins[id]={t,trackText(t,"",false)};for(auto&[_,p]:manifest.parents)if(!p.tracks.empty()&&p.tracks.front()==id)relevant=true;}
 if(!relevant)return false;
 auto before=manifest;auto items=scan();std::set<std::string>knownTracks;
 for(int n=0;n<CountTracks(project);n++)knownTracks.insert(trackId(GetTrack(project,n)));
 std::map<std::string,std::string>previousItemMarkers;
 Undo_BeginBlock2(project);busy=true;
 for(auto&[id,origin]:origins)trackText(origin.ptr,id,true);
 for(auto&i:items)if(origins.count(i.trackId)&&before.parents.count(i.parent)&&i.child.empty()){
  previousItemMarkers[i.guid]=readString(i.ptr,itemMarker);writeString(i.ptr,itemMarker,i.guid);
 }
 forwarding=true;Main_OnCommand(commandID,flags);forwarding=false;
 auto copies=scan();bool changed=false;std::set<std::string>copySelections;
 for(int n=0;n<CountTracks(project);n++){
  Ptr destination=GetTrack(project,n);std::string destinationId=trackId(destination);
  if(knownTracks.count(destinationId))continue;
  std::string sourceTrack=trackText(destination,"",false);auto origin=origins.find(sourceTrack);if(origin==origins.end())continue;
  std::map<std::string,std::string>sourceIDs,parentIDs,childIDs;
  for(auto&i:copies)if(i.trackId==destinationId&&before.parents.count(i.parent)&&i.child.empty()){
   auto source=readString(i.ptr,itemMarker);if(!source.empty())sourceIDs[source]=i.guid;
  }
  for(auto&[id,parent]:before.parents)if(!parent.tracks.empty()&&parent.tracks.front()==sourceTrack){
   auto clone=parent;clone.id=uuid();clone.tracks={destinationId};parentIDs[id]=clone.id;manifest.parents[clone.id]=clone;
  }
  for(auto&[id,child]:before.children)if(parentIDs.count(child.parent)){
   auto clone=child;clone.id=uuid();clone.parent=parentIDs.at(child.parent);clone.tracks={destinationId};clone.group=nextGroup(scan());clone.muted.clear();
   for(auto&source:child.muted)if(sourceIDs.count(source))clone.muted.insert(sourceIDs.at(source));
   childIDs[id]=clone.id;manifest.children[clone.id]=clone;
   // Reserve this group's number before cloning the next child.
   for(auto&i:copies)if(i.trackId==destinationId&&i.child==id)SetMediaItemInfo_Value(i.ptr,"I_GROUPID",clone.group);
  }
  for(auto&i:copies)if(i.trackId==destinationId){
   if(childIDs.count(i.child)){
    writeString(i.ptr,childKey,childIDs.at(i.child));writeString(i.ptr,parentKey,"");if(i.selected)copySelections.insert(childIDs.at(i.child));
    if(sourceIDs.count(i.source))writeString(i.ptr,sourceKey,sourceIDs.at(i.source));
    for(auto key:{hashKey,contentKey,payloadKey})writeString(i.ptr,key,"");
   }else if(parentIDs.count(i.parent)){
    writeString(i.ptr,parentKey,parentIDs.at(i.parent));writeString(i.ptr,childKey,"");writeString(i.ptr,sourceKey,"");if(i.selected)copySelections.insert(parentIDs.at(i.parent));
   }
   auto source=readString(i.ptr,itemMarker);if(!source.empty())writeString(i.ptr,itemMarker,previousItemMarkers.count(source)?previousItemMarkers.at(source):"");
  }
  trackText(destination,origin->second.marker,true);changed|=!parentIDs.empty();
 }
 for(auto&[id,origin]:origins)trackText(origin.ptr,origin.marker,true);
 for(auto&i:items)if(previousItemMarkers.count(i.guid))writeString(i.ptr,itemMarker,previousItemMarkers.at(i.guid));
 if(changed){selectContainer(copySelections.size()==1?*copySelections.begin():std::string{},false);saveManifest();}
 busy=false;sync(true);Undo_EndBlock2(project,"Track: Duplicate tracks",1|2|4|8);overlayTick();return true;
}
bool command(int id,int flags){for(int n=0;n<actionCount;++n)if(id==commands[n]){action(n);return true;}
 if(nativeContainerDelete(id))return true;
 if(forwarding||busy)return false;if(drag.active)endDrag();if(id==40029||id==40030)return false;const char*label=kbd_getTextFromCmd(id,nullptr);if(!label)return false;
 if(!std::strncmp(label,"File: Save",10)||!std::strncmp(label,"File: Close",11)){sync(true);return false;}
 if(!std::strcmp(label,"Track: Duplicate tracks")&&duplicateTracks(id,flags))return true;
 bool edits=!std::strncmp(label,"Item:",5)||!std::strncmp(label,"Item edit:",10)||!std::strncmp(label,"Take:",5)||!std::strncmp(label,"Item properties:",16);
 if(!edits)return false;sync();bool relevant=false,childOnly=true;
 for(auto&i:scan())if(i.selected){bool child=manifest.children.count(i.child);bool parent=manifest.parents.count(i.parent)&&!child;relevant|=child||parent;if(!child)childOnly=false;}
 if(!relevant)return false;
 // Child contents cannot be edited, deleted or opened in an item/take editor.
 // Selection-only native actions remain available; the copy is manipulated by
 // its container handle and explicit container actions instead.
 if(childOnly&&!std::strstr(label,"Select")&&!std::strstr(label,"select"))return true;
 std::string name=label;Undo_BeginBlock2(project);forwarding=true;Main_OnCommand(id,flags);forwarding=false;sync(true);Undo_EndBlock2(project,name.c_str(),1|4|8);return true;
}
bool command2(Ptr section,int id,int,int,int,Ptr){if((!section||*static_cast<int*>(section)==0)&&nativeContainerDelete(id))return true;for(int n=0;n<actionCount;++n)if(id==commands[n]){action(n);return true;}return false;}
void afterCommand(int id,int){if(forwarding||busy)return;if(id==40029||id==40030)reset=true;sync();overlayTick();}
Ptr configProject(){Ptr p=GetCurrentProjectInLoadSave?GetCurrentProjectInLoadSave():nullptr;return p?p:EnumProjects(-1,nullptr,0);}
constexpr const char*undoHeader="<MIXOLVE_LINKED_CONTAINERS_UNDO_V2";
void saveConfig(void*context,bool isUndo,ProjectConfig*){
 if(!isUndo||!context)return;Ptr p=configProject();if(!p)return;
 auto pending=undoManifests.find(p);std::string state=pending==undoManifests.end()?readManifest(p):pending->second;
 auto*ctx=static_cast<ProjectStateContext*>(context);ctx->AddLine("%s",undoHeader);
 constexpr char hex[]="0123456789ABCDEF";
 for(size_t offset=0;offset<state.size();offset+=256){std::string line="DATA ";for(size_t n=offset;n<std::min(state.size(),offset+256);n++){unsigned char c=state[n];line+=hex[c>>4];line+=hex[c&15];}ctx->AddLine("%s",line.c_str());}
 ctx->AddLine(">");
}
bool readConfig(const char*line,void*context,bool isUndo,ProjectConfig*){
 if(!isUndo||!line||lc::trim(line)!=undoHeader||!context)return false;
 auto*ctx=static_cast<ProjectStateContext*>(context);char buffer[1024]{};std::string state;bool valid=true,closed=false;
 auto digit=[](char c){if(c>='0'&&c<='9')return c-'0';if(c>='A'&&c<='F')return c-'A'+10;if(c>='a'&&c<='f')return c-'a'+10;return -1;};
 while(ctx->GetLine(buffer,sizeof(buffer))>=0){auto text=lc::trim(buffer);if(text==">"){closed=true;break;}
  if(text.rfind("DATA ",0)!=0){valid=false;continue;}auto data=text.substr(5);if(data.size()%2||state.size()+data.size()/2>16*1024*1024){valid=false;continue;}
  for(size_t n=0;n<data.size();n+=2){int high=digit(data[n]),low=digit(data[n+1]);if(high<0||low<0){valid=false;break;}state+=static_cast<char>((high<<4)|low);}
 }
 if(Ptr p=configProject())undoManifests[p]=valid&&closed?state:readManifest(p);reset=true;return true;
}
void loadConfig(bool isUndo,ProjectConfig*){if(Ptr p=configProject()){if(isUndo)undoManifests[p]="";else undoManifests.erase(p);}reset=true;}

ProjectConfig config={readConfig,saveConfig,loadConfig,nullptr};
void unload(){if(!host)return;endDrag();ara_filter::shutdown();araTakeItem=nullptr;overlayRemove();host->reg("-timer",(Ptr)tick);host->reg("-hookcommand",(Ptr)command);host->reg("-hookcommand2",(Ptr)command2);host->reg("-hookpostcommand",(Ptr)afterCommand);host->reg("-projectconfig",&config);
 for(int n=0;n<actionCount;++n)if(commands[n]){host->reg("-custom_action",&actions[n]);commands[n]=0;}cache.clear();undoManifests.clear();manifest={};viewItems.clear();project=nullptr;selectedContainer.clear();containerSelectionCleared=false;reset=true;host=nullptr;}
}
extern "C" __attribute__((visibility("default"))) int ReaperPluginEntry(void*,Info*rec){using namespace engine;if(!rec){unload();return 0;}if(rec->version!=0x20e||!rec->reg||!rec->get)return 0;hostStorage=*rec;host=&hostStorage;
#define LOAD(name) name=reinterpret_cast<decltype(name)>(rec->get(#name));if(!name){host=nullptr;return 0;}
 LOAD(GetCursorContext2);LOAD(SetCursorContext);LOAD(GetCurrentProjectInLoadSave);LOAD(EnumProjects);LOAD(CountMediaItems);LOAD(GetMediaItem);LOAD(GetMediaItemInfo_Value);LOAD(SetMediaItemInfo_Value);LOAD(GetSetMediaItemInfo);LOAD(GetSetMediaItemInfo_String);LOAD(IsMediaItemSelected);LOAD(SetMediaItemSelected);
 LOAD(TakeFX_GetCount);LOAD(TakeFX_Show);
 LOAD(ValidatePtr2);LOAD(CountTakes);LOAD(GetTake);LOAD(GetMediaItemTakeInfo_Value);LOAD(SetMediaItemTakeInfo_Value);LOAD(GetMediaItemTrack);LOAD(MoveMediaItemToTrack);LOAD(AddMediaItemToTrack);LOAD(DeleteTrackMediaItem);LOAD(GetItemStateChunk);LOAD(SetItemStateChunk);
 LOAD(InsertTrackInProject);LOAD(TrackList_AdjustWindows);LOAD(CountTracks);LOAD(GetTrack);LOAD(GetSelectedTrack);LOAD(GetMediaTrackInfo_Value);LOAD(GetSetMediaTrackInfo_String);LOAD(GetTrackGUID);LOAD(genGuid);LOAD(guidToString);
 LOAD(GetProjExtState);LOAD(SetProjExtState);LOAD(GetCursorPositionEx);LOAD(GetProjectStateChangeCount);LOAD(Undo_BeginBlock2);LOAD(Undo_EndBlock2);LOAD(Undo_GetCurEntry);LOAD(PreventUIRefresh);LOAD(UpdateArrange);LOAD(Main_OnCommand);LOAD(kbd_getTextFromCmd);LOAD(ShowMessageBox);LOAD(time_precise);
 LOAD(TimeMap2_timeToBeats);LOAD(TimeMap2_beatsToTime);
 LOAD(GetMouseModifier);LOAD(GetMainHwnd);LOAD(GetSet_ArrangeView2);LOAD(SnapToGrid);LOAD(GetToggleCommandStateEx);
#undef LOAD
 araTakeItem=reinterpret_cast<decltype(araTakeItem)>(rec->get("GetMediaItemTake_Item"));
 // One-time rollback of the previous build's forced 0 -> 1 item gap. This
 // marker is consumed once and does not constrain future user preferences.
 using ResourcePath=const char*(*)();using ConfigVar=void*(*)(const char*,int*);
 auto resource=(ResourcePath)rec->get("GetResourcePath");auto configVar=(ConfigVar)rec->get("get_config_var");
 if(resource&&configVar){const char*path=resource();if(path){std::string marker=std::string(path)+"/UserPlugins/.mixolve_restore_item_gap.pending";
  if(FILE*f=std::fopen(marker.c_str(),"rb")){char token[64]{};size_t count=std::fread(token,1,sizeof(token),f);std::fclose(f);
   constexpr char expected[]="mixolve-revert-item-gap-20261102\n";
   if(count==sizeof(expected)-1&&!std::memcmp(token,expected,count)){int size=0;auto*gap=(int*)configVar("trackitemgap",&size);
    if(gap&&size==(int)sizeof(int)){if(*gap==1)*gap=0;std::remove(marker.c_str());}
   }
  }
 }}
 for(int n=0;n<actionCount;++n){commands[n]=rec->reg("custom_action",&actions[n]);if(!commands[n]){unload();return 0;}}
 if(!rec->reg("hookcommand",(Ptr)command)||!rec->reg("hookcommand2",(Ptr)command2)||!rec->reg("hookpostcommand",(Ptr)afterCommand)||!rec->reg("projectconfig",&config)||!rec->reg("timer",(Ptr)tick)){unload();return 0;}return 1;
}
