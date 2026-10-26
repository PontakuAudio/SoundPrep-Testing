#include "wave.cpp"
#include <cassert>
#include <iostream>
#ifdef _WIN32
#include <thread>
#include <chrono>
#endif
static Proc test_proc=nullptr,other_previous=nullptr;
static int test_storage[3],forwarded=0,applied=0,viewport_changes=0,viewport_forwarded=0;
static void* test_wave=&test_storage[0];
static void* test_parent=&test_storage[1];
static void* test_clock=&test_storage[2];
static bool rounded=false;
static double cursor=0;
static bool selected=false;
static int selection_flag=256;
static bool invalid_selection=false;
static int nested=0;
static bool real_window=false;
static bool cursor_suspended=false;
extern "C" bool AMCursorAttach(void*,void*,void*(*)(const char*)){return true;}
extern "C" void AMCursorDetach(){cursor_suspended=false;}
extern "C" void AMCursorRestoreClock(){}
extern "C" void AMCursorSuspend(bool on){cursor_suspended=on;}
extern "C" void AMCursorClear(){}
extern "C" void AMCursorRefresh(){}
extern "C" void AMCursorAnchor(const char*,double,int){}
extern "C" void AMCursorViewportChanged(){++viewport_changes;viewport_forwarded=forwarded;}
extern "C" bool AMPreviewWaveSeek(const char* path,double where,double a,double b,unsigned) {
  assert(std::string(path)=="/素材.wav");
  assert(std::abs(where-(selected?.575:.625))<1e-9 && a==(selected?.2:0) && b==(selected?.8:1));++applied;return true;
}
static std::intptr_t native_proc(Window,unsigned msg,std::uintptr_t,std::intptr_t) {
  ++forwarded;
  if(msg==0x201 && nested) {
    assert(cursor_suspended);
    const int before=applied;
    if(nested==3)observe(0x200,1,60,0,true); // Drag returns to origin.
    if(nested==4)observe(0x100,27,0,0,true); // Escape cancels the modal loop.
    observe(0x202,0,20,0,true);
    if(nested==2)test_proc(test_wave,0x202,0,20); // Both paths, still one seek.
    test_proc(test_wave,0x215,0,0); // Native ReleaseCapture after the consumed UP.
    assert(applied==before); // Clock/source is not finalized until native returns.
    assert(cursor_suspended); // The native handler still owns selection paint.
    cursor=1.25;
  }
  if(msg==0x202)cursor=1.25;return 42;
}
static std::intptr_t other_proc(Window w,unsigned m,std::uintptr_t p,std::intptr_t l){return other_previous(w,m,p,l);}
static void* api(const char* name) {
  if(!std::strcmp(name,"MediaExplorerGetLastPlayedFileInfo"))return reinterpret_cast<void*>(+[](char* path,int size,int* mode,double* a,double* b,double*,double*,double*,double*,char*,int){std::snprintf(path,size,"/素材.wav");*mode=selected?selection_flag:0;*a=invalid_selection?NAN:(selected?.2:0);*b=selected?.8:1;return true;});
  if(!std::strcmp(name,"JS_Window_GetTitle"))return reinterpret_cast<void*>(+[](Window,char* out,int size){return std::snprintf(out,size,rounded?"0:%02.0f / 0:02.000":"0:%06.3f / 0:02.000",cursor);});
  if(!std::strcmp(name,"JS_Window_GetLongPtr"))return reinterpret_cast<void*>(+[](Window w,const char*)->void*{
#ifdef _WIN32
    if(real_window)return reinterpret_cast<void*>(GetWindowLongPtrW(static_cast<HWND>(w),GWLP_WNDPROC));
#else
    (void)w;
#endif
    return reinterpret_cast<void*>(test_proc);
  });
  if(!std::strcmp(name,"JS_Window_SetLong"))return reinterpret_cast<void*>(+[](Window w,const char*,double v,double* old){*old=0;
#ifdef _WIN32
    if(real_window){*old=static_cast<double>(SetWindowLongPtrW(static_cast<HWND>(w),GWLP_WNDPROC,static_cast<LONG_PTR>(v)));return;}
#else
    (void)w;
#endif
    test_proc=reinterpret_cast<Proc>(static_cast<std::uintptr_t>(v));
  });
  if(!std::strcmp(name,"JS_Window_IsWindow"))return reinterpret_cast<void*>(+[](Window w){return w==test_wave || w==test_parent || w==test_clock;});
  if(!std::strcmp(name,"GetToggleCommandStateEx"))return reinterpret_cast<void*>(+[](int,int){return rounded?1:0;});
  if(!std::strcmp(name,"BR_Win32_SendMessage"))return reinterpret_cast<void*>(+[](Window,unsigned,std::uintptr_t,std::intptr_t)->std::intptr_t{rounded=!rounded;return 1;});
  return nullptr;
}
#ifdef _WIN32
static bool use_drag_detect=false,dispatch_up=false;
static LRESULT CALLBACK modal_proc(HWND w,UINT msg,WPARAM p,LPARAM l) {
  if(msg!=WM_LBUTTONDOWN)return DefWindowProcW(w,msg,p,l);
  assert(cursor_suspended);
  const int before=applied;
  if(use_drag_detect) {
    POINT point{static_cast<short>(LOWORD(l)),static_cast<short>(HIWORD(l))};
    ClientToScreen(w,&point);assert(!DragDetect(w,point));
  } else {
    SetCapture(w);MSG next{};
    // Model the native waveform's nested mouse loop using the actual Windows
    // queue. The button-up is intentionally consumed before WNDPROC sees it.
    while(GetMessageW(&next,nullptr,0,0)>0) {
      if(dispatch_up)DispatchMessageW(&next);
      if(next.message==WM_LBUTTONUP)break;
    }
    ReleaseCapture();
  }
  assert(applied==before && cursor_suspended);cursor=1.25;return 42;
}
static void test_windows_modal() {
  WNDCLASSW cls{};cls.lpfnWndProc=modal_proc;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"AMWaveSeekTest";
  assert(RegisterClassW(&cls));
  HWND w=CreateWindowExW(0,cls.lpszClassName,L"Wave seek test",WS_OVERLAPPEDWINDOW,0,0,800,200,nullptr,nullptr,cls.hInstance,nullptr);assert(w);
  test_wave=w;real_window=true;assert(AMWaveAttach(test_parent,w,test_clock,api));
  for(int mode=0;mode<3;++mode) {
    use_drag_detect=mode==2;dispatch_up=mode==1;cursor=0;
    const int before=applied;
    assert(PostMessageW(w,WM_LBUTTONUP,0,MAKELPARAM(20,0)));
    assert(SendMessageW(w,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(20,0))==42);
    // Posted DOWN does not set the physical button state. DragDetect may return
    // immediately, leaving UP queued for normal dispatch (also a valid path).
    if(mode==2 && applied==before) {
      MSG next{};assert(PeekMessageW(&next,w,WM_LBUTTONUP,WM_LBUTTONUP,PM_REMOVE));
      DispatchMessageW(&next);
    }
    std::cerr<<"Windows modal mode="<<mode<<" applied="<<applied-before<<" cancelled="<<gesture.cancelled
      <<" dragged="<<gesture.dragged<<" released="<<gesture.released<<" "<<AMWaveDiagnostics()<<"\n";
    assert(applied==before+1 && !gesture.pressed && !gesture.cancelled && !cursor_suspended);
    const std::string event=AMWavePoll();assert(!event.empty());
    if(mode<2)assert(event.find("queued")!=std::string::npos);
  }
  // All queued movement counts, including a drag which comes back to its origin.
  use_drag_detect=false;dispatch_up=false;const int before=applied;
  assert(PostMessageW(w,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(60,0)));
  assert(PostMessageW(w,WM_LBUTTONUP,0,MAKELPARAM(20,0)));
  SendMessageW(w,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(20,0));assert(applied==before && !*AMWavePoll());
  // Exercise DragDetect with actual button state, not just posted messages.
  POINT saved{},point{20,30};GetCursorPos(&saved);
  ShowWindow(w,SW_SHOW);SetForegroundWindow(w);ClientToScreen(w,&point);SetCursorPos(point.x,point.y);
  MSG next{};while(PeekMessageW(&next,nullptr,0,0,PM_REMOVE))DispatchMessageW(&next);
  use_drag_detect=true;const int hardware_before=applied;
  INPUT down{};down.type=INPUT_MOUSE;down.mi.dwFlags=MOUSEEVENTF_LEFTDOWN;
  assert(SendInput(1,&down,sizeof(down))==1);
  std::thread release([]{
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    INPUT up{};up.type=INPUT_MOUSE;up.mi.dwFlags=MOUSEEVENTF_LEFTUP;
    assert(SendInput(1,&up,sizeof(up))==1);
  });
  const ULONGLONG deadline=GetTickCount64()+5000;
  while(applied==hardware_before && GetTickCount64()<deadline) {
    if(PeekMessageW(&next,nullptr,0,0,PM_REMOVE))DispatchMessageW(&next);
    else Sleep(1);
  }
  release.join();SetCursorPos(saved.x,saved.y);
  std::cerr<<"Windows SendInput DragDetect applied="<<applied-hardware_before<<" "<<AMWaveDiagnostics()<<"\n";
  assert(applied==hardware_before+1 && !gesture.pressed && !gesture.cancelled && *AMWavePoll());
  AMWaveDetach();DestroyWindow(w);real_window=false;
  std::cout<<"PASS: Win32 consumed/dispatched modal release, DragDetect, capture release, no duplicate seek, queued range drag\n";
}
#endif
int main() {
  {
    assert(std::abs(clock_fraction("1:02:03.456 / 2:04:06.912")-.5)<1e-12);
    assert(clock_fraction("loading")==-1 && clock_fraction("0:00.000 / 0:00.000")==-1);
    assert(clock_fraction("1e308:0 / 1")==-1 && clock_fraction("1 / 1e308:0")==-1);
    assert(clock_fraction("nan / 1")==-1 && clock_fraction("1 / inf")==-1);
    test_proc=native_proc;assert(AMWaveAttach(test_parent,test_wave,test_clock,api));
    test_proc(test_wave,0x201,1,20);assert(!*AMWavePoll() && cursor_suspended);
    assert(test_proc(test_wave,0x202,0,20)==42);assert(applied==1 && forwarded==2 && !cursor_suspended);
    assert(std::string(AMWavePoll()).find("素材.wav")!=std::string::npos);assert(!*AMWavePoll());
    const int changes=viewport_changes;
    for(unsigned msg:{0x205u,0x20au,0x114u,0x7bu,0x111u}) {
      assert(test_proc(test_wave,msg,0,0)==42);
      assert(viewport_forwarded==forwarded); // Reconcile only after native input.
    }
    assert(viewport_changes==changes+5 && applied==1 && !*AMWavePoll());
    rounded=true;test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x202,0,20);
    assert(rounded && applied==2 && *AMWavePoll());
    selected=true;test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x202,0,20);
    assert(rounded && applied==3 && *AMWavePoll());selected=false;
    for(int flag:{128,384}) {
      selection_flag=flag;selected=true;const int before=applied;
      test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x202,0,20);
      assert(applied==before+1 && *AMWavePoll());
    }
    selected=false;selection_flag=256;
    test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x200,1,60);test_proc(test_wave,0x202,0,20);
    assert(!*AMWavePoll() && !cursor_suspended); // A range drag returning to its origin is still a drag.
    test_proc(test_wave,0x201,5,20);test_proc(test_wave,0x202,4,20);assert(!*AMWavePoll());
    test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x215,0,0);test_proc(test_wave,0x202,0,20);assert(!*AMWavePoll());
    other_previous=test_proc;test_proc=other_proc;AMWaveDetach();assert(test_proc==other_proc);
    assert(AMWaveAttach(test_parent,test_wave,test_clock,api));test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x202,0,20);assert(*AMWavePoll());
    AMWaveDetach();assert(test_proc==other_proc);test_proc=other_previous;AMWaveDetach();assert(test_proc==native_proc);
    assert(AMWaveAttach(test_parent,test_wave,test_clock,api));
    const int before=applied;
    for(int mode:{1,2,3,4}) {
      nested=mode;cursor=0;test_proc(test_wave,0x201,1,20);
      assert(!gesture.pressed && !cursor_suspended);
      if(mode<=2){assert(applied==before+mode && *AMWavePoll());}
      else assert(applied==before+2 && !*AMWavePoll());
    }
    assert(std::string(AMWaveDiagnostics()).find("last_seek")!=std::string::npos);
    nested=0;invalid_selection=true;const int before_invalid=applied;
    test_proc(test_wave,0x201,1,20);test_proc(test_wave,0x202,0,20);
    assert(applied==before_invalid && !*AMWavePoll());invalid_selection=false;
    AMWaveDetach();
#ifdef _WIN32
    test_windows_modal();
#else
    (void)real_window;
#endif
    std::cout<<"PASS: native seek timing, precise rounded clock, Unicode, range/modifier/cancel exclusion, hook lifecycle\n";
  }
}
