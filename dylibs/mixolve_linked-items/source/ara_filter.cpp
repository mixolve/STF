#include "ara_filter.hpp"
#include "ARAInterface.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <algorithm>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <vector>

namespace ara_filter {
using namespace ARA;
// Native layout is restricted to this exact arm64 REAPER build. No executable
// bytes are modified. Only per-document/per-instance copies of ARA API tables
// are installed; playback-renderer interfaces are never replaced.
template<class T>T read(void*p,size_t off){T v{};std::memcpy(&v,(char*)p+off,sizeof(v));return v;}
template<class T>void write(void*p,size_t off,T v){std::memcpy((char*)p+off,&v,sizeof(v));}
std::vector<void*> list(void*p,size_t off){
 auto bytes=read<unsigned>(p,off+12);auto data=read<void**>(p,off);
 if(bytes>1024*1024||bytes%sizeof(void*)||(!data&&bytes))return {};
 return bytes?std::vector<void*>(data,data+bytes/sizeof(void*)):std::vector<void*>{};
}
// CreateFxCtx initially adds new bindings to the pending list at 0x1a8.
// REAPER then transfers ownership: the track editor belongs to ARA_Sequence+8,
// and each playback-only binding belongs to ARA_Take+8. The pending list is
// normally empty at rest and cannot enumerate the visible track editor.
std::vector<void*> liveFx(void*ctx){
 std::vector<void*> out;auto append=[&](void*f){if(f&&read<void*>(f,0)==ctx&&std::find(out.begin(),out.end(),f)==out.end())out.push_back(f);};
 for(auto f:list(ctx,0x1a8))append(f);
 for(auto seq:list(ctx,0x178))if(read<void*>(seq,0)==ctx){append(read<void*>(seq,8));for(auto take:list(seq,0x70))if(read<void*>(take,0)==ctx)append(read<void*>(take,8));}
 return out;
}
bool supported(){
#ifdef ARA_FILTER_TEST
 return true;
#else
 const auto*h=(const mach_header_64*)_dyld_get_image_header(0);
 if(!h||h->magic!=MH_MAGIC_64||h->cputype!=CPU_TYPE_ARM64)return false;
 constexpr unsigned char id[]={0x6e,0xcf,0x00,0x45,0xde,0xd7,0x3f,0x44,0x89,0xef,0xb7,0xae,0xcb,0x17,0xa9,0x23};
 auto*c=(const load_command*)(h+1);for(unsigned n=0;n<h->ncmds;n++){
  if(c->cmd==LC_UUID)return c->cmdsize>=sizeof(uuid_command)&&!std::memcmp(((const uuid_command*)c)->uuid,id,16);
  c=(const load_command*)((const char*)c+c->cmdsize);
 }return false;
#endif
}
struct Sequence {ARARegionSequenceRef ref{};ARARegionSequenceProperties properties{};};
struct Region {void*host{};void*take{};ARAPlaybackRegionProperties original{};ARARegionSequenceRef hidden{};};
struct Fx {
 void*native{};ARAEditorViewRef view{};const ARAEditorViewInterface*originalView{};ARAEditorViewInterface viewApi{};
 std::vector<ARARegionSequenceRef>hostHidden,lastHidden;bool sent=false;
};
struct Context {
 void*native{};ARADocumentControllerRef ref{};const ARADocumentControllerInterface*original{};ARADocumentControllerInterface api{};
 std::map<ARARegionSequenceRef,std::unique_ptr<Sequence>>sequences;
 std::map<ARAPlaybackRegionRef,Region>regions;
 std::map<void*,std::unique_ptr<Fx>>fx;
};
std::map<ARADocumentControllerRef,std::unique_ptr<Context>>contexts;

bool polling=false;
Context* context(ARADocumentControllerRef ref){auto i=contexts.find(ref);return i==contexts.end()?nullptr:i->second.get();}
Context* owner(ARAEditorViewRef ref,Fx*&fx){for(auto&[_,c]:contexts)for(auto&[__,f]:c->fx)if(f->view==ref){fx=f.get();return c.get();}return nullptr;}
std::vector<ARARegionSequenceRef> hidden(Context&c,const Fx&f){
 auto refs=f.hostHidden;for(auto&[_,s]:c.sequences)if(s->ref&&std::find(refs.begin(),refs.end(),s->ref)==refs.end())refs.push_back(s->ref);return refs;
}
void notify(Context&c,Fx&f,bool force=false){if(f.originalView&&f.view&&f.originalView->notifyHideRegionSequences){auto refs=hidden(c,f);if(!force&&f.sent&&refs==f.lastHidden)return;f.lastHidden=refs;f.sent=true;f.originalView->notifyHideRegionSequences(f.view,refs.size(),refs.empty()?nullptr:refs.data());}}
void hide(ARAEditorViewRef ref,ARASize count,const ARARegionSequenceRef*refs){Fx*f=nullptr;if(auto*c=owner(ref,f)){f->hostHidden.clear();if(count&&refs)f->hostHidden.assign(refs,refs+count);notify(*c,*f,true);}}
void selection(ARAEditorViewRef ref,const ARAViewSelection*value){
 Fx*f=nullptr;auto*c=owner(ref,f);if(!c||!f->originalView->notifySelection)return;
 if(!value){f->originalView->notifySelection(ref,value);return;}
 auto s=*value;std::vector<ARAPlaybackRegionRef>regions;std::vector<ARARegionSequenceRef>sequences;
 for(ARASize n=0;n<s.playbackRegionRefsCount;n++)if(!c->regions.count(s.playbackRegionRefs[n]))regions.push_back(s.playbackRegionRefs[n]);
 for(ARASize n=0;n<s.regionSequenceRefsCount;n++){auto r=s.regionSequenceRefs[n];bool synthetic=false;for(auto&[_,v]:c->sequences)synthetic|=v->ref==r;if(!synthetic)sequences.push_back(r);}
 s.playbackRegionRefsCount=regions.size();s.playbackRegionRefs=regions.empty()?nullptr:regions.data();s.regionSequenceRefsCount=sequences.size();s.regionSequenceRefs=sequences.empty()?nullptr:sequences.data();f->originalView->notifySelection(ref,&s);
}
void update(ARADocumentControllerRef ref,ARAPlaybackRegionRef region,const ARAPlaybackRegionProperties*properties){
 auto*c=context(ref);if(!c)return;auto i=c->regions.find(region);if(i==c->regions.end()){c->original->updatePlaybackRegionProperties(ref,region,properties);return;}
 i->second.original=*properties;auto p=*properties;p.regionSequenceRef=i->second.hidden;c->original->updatePlaybackRegionProperties(ref,region,&p);
}
void destroyRegion(ARADocumentControllerRef ref,ARAPlaybackRegionRef region){
 auto*c=context(ref);if(!c)return;c->regions.erase(region);c->original->destroyPlaybackRegion(ref,region);
}
void cleanup(Context&c){for(auto i=c.sequences.begin();i!=c.sequences.end();){bool used=false;for(auto&[_,r]:c.regions)used|=r.hidden==i->second->ref;
 if(!used){c.original->destroyRegionSequence(c.ref,i->second->ref);i=c.sequences.erase(i);}else ++i;}}
void pruneFx(Context&,const std::vector<void*>&);
void end(ARADocumentControllerRef ref){auto*c=context(ref);if(!c)return;cleanup(*c);c->original->endEditing(ref);pruneFx(*c,liveFx(c->native));for(auto&[_,f]:c->fx)notify(*c,*f,true);}
void destroyMusical(ARADocumentControllerRef ref,ARAMusicalContextRef musical){
 auto*c=context(ref);if(!c)return;
 // ARA requires native playback regions to be gone before musical-context
 // destruction. Keep our additional sequences within the same lifetime.
 for(auto&[_,s]:c->sequences)if(s->properties.musicalContextRef==musical){s->properties.musicalContextRef=nullptr;c->original->updateRegionSequenceProperties(ref,s->ref,&s->properties);}
 c->original->destroyMusicalContext(ref,musical);
}
void destroyDocument(ARADocumentControllerRef ref){
 auto i=contexts.find(ref);if(i==contexts.end())return;auto c=std::move(i->second);contexts.erase(i);
 auto live=liveFx(c->native);for(auto&[native,f]:c->fx)if(std::find(live.begin(),live.end(),native)!=live.end()&&read<void*>(native,0x50)==&f->viewApi)write(native,0x50,f->originalView);
 write(c->native,8,c->original);c->original->destroyDocumentController(ref);
 // The plug-in destroys the entire graph here. Our host refs stay alive until
 // that call returns; no separate destroy calls target an already-dead graph.
}
bool install(void*native){
 auto ref=read<ARADocumentControllerRef>(native,16);auto*old=read<const ARADocumentControllerInterface*>(native,8);
 if(!ref||!old||contexts.count(ref))return false;
 if(old->structSize<ARA_IMPLEMENTED_STRUCT_SIZE(ARADocumentControllerInterface,destroyRegionSequence)||old->structSize>sizeof(ARADocumentControllerInterface))return false;
 if(!old->createRegionSequence||!old->updateRegionSequenceProperties||!old->destroyRegionSequence||!old->updatePlaybackRegionProperties||!old->destroyPlaybackRegion||!old->beginEditing||!old->endEditing||!old->destroyDocumentController||!old->destroyMusicalContext)return false;
 auto c=std::make_unique<Context>();c->native=native;c->ref=ref;c->original=old;std::memcpy(&c->api,old,old->structSize);
 c->api.updatePlaybackRegionProperties=update;c->api.destroyPlaybackRegion=destroyRegion;c->api.endEditing=end;c->api.destroyMusicalContext=destroyMusical;c->api.destroyDocumentController=destroyDocument;
 auto*p=c.get();contexts.emplace(ref,std::move(c));write(native,8,&p->api);return true;
}
void attachFx(Context&c,void*native,TrackVisible visible){
 auto ext=read<ARAPlugInExtensionInstance>(native,0x10);if(c.fx.count(native))return;
 if(ext.structSize<ARA_IMPLEMENTED_STRUCT_SIZE(ARAPlugInExtensionInstance,editorViewInterface)||!ext.editorViewRef||!ext.editorViewInterface)return;
 if(ext.editorViewInterface->structSize<kARAEditorViewInterfaceMinSize||ext.editorViewInterface->structSize>sizeof(ARAEditorViewInterface)||!ext.editorViewInterface->notifyHideRegionSequences)return;
 auto f=std::make_unique<Fx>();f->native=native;f->view=ext.editorViewRef;f->originalView=ext.editorViewInterface;
 std::memcpy(&f->viewApi,f->originalView,f->originalView->structSize);
 f->viewApi.notifyHideRegionSequences=hide;f->viewApi.notifySelection=selection;
 if(visible)for(auto seq:list(c.native,0x178)){auto track=read<void*>(seq,0x10);if(track&&!visible(track))f->hostHidden.push_back(read<ARARegionSequenceRef>(seq,0x40));}
 auto*p=f.get();c.fx.emplace(native,std::move(f));write(native,0x50,&p->viewApi);
}
void pruneFx(Context&c,const std::vector<void*>&live){for(auto i=c.fx.begin();i!=c.fx.end();)if(std::find(live.begin(),live.end(),i->first)==live.end()||read<void*>(i->first,0x50)!=&i->second->viewApi)i=c.fx.erase(i);else ++i;}

// Host refs are opaque to the plug-in. These sequences are owned solely by
// this bridge and never inserted into REAPER's physical track/sequence lists.
Sequence* sequence(Context&c,ARARegionSequenceRef original,void*nativeSequence){
 auto i=c.sequences.find(original);if(i!=c.sequences.end())return i->second.get();
 auto s=std::make_unique<Sequence>();s->properties=read<ARARegionSequenceProperties>(nativeSequence,0x18);s->properties.name="Linked playback";s->properties.color=nullptr;
 s->ref=c.original->createRegionSequence(c.ref,reinterpret_cast<ARARegionSequenceHostRef>(s.get()),&s->properties);if(!s->ref)return nullptr;
 auto*p=s.get();c.sequences.emplace(original,std::move(s));return p;
}
void poll(const std::vector<void*>&projects,IsChildTake isChild,TrackVisible visible){
 static const bool compatible=supported();if(!compatible)return;if(!pthread_main_np()||polling||!isChild)return;polling=true;
 for(auto project:projects)for(auto native:list(project,0x1da0)){
  if(!native||read<void*>(native,0)!=project)continue;
  auto ref=read<ARADocumentControllerRef>(native,16);if(!context(ref)){
   bool relevant=false;for(auto seq:list(native,0x178))for(auto take:list(seq,0x70)){auto itemTake=read<void*>(take,0x10);if(itemTake&&isChild(itemTake))relevant=true;}
   if(!relevant)continue;install(native);
  }auto*c=context(ref);if(!c||read<void*>(native,8)!=&c->api||read<unsigned char>(native,0x21))continue;
  auto fx=liveFx(native);pruneFx(*c,fx);for(auto f:fx)attachFx(*c,f,visible);if(c->fx.empty())continue;
  struct Candidate{void*region;void*take;void*sequence;};std::map<ARAPlaybackRegionRef,Candidate>desired;
  for(auto seq:list(native,0x178))if(read<void*>(seq,0)==native&&read<size_t>(seq,0x18)==sizeof(ARARegionSequenceProperties))for(auto take:list(seq,0x70))if(read<void*>(take,0)==native&&read<void*>(take,0x10)&&isChild(read<void*>(take,0x10)))for(auto region:list(take,0x70)){
   auto r=read<ARAPlaybackRegionRef>(region,0x58);if(r&&read<void*>(region,0)==native)desired[r]={region,take,seq};
  }
  bool editing=false;auto begin=[&]{if(!editing){c->original->beginEditing(ref);editing=true;}};
  // Unlinking restores the original sequence, which the native editor renderer
  // already owns. Playback-renderer assignments require no change.
  for(auto i=c->regions.begin();i!=c->regions.end();)if(!desired.count(i->first)){
   begin();c->original->updatePlaybackRegionProperties(ref,i->first,&i->second.original);
   i=c->regions.erase(i);
  }else ++i;
  for(auto&[region,n]:desired){
   auto original=read<ARAPlaybackRegionProperties>(n.region,8);auto known=c->regions.find(region);
   if(known==c->regions.end()||known->second.original.regionSequenceRef!=original.regionSequenceRef){
    begin();auto*s=sequence(*c,original.regionSequenceRef,n.sequence);if(!s)continue;
    c->regions[region]={n.region,n.take,original,s->ref};auto p=original;p.regionSequenceRef=s->ref;c->original->updatePlaybackRegionProperties(ref,region,&p);
   }

  }
  if(editing){cleanup(*c);c->original->endEditing(ref);}for(auto&[_,f]:c->fx)notify(*c,*f);
 }
 polling=false;
}
void shutdown(){
 if(!supported()||!pthread_main_np())return;
 for(auto&[ref,c]:contexts){
  pruneFx(*c,liveFx(c->native));c->original->beginEditing(ref);
  for(auto&[r,v]:c->regions)c->original->updatePlaybackRegionProperties(ref,r,&v.original);
  for(auto&[_,f]:c->fx){
   write(f->native,0x50,f->originalView);
  }
  for(auto&[_,s]:c->sequences)c->original->destroyRegionSequence(ref,s->ref);
  c->original->endEditing(ref);for(auto&[_,f]:c->fx)f->originalView->notifyHideRegionSequences(f->view,f->hostHidden.size(),f->hostHidden.empty()?nullptr:f->hostHidden.data());write(c->native,8,c->original);
 }contexts.clear();
}
static_assert(sizeof(ARAPlaybackRegionProperties)==80&&sizeof(ARARegionSequenceProperties)==40);
static_assert(offsetof(ARAPlugInExtensionInstance,editorRendererInterface)+0x10==0x40);
static_assert(offsetof(ARAPlugInExtensionInstance,editorViewInterface)+0x10==0x50);
}
