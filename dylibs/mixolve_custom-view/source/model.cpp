#include "model.hpp"
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cctype>
#include <limits>
#include <cstdio>
namespace ep {
bool APIs::load(void*(*get)(const char*)) {
 missing.clear();if(!get){missing="API provider";return false;}
 #define LOAD(field,name) field=reinterpret_cast<decltype(field)>(get(name)); if(!field){if(!missing.empty())missing+=", ";missing+=name;}
 LOAD(project,"EnumProjects");LOAD(selected,"GetSelectedEnvelope");LOAD(valid,"ValidatePtr2");
 LOAD(items,"CountAutomationItems");LOAD(count,"CountEnvelopePointsEx");LOAD(point,"GetEnvelopePointEx");
 LOAD(set,"SetEnvelopePointEx");LOAD(name,"GetEnvelopeName");LOAD(format,"Envelope_FormatValue");
 LOAD(mode,"GetEnvelopeScalingMode");LOAD(from,"ScaleFromEnvelopeMode");LOAD(to,"ScaleToEnvelopeMode");
 LOAD(undoBegin,"Undo_BeginBlock2");LOAD(undoEnd,"Undo_EndBlock2");LOAD(arrange,"UpdateArrange");
 LOAD(tempoGet,"GetTempoTimeSigMarker");LOAD(tempoSet,"SetTempoTimeSigMarker");
 LOAD(brAlloc,"BR_EnvAlloc");LOAD(brFree,"BR_EnvFree");LOAD(brProps,"BR_EnvGetProperties");
 LOAD(mouseContext,"BR_GetMouseCursorContext");LOAD(mouseEnvelope,"BR_GetMouseCursorContext_Envelope");
 LOAD(mouseEnvelopeEx,"BR_GetMouseCursorContext_EnvelopeEx");LOAD(mousePosition,"BR_GetMouseCursorContext_Position");
 LOAD(pointByTime,"GetEnvelopePointByTimeEx");LOAD(brPrevious,"BR_EnvFindPrevious");
 #undef LOAD
 return project&&selected&&valid&&items&&count&&point&&set&&name&&format&&mode&&from&&to&&undoBegin&&undoEnd&&arrange;
}
static std::string trim(std::string s) {
 auto white=[](unsigned char c){return std::isspace(c);};
 s.erase(s.begin(),std::find_if_not(s.begin(),s.end(),white));
 s.erase(std::find_if_not(s.rbegin(),s.rend(),white).base(),s.end());return s;
}
static std::string lower(std::string s){for(char &c:s)c=std::tolower((unsigned char)c);return s;}
struct Number{double value;std::string unit;};
static bool number(std::string s,Number& out) {
 s=trim(lower(s));std::replace(s.begin(),s.end(),',','.');if(s.empty())return false;
 char *end=nullptr;errno=0;double n=std::strtod(s.c_str(),&end);
 if(end==s.c_str()||errno==ERANGE||!std::isfinite(n))return false;
 std::string unit=trim(s.substr(end-s.c_str()));
 if(unit=="khz"){n*=1000;unit="hz";}else if(unit=="mhz"){n*=1000000;unit="hz";}
 if(unit=="s"||unit=="sec"||unit=="seconds"){n*=1000;unit="ms";}
 else if(unit=="us"||unit=="µs"){n/=1000;unit="ms";}
 if(!std::isfinite(n))return false;out={n,unit};return true;
}
std::string Model::formatted(void *env,double raw) const {char text[512]={};api.format(env,raw,text,sizeof(text));return text;}
static std::string numeric(double value,bool fixed=false){
 if(std::abs(value)<(fixed?.005:1e-12))value=0; // Avoid a displayed negative zero.
 char out[96];std::snprintf(out,sizeof(out),fixed?"%.2f":"%.9g",value);return out;
}
std::string Model::displayed(const Point& p,bool& percentage,bool& linearPercentage) const {
 double value=api.from(p.meta.mode,p.raw);int type=p.meta.type;
 percentage=false;linearPercentage=false;
 if(type==0||type==1)return value<=0?"-inf":numeric(20*std::log10(value),true);
 if(type==2||type==3){
  std::string endpoint=lower(formatted(p.env,api.to(p.meta.mode,p.meta.low)));
  bool lowIsLeft=!endpoint.empty()&&(endpoint.back()=='l'||endpoint.find("left")!=std::string::npos);
  return numeric(value*100*(lowIsLeft?1:-1),true);
 }
 if(type==4||type==5)return numeric(value*100,true);
 Number current{};
 if(number(p.nativeDisplay,current)){
  if(p.meta.range&&(type==10||type<0)&&current.unit.empty()){
   Number lo{},hi{},middle{};
   bool endpoints=number(formatted(p.env,api.to(p.meta.mode,p.meta.low)),lo)&&number(formatted(p.env,api.to(p.meta.mode,p.meta.high)),hi);
   bool unitRange=endpoints&&lo.unit.empty()&&hi.unit.empty()&&
    ((std::abs(lo.value)<1e-9&&std::abs(hi.value-1)<1e-9)||(std::abs(hi.value)<1e-9&&std::abs(lo.value-1)<1e-9));
   // Numeric on/off enums also have endpoints 0/1, but no fractional values.
   bool fraction=unitRange&&number(formatted(p.env,api.to(p.meta.mode,(p.meta.low+p.meta.high)/2)),middle)&&middle.unit.empty()&&middle.value>0&&middle.value<1;
   if(fraction){
    percentage=true;linearPercentage=true;
    for(double position:{.25,.5,.75}){
     Number probe{};
     if(!number(formatted(p.env,api.to(p.meta.mode,p.meta.low+(p.meta.high-p.meta.low)*position)),probe)||!probe.unit.empty()||std::abs(probe.value-(lo.value+(hi.value-lo.value)*position))>1e-9){linearPercentage=false;break;}
    }
    // Default normalized formatters often round early. Preserve the actual
    // point precision instead of magnifying their display rounding to percent.
    double shown=linearPercentage?lo.value+(hi.value-lo.value)*(value-p.meta.low)/(p.meta.high-p.meta.low):current.value;
    return numeric(std::clamp(shown,0.,1.)*100,true);
   }
  }
  return numeric(current.value);
 }
 if(lower(p.nativeDisplay).find("-inf")==0)return "-inf";
 return p.nativeDisplay; // Discrete values such as MUTE or Triangle are labels, not units.
}
// Relative changes use the same numeric domain as the readout: dB for volume,
// percentage points for normalized controls, and physical numbers for other FX.
bool Model::coordinate(const Point& p,double raw,double& out) const {
 double v=api.from(p.meta.mode,raw);if(!std::isfinite(v))return false;
 if(p.normalizedMean){out=(v-p.meta.low)/(p.meta.high-p.meta.low)*100;return true;}
 switch(p.meta.type){
 case 0:case 1:out=v>0?20*std::log10(v):-150;return true;
 case 2:case 3:out=v*100*p.panSign;return true;
 case 4:case 5:out=v*100;return true;
 case 6:case 7:case 8:case 9:out=v;return true;
 default:
  if(p.percentage&&p.linearPercentage){double t=(v-p.meta.low)/(p.meta.high-p.meta.low);out=(p.percentageReversed?1-t:t)*100;return true;}
  Number n{};if(!number(formatted(p.env,raw),n))return false;
  out=n.value*(p.percentage?100:1);return true;
 }
}
bool Model::fromCoordinate(const Point& p,double value,double& raw) const {
 double v=value;
 if(p.normalizedMean)v=p.meta.low+(p.meta.high-p.meta.low)*std::clamp(value/100,0.,1.);
 else switch(p.meta.type){
 case 0:case 1:v=value<=-150?0:std::pow(10.,value/20);break;
 case 2:case 3:v=value/(100*p.panSign);break;
 case 4:case 5:v=value/100;break;
 case 6:case 7:case 8:case 9:break;
 default:{Point point=p;point.display.clear();point.nativeDisplay=formatted(p.env,raw);return parse(point,numeric(value),raw);}
 }
 if(!std::isfinite(v))return false;
 raw=api.to(p.meta.mode,std::clamp(v,p.meta.low,p.meta.high));return std::isfinite(raw);
}
Meta Model::metadata(void *proj,void *env) {
 char name[512]={};api.name(env,name,sizeof(name));int mode=api.mode(env);
 if(proj==metaProject&&env==metaEnv&&cached.name==name&&cached.mode==mode&&cached.range)return cached;
 Meta m;m.name=name;m.mode=mode;
 if(api.brAlloc&&api.brFree&&api.brProps){
  void *br=api.brAlloc(env,false);
  if(br){bool active=false,visible=false,armed=false,lane=false,fader=false;int height=0,shape=0,opts=0;double center=0;
   api.brProps(br,&active,&visible,&armed,&lane,&height,&shape,&m.low,&m.high,&center,&m.type,&fader,&opts);
   m.range=std::isfinite(m.low)&&std::isfinite(m.high)&&m.low<m.high;
   api.brFree(br,false);
  }
 }
 metaProject=proj;metaEnv=env;cached=m;return m;
}
void Model::pointer(bool down,bool insideEditor){
 if(!down){mouseWasDown=false;return;}
 if(mouseWasDown)return;mouseWasDown=true;
 if(insideEditor)return; // Keep the last segment available when clicking its value.
 segmentActive=false;segmentIndices.clear();segmentTimes.clear();
 if(!api.mouseContext||!api.mousePosition||!api.pointByTime||(!api.mouseEnvelopeEx&&!api.mouseEnvelope))return;
 char window[128]={},section[128]={},details[128]={};api.mouseContext(window,sizeof(window),section,sizeof(section),details,sizeof(details));
 if(std::string(details)!="env_segment")return;
 bool take=false;int ai=-1,hit=-1;
 void *env=api.mouseEnvelopeEx?api.mouseEnvelopeEx(&take,&ai,&hit):api.mouseEnvelope(&take);
 void *project=api.project(-1,nullptr,0);
 if(!env||!project||!api.valid(project,env,"TrackEnvelope*"))return;
 double position=api.mousePosition();if(!std::isfinite(position))return;
 int index=-1;
 if(take){
  // SWS resolves take offsets/playrate in project time without guessing units.
  if(!api.brAlloc||!api.brFree||!api.brPrevious)return;
  void *br=api.brAlloc(env,true);if(!br)return;index=api.brPrevious(br,position);api.brFree(br,false);ai=-1;
 }else index=api.pointByTime(env,ai,position);
 int count=api.count(env,ai);if(count<1)return;
 bool beforeFirst=index<0;
 if(index<0)index=0;if(index>=count)index=count-1;
 std::vector<int> ids{index};if(!beforeFirst&&index+1<count)ids.push_back(index+1);
 bool allSelected=true;
 for(int id:ids){double time=0,value=0,tension=0;int shape=0;bool selected=false;
  if(!api.point(env,ai,id,&time,&value,&shape,&tension,&selected))return;
  segmentTimes.push_back(time);allSelected=allSelected&&selected;
 }
 // A segment whose ends already belong to an explicit selection retains the
 // existing multi-point target, rather than discarding other selected points.
 if(allSelected&&api.selected(project)==env){segmentTimes.clear();return;}
 segmentProject=project;segmentEnv=env;segmentAI=ai;segmentCount=count;segmentIndices=ids;segmentActive=true;
}
Point Model::read() {
 Point result;result.project=api.project(-1,nullptr,0);if(!result.project)return result;
 result.env=api.selected(result.project);
 if(segmentActive){
  if(result.project!=segmentProject||!api.valid(result.project,segmentEnv,"TrackEnvelope*")||api.count(segmentEnv,segmentAI)!=segmentCount||(!mouseWasDown&&result.env&&result.env!=segmentEnv))segmentActive=false;
  else {
   for(size_t i=0;i<segmentIndices.size();++i){double time=0,value=0,tension=0;int shape=0;bool selected=false;
    if(!api.point(segmentEnv,segmentAI,segmentIndices[i],&time,&value,&shape,&tension,&selected)){segmentActive=false;break;}
    if(time!=segmentTimes[i]){if(mouseWasDown)segmentTimes[i]=time;else{segmentActive=false;break;}}
   }
   if(segmentActive){result.env=segmentEnv;result.segment=true;}
  }
 }
 if(!result.env||!api.valid(result.project,result.env,"TrackEnvelope*")){result.env=nullptr;return result;}
 // A point is identified by envelope, automation-item index, point index and
 // its full attributes. Commit rechecks these rather than following a stale ID.
 auto collect=[&](int ai,int i,bool requireSelected){
  double time=0,raw=0,tension=0;int shape=0;bool selected=false;
  if(!api.point(result.env,ai,i,&time,&raw,&shape,&tension,&selected)||(requireSelected&&!selected))return;
  ++result.selected;result.points.push_back({ai,i,shape,time,raw,tension});
  if(result.selected==1){result.ai=ai;result.index=i;result.time=time;result.raw=raw;result.shape=shape;result.tension=tension;}
  else if(raw!=result.raw)result.mixed=true;
 };
 if(result.segment){for(int i:segmentIndices)collect(segmentAI,i,false);}
 else {int items=api.items(result.env);for(int ai=-1;ai<items;++ai){int count=api.count(result.env,ai);for(int i=0;i<count;++i)collect(ai,i,true);}}

 if(result.selected>0){result.meta=metadata(result.project,result.env);result.nativeDisplay=formatted(result.env,result.raw);result.display=displayed(result,result.percentage,result.linearPercentage);result.editable=result.meta.range&&std::isfinite(result.raw)&&(result.meta.type!=9||(api.tempoGet&&api.tempoSet&&result.ai==-1));}
 if(result.selected>0){
  if(result.meta.type==2||result.meta.type==3){std::string end=lower(formatted(result.env,api.to(result.meta.mode,result.meta.low)));result.panSign=(!end.empty()&&(end.back()=='l'||end.find("left")!=std::string::npos))?1:-1;}
  if(result.percentage&&result.linearPercentage){Number lo{};number(formatted(result.env,api.to(result.meta.mode,result.meta.low)),lo);result.percentageReversed=lo.value>.5;}
 }
 if(result.selected>1){
  long double total=0;bool numericSelection=true;
  for(const auto& point:result.points){double v=0;if(!coordinate(result,point.raw,v)){numericSelection=false;break;}total+=v;}
  if(!numericSelection){result.normalizedMean=true;total=0;for(const auto& point:result.points){double v=0;if(!coordinate(result,point.raw,v)){result.editable=false;break;}total+=v;}}
  result.average=(double)(total/result.points.size());result.display=numeric(result.average,true);
  bool silent=(result.meta.type==0||result.meta.type==1);for(const auto& point:result.points)silent=silent&&api.from(result.meta.mode,point.raw)<=0;
  if(silent)result.display="-inf";
 }
 return result;
}
bool Model::parse(const Point& p,const std::string& input,double& raw) const {
 std::string s=lower(trim(input));if(s.empty()||!p.meta.range)return false;
 // Leaving a formatted value unchanged must not quantize the underlying point.
 if(s==lower(trim(p.display))){raw=p.raw;return true;}
 Number n{};double linear=0;int type=p.meta.type;
 auto pan=[&](double percent){
  std::string leftEndpoint=lower(formatted(p.env,api.to(p.meta.mode,p.meta.low)));
  bool lowIsLeft=!leftEndpoint.empty()&&(leftEndpoint.back()=='l'||leftEndpoint.find("left")!=std::string::npos);
  return ((percent<0)==lowIsLeft?p.meta.low:p.meta.high)*std::abs(percent)/100;
 };
 if((type==0||type==1)&&(s=="-inf"||s=="-inf db"||s=="-infinity"||s=="-∞"))linear=0;
 else if(type==6&&(s=="mute"||s=="unmute"))linear=s=="mute"?0:1;
 else {
  if((type==2||type==3)&&s=="center")linear=0;
  else if((type==2||type==3)&&(s.back()=='l'||s.back()=='r')){
   bool left=s.back()=='l';s.pop_back();if(!number(s,n)||(n.unit!=""&&n.unit!="%"))return false;
   linear=pan((left?-1:1)*std::abs(n.value));
  }
  else {
   if(!number(s,n)) {
    // Discrete FX labels can be entered verbatim if an endpoint matches.
    double first=0,last=0;bool found=false;
    for(int i=0;i<=256;++i){double v=p.meta.low+(p.meta.high-p.meta.low)*i/256.;double candidate=api.to(p.meta.mode,v);std::string label=lower(trim(formatted(p.env,candidate)));
     if(label==s||((s=="-inf"||s=="-inf db")&&label.find("-inf")==0)){
      if(!found)first=v;last=v;found=true;
     }
    }
    if(found){raw=api.to(p.meta.mode,(first+last)/2);return true;}return false;
   }
   switch(type){
    case 0:case 1:if(n.unit!=""&&n.unit!="db")return false;linear=std::pow(10.,n.value/20);break;
    case 2:case 3:if(n.unit!=""&&n.unit!="%")return false;linear=pan(n.value);break;
    case 4:case 5:if(n.unit!=""&&n.unit!="%")return false;linear=n.value/100;break;
    case 6:if(n.unit!=""||(n.value!=0&&n.value!=1))return false;linear=n.value;break;
    case 7:if(n.unit!=""&&n.unit!="st"&&n.unit!="semitones")return false;linear=n.value;break;
    case 8:if(n.unit!=""&&n.unit!="x")return false;linear=n.value;break;
    case 9:if(n.unit!=""&&n.unit!="bpm")return false;linear=n.value;break;
    default:{
     if(p.percentage){
      if(!n.unit.empty()&&n.unit!="%")return false;
      n.value=std::clamp(n.value,0.,100.)/100;n.unit.clear();
      if(p.linearPercentage){
       Number lo{};if(!number(formatted(p.env,api.to(p.meta.mode,p.meta.low)),lo))return false;
       double position=lo.value>.5?1-n.value:n.value;
       linear=p.meta.low+(p.meta.high-p.meta.low)*position;break;
      }
     }else {
      Number native{};if(n.unit=="%"&&number(p.nativeDisplay,native)&&native.unit=="%")n.unit.clear();
     }
     // Explicit percentages on unit-bearing FX retain the normalized-position shortcut.
     if(n.unit=="%"){linear=p.meta.low+(p.meta.high-p.meta.low)*n.value/100;break;}
     Number lo{},hi{};auto displayAt=[&](double v,Number& out){return number(formatted(p.env,api.to(p.meta.mode,v)),out);};
     double lowerBound=p.meta.low;
     if(!displayAt(lowerBound,lo)){
      if(lower(formatted(p.env,api.to(p.meta.mode,lowerBound))).find("-inf")!=0)return false;
      lowerBound=p.meta.low+(p.meta.high-p.meta.low)*1e-9;
      if(!displayAt(lowerBound,lo))return false;
     }
     if(!displayAt(p.meta.high,hi)||lo.unit!=hi.unit||lo.value==hi.value)return false;
     if(!n.unit.empty()&&n.unit!=lo.unit)return false;
     bool up=hi.value>lo.value;double target=std::clamp(n.value,std::min(lo.value,hi.value),std::max(lo.value,hi.value));
     if(target==lo.value){linear=lowerBound;break;}
     if(target==hi.value){linear=p.meta.high;break;}
     // Reject non-monotonic mappings instead of moving an unrelated parameter value.
     double prev=lo.value;
     for(int i=1;i<=8;++i){Number q{};if(!displayAt(lowerBound+(p.meta.high-lowerBound)*i/8.,q)||q.unit!=lo.unit||(up?q.value<prev:q.value>prev))return false;prev=q.value;}
     double a=lowerBound,b=p.meta.high,best=a,error=std::abs(lo.value-target);
     for(int i=0;i<56;++i){double mid=(a+b)/2;Number q{};if(!displayAt(mid,q)||q.unit!=lo.unit)return false;double e=std::abs(q.value-target);if(e<error){best=mid;error=e;}if((q.value<target)==up)a=mid;else b=mid;}
     linear=best;break;
    }
   }
  }
 }
 if(!std::isfinite(linear))return false;
 linear=std::clamp(linear,p.meta.low,p.meta.high);raw=api.to(p.meta.mode,linear);return std::isfinite(raw);
}
bool Model::commit(const Point& before,const std::string& input,std::string& error) {
 metaEnv=nullptr; // Re-read live ranges before writing, including changed preferences.
 Point now=read();
 if(!now.editable||now.selected<1||now.segment!=before.segment||now.points!=before.points||now.project!=before.project||now.env!=before.env||now.ai!=before.ai||now.index!=before.index||now.time!=before.time||now.raw!=before.raw||now.shape!=before.shape||now.tension!=before.tension||now.meta.type!=before.meta.type||now.meta.mode!=before.meta.mode||now.meta.name!=before.meta.name||now.percentage!=before.percentage||now.linearPercentage!=before.linearPercentage||now.normalizedMean!=before.normalizedMean||now.percentageReversed!=before.percentageReversed){error="The selected point changed. Select it again.";return false;}
 if(lower(trim(input))==lower(trim(now.display)))return true;
 double value=0,requestedMean=0;bool silence=false;
 if(now.selected>1&&(now.normalizedMean||now.meta.type==6)){
  Number n{};if(!number(input,n)||(!n.unit.empty()&&!(now.normalizedMean&&n.unit=="%"))){error="Enter a valid value.";return false;}
  value=now.raw;if(!fromCoordinate(now,n.value,value)||!coordinate(now,value,requestedMean)){error="Enter a valid value.";return false;}
 }else{
  if(!parse(now,input,value)){error="Enter a valid value.";return false;}
  if(now.selected>1&&!coordinate(now,value,requestedMean)){error="Enter a valid value.";return false;}
  silence=(now.meta.type==0||now.meta.type==1)&&value==0;
 }
 double delta=now.selected>1?requestedMean-now.average:0;
 if(now.selected>1&&!silence&&std::abs(delta)<=1e-12*std::max(1.,std::abs(now.average)))return true;
 std::vector<SelectedPoint> changed;std::vector<double> values;
 for(const auto& point:now.points){
  double target=value;
  if(now.selected>1&&!silence){double current=0;target=point.raw;
   if(!coordinate(now,point.raw,current)||!fromCoordinate(now,current+delta,target)){error="Enter a valid value.";return false;}
  }
  if(target!=point.raw&&std::abs(target-point.raw)>1e-12*std::max(1.,std::abs(point.raw))){changed.push_back(point);values.push_back(target);}
 }
 if(changed.empty())return true;
 struct Tempo {int num=0,denom=0;bool linear=false;};std::vector<Tempo> tempos;
 if(now.meta.type==9){
  for(const auto& point:changed){double time=0,beat=0,bpm=0;int measure=0;Tempo tempo;
   if(!api.tempoGet(now.project,point.index,&time,&measure,&beat,&bpm,&tempo.num,&tempo.denom,&tempo.linear)||time!=point.time||bpm!=point.raw){error="The selected tempo points changed.";return false;}
   tempos.push_back(tempo);
  }
 }
 api.undoBegin(now.project);bool noSort=true,ok=true,any=false;
 for(size_t i=0;i<changed.size();++i){const auto& point=changed[i];
  bool written=now.meta.type==9
   ?api.tempoSet(now.project,point.index,point.time,-1,-1,values[i],tempos[i].num,tempos[i].denom,tempos[i].linear)
   :api.set(now.env,point.ai,point.index,nullptr,&values[i],nullptr,nullptr,nullptr,&noSort);
  ok=ok&&written;any=any||written;
 }
 api.undoEnd(now.project,any?"Set selected envelope point values":"Envelope points unchanged",now.meta.type==9?-1:1);
 if(any)api.arrange();if(!ok)error="The selected envelope points could not all be changed.";
 return ok;
}
}
