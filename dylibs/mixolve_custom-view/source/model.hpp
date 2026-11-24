#pragma once
#include <string>
#include <cmath>
#include <vector>
namespace ep {
struct Info { int version; void *main; int(*reg)(const char*,void*); void*(*get)(const char*); };
struct APIs {
 std::string missing;
 void *(*project)(int,char*,int)=nullptr;
 void *(*selected)(void*)=nullptr;
 bool (*valid)(void*,void*,const char*)=nullptr;
 int (*items)(void*)=nullptr;
 int (*count)(void*,int)=nullptr;
 bool (*point)(void*,int,int,double*,double*,int*,double*,bool*)=nullptr;
 bool (*set)(void*,int,int,double*,double*,int*,double*,bool*,bool*)=nullptr;
 bool (*name)(void*,char*,int)=nullptr;
 void (*format)(void*,double,char*,int)=nullptr;
 int (*mode)(void*)=nullptr;
 double (*from)(int,double)=nullptr;
 double (*to)(int,double)=nullptr;
 void (*undoBegin)(void*)=nullptr;
 void (*undoEnd)(void*,const char*,int)=nullptr;
 void (*arrange)()=nullptr;
 bool (*tempoGet)(void*,int,double*,int*,double*,double*,int*,int*,bool*)=nullptr;
 bool (*tempoSet)(void*,int,double,int,double,double,int,int,bool)=nullptr;
 void *(*brAlloc)(void*,bool)=nullptr;
 bool (*brFree)(void*,bool)=nullptr;
 void (*brProps)(void*,bool*,bool*,bool*,bool*,int*,int*,double*,double*,double*,int*,bool*,int*)=nullptr;
 void (*mouseContext)(char*,int,char*,int,char*,int)=nullptr;
 void *(*mouseEnvelope)(bool*)=nullptr;
 void *(*mouseEnvelopeEx)(bool*,int*,int*)=nullptr;
 double (*mousePosition)()=nullptr;
 int (*pointByTime)(void*,int,double)=nullptr;
 int (*brPrevious)(void*,double)=nullptr;
 bool load(void*(*get)(const char*));
};
struct Meta { int type=-1,mode=0; double low=0,high=1; bool range=false; std::string name; };
struct SelectedPoint {
 int ai=-1,index=-1,shape=0;double time=0,raw=0,tension=0;
 bool operator==(const SelectedPoint& p) const{return ai==p.ai&&index==p.index&&shape==p.shape&&time==p.time&&raw==p.raw&&tension==p.tension;}
};
struct Point { void *project=nullptr,*env=nullptr; int ai=-1,index=-1,selected=0; double time=0,raw=0,tension=0,average=0; int shape=0,panSign=1; Meta meta; std::string display,nativeDisplay; bool editable=false,percentage=false,linearPercentage=false,mixed=false,normalizedMean=false,percentageReversed=false,segment=false; std::vector<SelectedPoint> points; };
class Model {
 public:
 APIs api;
 Point read();
 void pointer(bool mouseDown,bool insideEditor);
 bool commit(const Point&,const std::string&,std::string&);
 bool parse(const Point&,const std::string&,double&) const;
 private:
 void *metaEnv=nullptr,*metaProject=nullptr;
 bool mouseWasDown=false,segmentActive=false;
 void *segmentEnv=nullptr,*segmentProject=nullptr;
 int segmentAI=-1,segmentCount=0;
 std::vector<int> segmentIndices;
 std::vector<double> segmentTimes;
 Meta cached;
 Meta metadata(void*,void*);
 std::string formatted(void*,double) const;
 std::string displayed(const Point&,bool&,bool&) const;
 bool coordinate(const Point&,double,double&) const;
 bool fromCoordinate(const Point&,double,double&) const;
};
}
