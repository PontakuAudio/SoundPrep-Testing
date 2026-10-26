#pragma once
#include "platform.h"
#include <cstring>
#include <string>
#include <algorithm>
inline bool am_path_equal(const char* a,const char* b){
  if(!a || !b)return false;if(!std::strcmp(a,b))return true;
#ifdef _WIN32
  auto convert=[](const char* value){int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,nullptr,0);if(n<=0)return std::wstring{};std::wstring s(n,L'\0');MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value,-1,s.data(),n);s.resize(n-1);std::replace(s.begin(),s.end(),L'/',L'\\');return s;};
  auto x=convert(a),y=convert(b);return !x.empty() && !y.empty() && CompareStringOrdinal(x.data(),static_cast<int>(x.size()),y.data(),static_cast<int>(y.size()),TRUE)==CSTR_EQUAL;
#else
  return false;
#endif
}
