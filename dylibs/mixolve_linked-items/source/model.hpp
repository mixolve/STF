#pragma once
#include <string>
#include <vector>
#include <map>
#include <set>
#include <sstream>
#include <iomanip>
#include <cmath>
#include <algorithm>
#include <CommonCrypto/CommonDigest.h>
namespace lc {
struct Parent {std::string id;double start=0,end=0;std::vector<std::string>tracks;int group=0;};
struct Child {std::string id,parent;double offset=0;std::vector<std::string>tracks;int group=0;std::set<std::string>muted{};};
struct Manifest {std::map<std::string,Parent>parents;std::map<std::string,Child>children;};
inline bool validId(const std::string&s){return !s.empty()&&s.size()<80&&s.find_first_not_of("{}0123456789abcdefABCDEF-")==std::string::npos;}
inline std::string encode(const Manifest&m){std::ostringstream o;o<<"LC2\n"<<std::setprecision(17);
 for(auto&[id,p]:m.parents){o<<"P "<<id<<' '<<p.start<<' '<<p.end<<' '<<p.group;for(auto&t:p.tracks)o<<' '<<t;o<<'\n';}
 for(auto&[id,c]:m.children){o<<"C "<<id<<' '<<c.parent<<' '<<c.offset<<' '<<c.group;for(auto&t:c.tracks)o<<' '<<t;o<<'\n';for(auto&source:c.muted)o<<"M "<<id<<' '<<source<<'\n';}return o.str();}
inline Manifest decode(const std::string&s){Manifest m;std::istringstream in(s);std::string line;if(!std::getline(in,line)||line!="LC2")return m;
 while(std::getline(in,line)){std::istringstream l(line);char kind=0;l>>kind;std::string t;
  if(kind=='P'){Parent p;l>>p.id>>p.start>>p.end>>p.group;if(!l||!validId(p.id)||!std::isfinite(p.start)||!std::isfinite(p.end)||p.end<p.start)continue;
   while(l>>t)if(validId(t))p.tracks.push_back(t);if(!p.tracks.empty())m.parents[p.id]=p;
  }else if(kind=='C'){Child c;l>>c.id>>c.parent>>c.offset>>c.group;if(!l||!validId(c.id)||!validId(c.parent)||!std::isfinite(c.offset))continue;
   while(l>>t)if(validId(t))c.tracks.push_back(t);if(!c.tracks.empty())m.children[c.id]=c;}else if(kind=='M'){std::string id,source;l>>id>>source;if(l&&m.children.count(id)&&validId(source))m.children[id].muted.insert(source);}}
 for(auto i=m.children.begin();i!=m.children.end();)if(!m.parents.count(i->second.parent))i=m.children.erase(i);else ++i;
 return m;}
inline std::string mappedGuid(const std::string&instance,const std::string&old){
 unsigned char bytes[CC_SHA256_DIGEST_LENGTH];std::string key="LinkedContainers-v2|"+instance+"|"+old;
 CC_SHA256(key.data(),static_cast<CC_LONG>(key.size()),bytes);bytes[6]=(bytes[6]&15)|0x50;bytes[8]=(bytes[8]&63)|0x80;
 const char*hex="0123456789ABCDEF";std::string out="{";for(int i=0;i<16;i++){if(i==4||i==6||i==8||i==10)out+='-';out+=hex[bytes[i]>>4];out+=hex[bytes[i]&15];}return out+"}";
}
inline std::string trim(std::string s){size_t a=s.find_first_not_of(" \t\r"),b=s.find_last_not_of(" \t\r");return a==std::string::npos?"":s.substr(a,b-a+1);}
// Native TAKEFX window flags are UI state, not audio state. In particular,
// an empty TAKEFX block created by track ARA must never spawn a child FX chain.
inline std::string fxWindowIndependent(const std::string&chunk){
 struct Frame {std::string kind;size_t start;bool content=false;};std::vector<Frame>stack;
 std::istringstream in(chunk);std::string line,out;
 const std::set<std::string>windowKeys={"SHOW","WNDRECT","LASTSEL","DOCKED","FLOAT","FLOATPOS"};
 while(std::getline(in,line)){
  auto t=trim(line);auto key=t.substr(0,t.find(' '));bool chain=!stack.empty()&&stack.back().kind=="TAKEFX";
  if(chain&&windowKeys.count(key))continue;
  if(t==">"){
   if(chain&&!stack.back().content)out.resize(stack.back().start);else out+=line+'\n';
   if(!stack.empty())stack.pop_back();continue;
  }
  if(chain&&!t.empty())stack.back().content=true;
  if(!t.empty()&&t[0]=='<')stack.push_back({key.substr(1),out.size(),key=="<TAKEFX"&&t!="<TAKEFX"});
  out+=line+'\n';
 }
 return out;
}
// Normalize only volatile root fields. Nested plug-in/MIDI data is retained.
inline std::string canonical(const std::string&chunk,bool ignorePosition=false){std::istringstream in(fxWindowIndependent(chunk));std::string line,out;int depth=0;
 while(std::getline(in,line)){auto t=trim(line);auto key=t.substr(0,t.find(' '));
  bool skip=depth==1&&(key=="SEL"||key=="IID"||key=="LOCK"||key=="GROUP"||key=="LASTSEL"||(ignorePosition&&key=="POSITION"));
  if(!skip)out+=line+'\n';if(!t.empty()&&t[0]=='<')depth++;else if(t==">")depth--;}
 return out;}
// Item/take gain is read live from the public API. Native chunks may retain
// the previous VOLPAN during a mouse gesture; keep other VOLPAN values intact.
inline std::string volumeIndependent(const std::string&chunk){
 std::istringstream in(canonical(chunk,true));std::string line,out;std::vector<std::string>stack;
 while(std::getline(in,line)){auto t=trim(line);auto key=t.substr(0,t.find(' '));
  if((stack.size()==1||(!stack.empty()&&stack.back()=="TAKE"))&&(key=="VOLPAN"||key=="VOL")){
   size_t value=t.find_first_not_of(" \t",key.size());size_t end=value==std::string::npos?value:t.find_first_of(" \t",value);
   if(value!=std::string::npos)line=key+" @LIVE_GAIN@"+(end==std::string::npos?"":t.substr(end));
  }
  out+=line+'\n';if(!t.empty()&&t[0]=='<')stack.push_back(t.substr(1,t.find(' ')==std::string::npos?std::string::npos:t.find(' ')-1));else if(t==">"&&!stack.empty())stack.pop_back();
 }return out;
}
// Local mute only changes the root item flag; take/plug-in data stays intact.
inline std::string mutedChunk(const std::string&chunk){
 std::istringstream in(chunk);std::string line,out;int depth=0;bool wrote=false;
 while(std::getline(in,line)){
  auto t=trim(line);auto key=t.substr(0,t.find(' '));
  if(depth==1&&key=="MUTE"){
   size_t value=t.find_first_not_of(" \t",4),end=value==std::string::npos?value:t.find_first_of(" \t",value);
   line="MUTE 1"+(end==std::string::npos?std::string{}:t.substr(end));wrote=true;
  }
  if(depth==1&&t==">"&&!wrote){out+="MUTE 1\n";wrote=true;}
  out+=line+'\n';if(!t.empty()&&t[0]=='<')depth++;else if(t==">")depth--;
 }
 return out;
}
inline std::string cloneChunk(const std::string&chunk,const std::string&instance){
 std::istringstream in(fxWindowIndependent(chunk));std::ostringstream out;std::string line;int depth=0;
 const std::set<std::string>ids={"GUID","IGUID","TAKEGUID","FXID","EGUID","POOLEDEVTS"};
 while(std::getline(in,line)){auto t=trim(line);auto split=t.find(' ');auto key=t.substr(0,split);
  if(depth==1&&key=="IID")continue;
  if(ids.count(key)&&split!=std::string::npos){auto value=trim(t.substr(split+1));if(validId(value))line=key+' '+mappedGuid(instance,value);}
  if(depth==1&&(key=="SEL"||key=="GROUP"||key=="LOCK")){
   if(key=="SEL")line="SEL 0";else if(key=="GROUP")line="GROUP 0";else line="LOCK 1";
  }
  out<<line<<'\n';if(key=="<TAKEFX")out<<"SHOW 0\n";if(!t.empty()&&t[0]=='<')depth++;else if(t==">")depth--;
 }
 return out.str();
}
}
