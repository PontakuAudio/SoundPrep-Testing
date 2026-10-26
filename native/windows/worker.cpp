// This DLL refuses ordinary resource directories. All hooks are thread-local to
// the explicitly owned background REAPER; no other process/window is modified.
#include "common.h"
#include "../platform.h"
#include <filesystem>
#include <fstream>
extern "C" void AMPlatformRegister(int(*)(const char*,void*),void*(*)(const char*));
struct Host{int version;HWND main;int(*reg)(const char*,void*);void*(*get)(const char*);};
namespace {
Host host{};bool owned=false,started=false;unsigned ticks=0;HHOOK activation=nullptr;std::filesystem::path resource;
LRESULT CALLBACK cbt(int code,WPARAM w,LPARAM l){
  if(owned && code==HCBT_ACTIVATE)return 1;
  if(owned && code==HCBT_CREATEWND){auto info=reinterpret_cast<CBT_CREATEWNDW*>(l);if(!(info->lpcs->style&WS_CHILD))info->lpcs->dwExStyle|=WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW;}
  return CallNextHookEx(activation,code,w,l);
}
BOOL CALLBACK hide(HWND w,LPARAM){ShowWindow(w,SW_HIDE);return TRUE;}
void tick(){
  if(!owned)return;
  if(!started && ++ticks>10){
    auto add=reinterpret_cast<int(*)(bool,int,const char*,bool)>(host.get("AddRemoveReaScript"));auto run=reinterpret_cast<void(*)(int,int,void*)>(host.get("Main_OnCommandEx"));auto project=reinterpret_cast<void*(*)(int,char*,int)>(host.get("EnumProjects"));
    if(add && run && project && project(-1,nullptr,0) && host.get("JS_Window_Show") && host.get("CF_CreatePreview")){
      std::ifstream input(resource/".audition-macro-worker-command");std::string script;std::getline(input,script);if(!script.empty() && script.back()=='\r')script.pop_back();
      if(!script.empty()){started=true;int id=add(true,0,script.c_str(),true);if(id>0)run(id,0,project(-1,nullptr,0));}
    }
  }
  std::error_code e;if(std::filesystem::exists(resource/".audition-macro-worker-ready",e))EnumThreadWindows(GetCurrentThreadId(),hide,0);
}
}
extern "C" AM_EXPORT int ReaperPluginEntry(void*,Host* api){
  if(!api){if(owned)host.reg("-timer",reinterpret_cast<void*>(tick));if(activation)UnhookWindowsHookEx(activation);activation=nullptr;owned=false;return 0;}
  if(api->version!=0x20e || !api->reg || !api->get)return 0;
  try{auto path=reinterpret_cast<const char*(*)()>(api->get("GetResourcePath"));if(!path)return 0;resource=std::filesystem::u8path(path());
    if(!std::filesystem::is_regular_file(resource/".audition-macro-worker"))return 0;
    host=*api;AMPlatformRegister(api->reg,api->get);owned=true;activation=SetWindowsHookExW(WH_CBT,cbt,nullptr,GetCurrentThreadId());if(!activation){owned=false;return 0;}
    SetWindowLongPtrW(host.main,GWL_EXSTYLE,GetWindowLongPtrW(host.main,GWL_EXSTYLE)|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW);
    host.reg("timer",reinterpret_cast<void*>(tick));return 1;
  }catch(...){return 0;}
}
