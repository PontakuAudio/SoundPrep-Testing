#include "quiet_render.h"
#include <cassert>
#include <iostream>

namespace {
void child(HWND parent,const wchar_t* cls,int id){
  assert(CreateWindowExW(0,cls,L"",WS_CHILD|WS_VISIBLE,0,0,40,20,parent,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),amwin::module(),nullptr));
}
INT_PTR CALLBACK dialog(HWND w,UINT msg,WPARAM,LPARAM kind){
  if(msg==WM_INITDIALOG){
    child(w,L"Button",IDCANCEL);
    if(kind){
      child(w,PROGRESS_CLASSW,1035);
      if(kind==1){child(w,L"Edit",1007);child(w,L"Edit",1008);child(w,L"Static",1040);}
      else{child(w,L"Static",1080);child(w,L"Button",IDOK);}
    }
    return FALSE;
  }
  return FALSE;
}
HWND create(int kind){
  struct Template {DLGTEMPLATE dlg;WORD menu,cls,title;} data{};
  data.dlg.style=WS_POPUP|WS_CAPTION;data.dlg.cx=100;data.dlg.cy=50;
  HWND w=CreateDialogIndirectParamW(amwin::module(),&data.dlg,nullptr,dialog,kind);assert(w);return w;
}
void pump(unsigned ms){
  auto end=GetTickCount64()+ms;
  do{MSG msg;while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}Sleep(5);}while(GetTickCount64()<end);
}
}
int main(){
  INITCOMMONCONTROLSEX controls{sizeof(controls),ICC_PROGRESS_CLASS};assert(InitCommonControlsEx(&controls));
  HWND foreground=GetForegroundWindow();
  for(int kind:{1,2}){
    amwin::QuietRender quiet;HWND w=create(kind);foreground=GetForegroundWindow();ShowWindow(w,SW_SHOWNORMAL);
    assert(!IsWindowVisible(w));assert(GetForegroundWindow()==foreground);
    assert(GetWindowLongPtrW(w,GWL_EXSTYLE)&WS_EX_NOACTIVATE);
    {amwin::QuietRender nested;ShowWindow(w,SW_SHOWNOACTIVATE);assert(!IsWindowVisible(w));}
    DestroyWindow(w);
  }
  {
    amwin::QuietRender quiet;HWND error=create(0);ShowWindow(error,SW_SHOWNOACTIVATE);
    assert(IsWindowVisible(error));DestroyWindow(error);
    HWND longRender=create(1);ShowWindow(longRender,SW_SHOWNOACTIVATE);assert(!IsWindowVisible(longRender));
    pump(1100);assert(IsWindowVisible(longRender));assert(GetForegroundWindow()==foreground);
    assert(!(GetWindowLongPtrW(longRender,GWL_EXSTYLE)&WS_EX_NOACTIVATE));DestroyWindow(longRender);
  }
  // Exception cleanup must remove hooks/subclasses and reveal surviving UI.
  HWND remaining=nullptr;
  try{amwin::QuietRender quiet;remaining=create(2);ShowWindow(remaining,SW_SHOWNOACTIVATE);assert(!IsWindowVisible(remaining));throw 1;}catch(int){}
  assert(IsWindowVisible(remaining));assert(!(GetWindowLongPtrW(remaining,GWL_EXSTYLE)&WS_EX_NOACTIVATE));DestroyWindow(remaining);
  HWND normal=create(1);ShowWindow(normal,SW_SHOWNOACTIVATE);assert(IsWindowVisible(normal));DestroyWindow(normal);
  std::cout<<"PASS: short render/peaks hidden, long render visible without activation, errors visible, nested and exception cleanup\n";
}
