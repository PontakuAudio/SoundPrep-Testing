#pragma once
#include "common.h"

// A short, synchronous scope around our item-render/peak actions only. Match
// REAPER's progress controls, not localized captions. Errors, plug-in dialogs,
// and any other windows remain visible. Long operations retain native Cancel.
namespace amwin {
class QuietRender {
  struct Window {HWND hwnd;ULONGLONG began;UINT_PTR timer;bool hidden;bool noActivate;};
  HHOOK messages=nullptr,activation=nullptr;
  std::vector<Window> windows;
  inline static thread_local QuietRender* active=nullptr;
  static constexpr UINT delay=1000;
  static UINT_PTR id(){return reinterpret_cast<UINT_PTR>(&proc);}
  static bool class_is(HWND w,const wchar_t* name){wchar_t cls[80]{};return GetClassNameW(w,cls,80) && !lstrcmpiW(cls,name);}
  static bool progress(HWND w){
    return class_is(w,L"#32770") && class_is(GetDlgItem(w,1035),L"msctls_progress32") &&
      class_is(GetDlgItem(w,IDCANCEL),L"Button") &&
      ((class_is(GetDlgItem(w,1007),L"Edit") && class_is(GetDlgItem(w,1008),L"Edit") && GetDlgItem(w,1040)) ||
       (class_is(GetDlgItem(w,1080),L"Static") && class_is(GetDlgItem(w,IDOK),L"Button")));
  }
  Window* find(HWND w){for(auto& entry:windows)if(entry.hwnd==w)return &entry;return nullptr;}
  bool suppress(HWND w){
    auto entry=find(w);return entry && entry->timer && GetTickCount64()-entry->began<delay && progress(w);
  }
  static void restore_activation(Window& entry){
    if(entry.noActivate){
      SetWindowLongPtrW(entry.hwnd,GWL_EXSTYLE,GetWindowLongPtrW(entry.hwnd,GWL_EXSTYLE)&~WS_EX_NOACTIVATE);
      entry.noActivate=false;
    }
  }
  static LRESULT CALLBACK proc(HWND w,UINT msg,WPARAM wp,LPARAM lp,UINT_PTR,DWORD_PTR data){
    auto self=reinterpret_cast<QuietRender*>(data);auto entry=self->find(w);
    if(msg==WM_NCDESTROY){
      if(entry && entry->timer)KillTimer(w,entry->timer);
      RemoveWindowSubclass(w,proc,id());
      self->windows.erase(std::remove_if(self->windows.begin(),self->windows.end(),[w](const Window& e){return e.hwnd==w;}),self->windows.end());
    }else if(msg==WM_SHOWWINDOW && wp && entry && self->suppress(w)){
      // Vetoing HCBT_ACTIVATE alone can leave Windows with no foreground
      // window. Prevent the activation request before it deactivates the old one.
      auto style=GetWindowLongPtrW(w,GWL_EXSTYLE);
      if(!(style&WS_EX_NOACTIVATE)){entry->noActivate=true;SetWindowLongPtrW(w,GWL_EXSTYLE,style|WS_EX_NOACTIVATE);}
    }else if(msg==WM_WINDOWPOSCHANGING && entry && progress(w)){
      auto pos=reinterpret_cast<WINDOWPOS*>(lp);
      if((pos->flags&SWP_SHOWWINDOW) && self->suppress(w)){pos->flags&=~SWP_SHOWWINDOW;entry->hidden=true;}
    }else if(msg==WM_TIMER && entry && entry->timer && wp==entry->timer){
      KillTimer(w,entry->timer);entry->timer=0;
      restore_activation(*entry);
      if(entry->hidden){entry->hidden=false;ShowWindow(w,SW_SHOWNOACTIVATE);}
      return 0;
    }
    return DefSubclassProc(w,msg,wp,lp);
  }
  static LRESULT CALLBACK message(int code,WPARAM wp,LPARAM lp){
    auto self=active;
    if(code>=0 && self){auto m=reinterpret_cast<CWPSTRUCT*>(lp);
      if(m->message==WM_INITDIALOG && !(GetWindowLongPtrW(m->hwnd,GWL_STYLE)&WS_CHILD) && !self->find(m->hwnd)){
        // Install before WM_INITDIALOG constructs controls / calls ShowWindow.
        try{
          self->windows.push_back({m->hwnd,GetTickCount64(),0,false,false});
          if(SetWindowSubclass(m->hwnd,proc,id(),reinterpret_cast<DWORD_PTR>(self)))
            self->windows.back().timer=SetTimer(m->hwnd,id(),delay,nullptr);
          else self->windows.pop_back();
        }catch(...){/* Allocation failure leaves native UI unchanged. */}
      }
    }
    return CallNextHookEx(self?self->messages:nullptr,code,wp,lp);
  }
  static LRESULT CALLBACK cbt(int code,WPARAM wp,LPARAM lp){
    auto self=active;
    if(self && (code==HCBT_ACTIVATE || code==HCBT_SETFOCUS) && self->suppress(GetAncestor(reinterpret_cast<HWND>(wp),GA_ROOT)))return 1;
    return CallNextHookEx(self?self->activation:nullptr,code,wp,lp);
  }
public:
  QuietRender(){
    if(active)return;
    active=this;
    activation=SetWindowsHookExW(WH_CBT,cbt,nullptr,GetCurrentThreadId());
    if(activation)messages=SetWindowsHookExW(WH_CALLWNDPROC,message,nullptr,GetCurrentThreadId());
  }
  ~QuietRender(){
    if(active!=this)return;
    if(messages)UnhookWindowsHookEx(messages);
    if(activation)UnhookWindowsHookEx(activation);
    active=nullptr;
    for(auto& entry:windows){
      if(entry.timer)KillTimer(entry.hwnd,entry.timer);
      RemoveWindowSubclass(entry.hwnd,proc,id());
      restore_activation(entry);
      if(entry.hidden && IsWindow(entry.hwnd))ShowWindow(entry.hwnd,SW_SHOWNOACTIVATE);
    }
  }
  QuietRender(const QuietRender&)=delete;
  QuietRender& operator=(const QuietRender&)=delete;
};
}
