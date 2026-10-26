#include "common.h"
#include "../path_equal.h"
#include "quiet_render.h"
namespace {
HWND main_window;
void (*action)(int,int,void*)=nullptr;
bool quiet_item_action(int command,void* project){
  if(!action || (command!=40209 && command!=40245) || GetCurrentThreadId()!=GetWindowThreadProcessId(main_window,nullptr))return false;
  amwin::QuietRender quiet;action(command,0,project);return true;
}
void* quiet_item_action_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==2 && quiet_item_action(static_cast<int>(reinterpret_cast<intptr_t>(p[0])),p[1])));}
bool replace(const char* source,const char* target){try{return source && target && MoveFileExW(amwin::wide(source).c_str(),amwin::wide(target).c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);}catch(...){return false;}}
void* path_equal_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==2 && am_path_equal(static_cast<char*>(p[0]),static_cast<char*>(p[1]))));}
void* replace_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==2 && replace(static_cast<char*>(p[0]),static_cast<char*>(p[1]))));}
}
extern "C" const char* AMExecutablePath(){
  static std::string result;std::wstring path(32768,L'\0');DWORD length=GetModuleFileNameW(nullptr,path.data(),static_cast<DWORD>(path.size()));
  if(!length || length==path.size())return "";path.resize(length);try{result=amwin::utf8(path);}catch(...){result.clear();}return result.c_str();
}
extern "C" void AMPrepareFocus(int pid){DWORD foreground=0;GetWindowThreadProcessId(GetForegroundWindow(),&foreground);if(pid>0 && foreground==static_cast<DWORD>(pid) && IsWindow(main_window))SetForegroundWindow(main_window);}
extern "C" void AMPlatformRegister(int(*reg)(const char*,void*),void*(*get)(const char*)){
  auto main=reinterpret_cast<HWND(*)()>(get("GetMainHwnd"));main_window=main?main():nullptr;
  action=reinterpret_cast<void(*)(int,int,void*)>(get("Main_OnCommandEx"));
  reg("API_AM_QuietItemAction",reinterpret_cast<void*>(quiet_item_action));reg("APIvararg_AM_QuietItemAction",reinterpret_cast<void*>(quiet_item_action_var));
  reg("APIdef_AM_QuietItemAction",const_cast<char*>("bool\0int,ReaProject*\0command,project\0Apply item FX (40209) or build peaks (40245) with delayed, non-activating progress UI. Returns false if unsupported."));
  reg("API_AM_PathEqual",reinterpret_cast<void*>(am_path_equal));reg("APIvararg_AM_PathEqual",reinterpret_cast<void*>(path_equal_var));
  reg("APIdef_AM_PathEqual",const_cast<char*>("bool\0const char*,const char*\0a,b\0Compare Windows Unicode paths, ignoring case and slash direction."));
  reg("API_AM_FileReplace",reinterpret_cast<void*>(replace));reg("APIvararg_AM_FileReplace",reinterpret_cast<void*>(replace_var));
  reg("APIdef_AM_FileReplace",const_cast<char*>("bool\0const char*,const char*\0source,target\0Atomically replace a same-volume file using Unicode Windows paths."));
}
