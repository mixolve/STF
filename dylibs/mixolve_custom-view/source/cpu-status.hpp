#pragma once
#include <string>
#include <cstdio>

namespace mx {

inline std::string trimCpuText(const std::string& s) {
 const auto start=s.find_first_not_of(" \t\r\n");
 if(start==std::string::npos)return {};
 return s.substr(start,s.find_last_not_of(" \t\r\n")-start+1);
}

// REAPER reuses its info line for mouseover explanations. Extract only a
// standalone CPU percentage from its FIRST metric. Never return hover help.
inline bool cpuFromStatus(const std::string& status,std::string& output) {
 std::string first=status;
 for(const char *sep:{" \xE2\x80\x94 "," - "}){
  auto at=first.find(sep);
  if(at!=std::string::npos)first=first.substr(0,at);
 }
 first=trimCpuText(first);
 if(first.size()>=4 && (first.compare(0,4,"CPU:")==0 || first.compare(0,4,"cpu:")==0))
  first=trimCpuText(first.substr(4));
 if(first.size()<2||first.back()!='%')return false;
 std::string num=trimCpuText(first.substr(0,first.size()-1));
 if(num.empty())return false;
 int dots=0,decimalDigits=0;
 double value=0,fraction=0,unit=1;
 bool decimal=false,hasDigit=false;
 for(char ch:num){
  if(ch=='.'||ch==','){
   if(++dots>1)return false;
   decimal=true;
  }else if(ch>='0'&&ch<='9'){
   hasDigit=true;
   if(decimal){if(++decimalDigits>6)return false;unit/=10;fraction+=(ch-'0')*unit;}
   else value=value*10+(ch-'0');
  }else return false;
 }
 value+=fraction;
 if(!hasDigit||value>1000||value<0)return false;
 char buf[32];
 std::snprintf(buf,sizeof(buf),"%04.1f",value);
 output=buf;
 return true;
}
}
