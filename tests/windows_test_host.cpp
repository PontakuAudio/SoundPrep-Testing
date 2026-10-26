// Test-only bootstrap. Loaded solely from a disposable marked resource path.
// Unlike the render worker, it does not suppress native window creation/input.
#include <windows.h>
#include <filesystem>
#include <fstream>
#include <string>
struct Host {int version;HWND main;int(*reg)(const char*,void*);void*(*get)(const char*);};
namespace {
Host host{};std::filesystem::path resource;bool started=false;unsigned ticks=0;HHOOK observer=nullptr;
LRESULT CALLBACK watch(int code,WPARAM w,LPARAM l){
  if(code>=0){auto info=reinterpret_cast<CWPSTRUCT*>(l);
    if(info->message==WM_WINDOWPOSCHANGED && !(GetWindowLongPtrW(info->hwnd,GWL_STYLE)&WS_CHILD)){
      auto pos=reinterpret_cast<WINDOWPOS*>(info->lParam);
      if(pos->flags&SWP_SHOWWINDOW){
        std::wofstream log(resource/"window-shows.txt",std::ios::app);wchar_t title[512]{},cls[128]{};
        GetWindowTextW(info->hwnd,title,512);GetClassNameW(info->hwnd,cls,128);log<<L"SHOW "<<cls<<L" "<<title<<L"\n";
        for(HWND child=GetWindow(info->hwnd,GW_CHILD);child;child=GetWindow(child,GW_HWNDNEXT)){
          GetWindowTextW(child,title,512);GetClassNameW(child,cls,128);log<<GetDlgCtrlID(child)<<L" "<<cls<<L" "<<title<<L"\n";
        }
      }
    }
  }
  return CallNextHookEx(observer,code,w,l);
}
void tick() {
  if(started || ++ticks<25 || !host.get("JS_Window_Show") || !host.get("CF_CreatePreview") || !host.get("AM_BarAttach"))return;
  auto add=reinterpret_cast<int(*)(bool,int,const char*,bool)>(host.get("AddRemoveReaScript"));
  auto run=reinterpret_cast<void(*)(int,int,void*)>(host.get("Main_OnCommandEx"));
  auto project=reinterpret_cast<void*(*)(int,char*,int)>(host.get("EnumProjects"));
  if(!add || !run || !project || !project(-1,nullptr,0))return;
  std::ifstream file(resource/".audition-macro-test-command");std::string script;std::getline(file,script);
  if(!script.empty() && script.back()=='\r')script.pop_back();
  if(script.empty())return;
  started=true;
  if(std::filesystem::is_regular_file(resource/".audition-macro-test-observe-windows")){
    observer=SetWindowsHookExW(WH_CALLWNDPROC,watch,nullptr,GetCurrentThreadId());
    if(observer)std::ofstream(resource/"window-shows.txt")<<"OBSERVER READY\n";
  }
  int id=add(true,0,script.c_str(),true);if(id>0)run(id,0,project(-1,nullptr,0));
}
}
extern "C" __declspec(dllexport) int ReaperPluginEntry(void*,Host* api) {
  if(!api){if(observer)UnhookWindowsHookEx(observer);if(host.reg)host.reg("-timer",reinterpret_cast<void*>(tick));return 0;}
  if(api->version!=0x20e || !api->reg || !api->get)return 0;
  try {
    auto getPath=reinterpret_cast<const char*(*)()>(api->get("GetResourcePath"));if(!getPath)return 0;
    resource=std::filesystem::u8path(getPath());
    if(!std::filesystem::is_regular_file(resource/".audition-macro-test"))return 0;
    host=*api;return host.reg("timer",reinterpret_cast<void*>(tick));
  }catch(...){return 0;}
}
