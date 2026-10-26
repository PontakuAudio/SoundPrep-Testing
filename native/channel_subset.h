// Strict, bounded 1-based channel lists shared by preview and waveform APIs.
#pragma once
#include <array>
#include <algorithm>
#include <vector>
namespace amchannels {
inline bool parse(const char* text,std::vector<int>& result) {
  result.clear();if(!text || !*text)return false;
  std::array<bool,129> seen{};
  for(const char* p=text;*p;) {
    int value=0,digits=0;
    while(*p>='0' && *p<='9') {if(++digits>3)return false;value=value*10+(*p++-'0');}
    if(!digits || value<1 || value>128 || seen[value])return false;
    seen[value]=true;result.push_back(value);
    if(*p==',') {if(!*++p)return false;}else if(*p)return false;
  }
  return result.size()<=2 || std::is_sorted(result.begin(),result.end());
}
}
