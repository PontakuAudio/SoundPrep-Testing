#pragma once
#include <string>
inline std::string am_json_quote(const char* text){
  std::string out="\"";const char* hex="0123456789abcdef";
  for(const unsigned char* p=reinterpret_cast<const unsigned char*>(text);*p;++p){
    if(*p=='"' || *p=='\\'){out+='\\';out+=static_cast<char>(*p);}
    else if(*p<32){out+="\\u00";out+=hex[*p>>4];out+=hex[*p&15];}
    else out+=static_cast<char>(*p);
  }
  return out+'"';
}
