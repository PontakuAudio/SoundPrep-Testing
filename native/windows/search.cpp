#include "common.h"
#include <set>
#include <cstring>
namespace {
std::set<HWND> observed;
constexpr UINT_PTR hook=0x414d5345;
LRESULT CALLBACK observe(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR){
  if(m==WM_IME_STARTCOMPOSITION)SetPropW(w,L"AuditionMacro.IME",reinterpret_cast<HANDLE>(1));
  if(m==WM_IME_ENDCOMPOSITION)RemovePropW(w,L"AuditionMacro.IME");
  if(m==WM_NCDESTROY){observed.erase(w);RemovePropW(w,L"AuditionMacro.IME");RemoveWindowSubclass(w,observe,hook);}
  return DefSubclassProc(w,m,p,l);
}
HWND field(void* parent){
  HWND w=amwin::edit(static_cast<HWND>(parent));
  if(w && !observed.count(w) && SetWindowSubclass(w,observe,hook,0))observed.insert(w);
  return w;
}
const char* read_search(void* parent){
  static std::string result;
  try{HWND w=field(parent);result=w?amwin::Json{{"text",amwin::utf8(amwin::text(w))},{"composing",amwin::composition(w)}}.dump():"{}";}
  catch(...){result="{}";}return result.c_str();
}
bool write_search(void* parent,const char* expected,const char* next){
  try{
    HWND w=field(parent);if(!w || !expected || !next || std::strlen(next)>8192 || amwin::composition(w))return false;
    if(amwin::text(w)!=amwin::wide(expected))return false;
    DWORD start=0,end=0;SendMessageW(w,EM_GETSEL,reinterpret_cast<WPARAM>(&start),reinterpret_cast<LPARAM>(&end));
    auto value=amwin::wide(next);if(!SetWindowTextW(w,value.c_str()))return false;
    SendMessageW(w,EM_SETSEL,std::min<size_t>(start,value.size()),std::min<size_t>(end,value.size()));return true;
  }catch(...){return false;}
}
void* read_var(void** p,int n){return n==1?const_cast<char*>(read_search(p[0])):nullptr;}
void* write_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==3 && write_search(p[0],static_cast<char*>(p[1]),static_cast<char*>(p[2]))));}
}
extern "C" void AMWinSearchDetach(){
  for(HWND w:observed)if(IsWindow(w)){RemoveWindowSubclass(w,observe,hook);RemovePropW(w,L"AuditionMacro.IME");}
  observed.clear();
}
extern "C" void AMSearchRegister(int(*reg)(const char*,void*),void*(*)(const char*)){
  reg("API_AM_SearchRead",reinterpret_cast<void*>(read_search));reg("APIvararg_AM_SearchRead",reinterpret_cast<void*>(read_var));
  reg("APIdef_AM_SearchRead",const_cast<char*>("const char*\0void*\0parent\0Read native Unicode search text and IME state as JSON."));
  reg("API_AM_SearchWrite",reinterpret_cast<void*>(write_search));reg("APIvararg_AM_SearchWrite",reinterpret_cast<void*>(write_var));
  reg("APIdef_AM_SearchWrite",const_cast<char*>("bool\0void*,const char*,const char*\0parent,expected,text\0Replace matching search text unless an IME composition is active."));
}
