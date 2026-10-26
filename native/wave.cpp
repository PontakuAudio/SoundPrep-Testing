#include "platform.h"
// Observe the standard waveform AFTER REAPER interprets a gesture. Coordinates,
// zoom, scrolling, range edits and drag/drop remain entirely owned by REAPER.
#include "json_write.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>

extern "C" bool AMPreviewWaveSeek(const char*,double,double,double,unsigned);
extern "C" void AMWaveDetach();
extern "C" bool AMCursorAttach(void*,void*,void*(*)(const char*));
extern "C" void AMCursorDetach();
extern "C" void AMCursorRestoreClock();
extern "C" void AMCursorSuspend(bool);
extern "C" void AMCursorClear();
extern "C" void AMCursorRefresh();
extern "C" void AMCursorAnchor(const char*,double,int);
extern "C" void AMCursorViewportChanged();
namespace {
using Window=void*;
using Proc=std::intptr_t(*)(Window,unsigned,std::uintptr_t,std::intptr_t);
using Info=bool(*)(char*,int,int*,double*,double*,double*,double*,double*,double*,char*,int);
Info info;
int (*title)(Window,char*,int);
void* (*get_long)(Window,const char*);
void (*set_long)(Window,const char*,double,double*);
bool (*is_window)(Window);
int (*toggle)(int,int);
std::intptr_t (*send_message)(Window,unsigned,std::uintptr_t,std::intptr_t);
std::unordered_map<Window,Proc> originals;
Window active=nullptr,parent=nullptr,clock_window=nullptr;
struct Gesture {
  bool pressed=false,dragged=false,modified=false,released=false,cancelled=false,queued=false;
  int x=0,y=0,depth=0;
} gesture;
unsigned generation=0,downs=0,releases=0,queued_releases=0,cancellations=0;
unsigned sequence=0;
std::string pending,last_event;

// A native Windows DragDetect/modal loop can consume the release without ever
// dispatching WM_LBUTTONUP to this window. Observe it before consumption, then
// seek only AFTER the outer native handler has resolved the click and clock.
void observe(unsigned message,std::uintptr_t flags,int x,int y,bool queued=false) {
  if(!gesture.pressed)return;
  if(message==0x200 || message==0x202) {
    if(std::abs(x-gesture.x)>3 || std::abs(y-gesture.y)>3)gesture.dragged=true;
    if(flags&(4|8))gesture.modified=true;
    if(message==0x202) {
      if(!gesture.released)++releases;
      gesture.released=true;
      if(queued){gesture.queued=true;++queued_releases;}
    }
  } else if(message==0x1f || (message==0x215 && !gesture.released) ||
      (message==0x100 && flags==27)) {
    if(!gesture.cancelled)++cancellations;
    gesture.cancelled=true;
  }
}
#ifdef _WIN32
LRESULT CALLBACK queued_mouse(int code,WPARAM action,LPARAM value) {
  if(code>=0 && action==PM_REMOVE && gesture.pressed && active) {
    const auto* m=reinterpret_cast<const MSG*>(value);
    if(m->message==WM_KEYDOWN && m->wParam==VK_ESCAPE)observe(m->message,m->wParam,0,0);
    if((m->message==WM_MOUSEMOVE || m->message==WM_LBUTTONUP) &&
        (m->hwnd==active || GetCapture()==active)) {
      POINT p{static_cast<short>(LOWORD(m->lParam)),static_cast<short>(HIWORD(m->lParam))};
      if(m->hwnd!=active){p=m->pt;ScreenToClient(static_cast<HWND>(active),&p);}
      observe(m->message,m->wParam,p.x,p.y,true);
    }
  }
  return CallNextHookEx(nullptr,code,action,value);
}
#endif

double seconds(const char* text,const char** end) {
  double result=0,part=0;const char* p=text;
  while(*p==' ')++p;
  if(*p<'0' || *p>'9')return -1;
  do {
    char* next=nullptr;part=std::strtod(p,&next);
    if(next==p || !std::isfinite(part) || part<0)return -1;
    result=result*60+part;if(!std::isfinite(result))return -1;p=next;
    if(*p!=':')break;
    ++p;
  }while(true);
  if(end)*end=p;
  return result;
}
double clock_fraction(const char* text) {
  const char* end=nullptr;const double at=seconds(text,&end);
  if(at<0 || !end)return -1;
  const char* slash=std::strchr(end,'/');if(!slash)return -1;
  const double length=seconds(slash+1,nullptr);
  return length>0 ? std::clamp(at/length,0.0,1.0) : -1;
}
void capture() {
  if(!active || !is_window(clock_window) || !is_window(parent))return;
  char path[4096]{},extra[128]{},text[256]{};int mode=0;
  double a=0,b=1,pitch=0,gain=0,rate=1,bpm=0;
  if(!info(path,sizeof(path),&mode,&a,&b,&pitch,&gain,&rate,&bpm,extra,sizeof(extra)))return;
  // Whole-second/beat display rounds the cursor. Ask REAPER's own formatter for
  // its precise clock synchronously, then restore the preference before paint.
  const bool rounded=toggle(32063,40032)==1;
  if(rounded)send_message(parent,0x111,40032,0);
  title(clock_window,text,sizeof(text));
  if(rounded)send_message(parent,0x111,40032,0);
  const double relative=clock_fraction(text);if(relative<0)return;
  if(!std::isfinite(a) || !std::isfinite(b))return;
  if(!(mode&384) || b<=a){a=0;b=1;}
  const double where=a+relative*(b-a); // Native clock is relative to the selected section.
  AMCursorAnchor(path,where,gesture.x);
  ++sequence;
  const bool applied=AMPreviewWaveSeek(path,where,a,b,sequence);
  char values[320];
  std::snprintf(values,sizeof(values),",\"fraction\":%.17g,\"a\":%.17g,\"b\":%.17g,\"sequence\":%u,\"applied\":%s,\"x\":%d,\"delivery\":\"%s\"}",where,a,b,sequence,applied?"true":"false",gesture.x,gesture.queued?"queued":"dispatched");
  pending="{\"path\":"+am_json_quote(path)+",\"clock\":"+am_json_quote(text)+values;
  last_event=pending;
}
std::intptr_t callback(Window window,unsigned message,std::uintptr_t wp,std::intptr_t lp) {
  const auto it=originals.find(window);if(it==originals.end())return 0;
  const Proc original=it->second;
  if(window==active) {
    if((message>=0x201 && message<=0x20e) || message==0x100 || message==0x101)AMCursorRestoreClock();
    const int x=static_cast<std::int16_t>(lp&0xffff),y=static_cast<std::int16_t>((lp>>16)&0xffff);
    if(message==0x201 || message==0x203) {
      AMCursorSuspend(true);
      ++generation;++downs;gesture={};gesture.pressed=true;
      gesture.modified=(wp&(4|8))!=0;gesture.x=x;gesture.y=y;
    } else observe(message,wp,x,y);
  }
  const unsigned current=generation;
  const bool tracking=window==active && gesture.pressed;
  if(tracking)++gesture.depth;
#ifdef _WIN32
  const bool mouse_call=message==0x201 || message==0x203 || message==0x200 || message==0x202;
  const HHOOK hook=tracking && gesture.depth==1 && mouse_call ?
    SetWindowsHookExW(WH_GETMESSAGE,queued_mouse,nullptr,GetCurrentThreadId()) : nullptr;
#endif
  const auto result=am_call_proc(original,window,message,wp,lp);
  if(window==active && ((message>=0x201 && message<=0x20e) ||
      message==0x7b || message==0x100 || message==0x101 || message==0x111 ||
      message==0x114 || message==0x115))AMCursorViewportChanged();
#ifdef _WIN32
  if(hook)UnhookWindowsHookEx(hook);
#endif
  if(tracking && current==generation && window==active && --gesture.depth==0 &&
      (gesture.released || gesture.cancelled)) {
    const bool click=gesture.released && !gesture.cancelled && !gesture.dragged && !gesture.modified;
    gesture.pressed=false;
    if(click){AMCursorClear();capture();}
    AMCursorSuspend(false);if(click)AMCursorRefresh();
  }
  if(message==0x2 && window==active){active=parent=clock_window=nullptr;++generation;gesture={};pending.clear();}
  if(message==0x82)originals.erase(window);
  return result;
}
}
extern "C" void AMWaveDetach() {
  AMCursorDetach();
  active=parent=clock_window=nullptr;++generation;gesture={};pending.clear();
  if(!get_long || !set_long || !is_window)return;
  for(auto it=originals.begin();it!=originals.end();) {
    if(!is_window(it->first)){it=originals.erase(it);continue;}
    if(get_long(it->first,"WNDPROC")==reinterpret_cast<void*>(callback)) {
      double unused=0;set_long(it->first,"WNDPROC",static_cast<double>(reinterpret_cast<std::uintptr_t>(it->second)),&unused);
      it=originals.erase(it);
    } else ++it; // Preserve extensions added above our observer.
  }
}
extern "C" bool AMWaveAttach(void* me,void* wave,void* clock,void*(*lookup)(const char*)) {
#define AM_LOOKUP(variable,name) variable=reinterpret_cast<decltype(variable)>(lookup(name))
  AM_LOOKUP(info,"MediaExplorerGetLastPlayedFileInfo");AM_LOOKUP(title,"JS_Window_GetTitle");
  AM_LOOKUP(get_long,"JS_Window_GetLongPtr");AM_LOOKUP(set_long,"JS_Window_SetLong");
  AM_LOOKUP(is_window,"JS_Window_IsWindow");AM_LOOKUP(toggle,"GetToggleCommandStateEx");
  AM_LOOKUP(send_message,"BR_Win32_SendMessage");
#undef AM_LOOKUP
  if(!info || !title || !get_long || !set_long || !is_window || !toggle || !send_message ||
      !is_window(me) || !is_window(wave) || !is_window(clock))return false;
  if(active==wave && parent==me && clock_window==clock)return true;
  AMWaveDetach();
  if(!originals.count(wave)) {
    Proc previous=reinterpret_cast<Proc>(get_long(wave,"WNDPROC"));if(!previous || previous==callback)return false;
    const auto address=reinterpret_cast<std::uintptr_t>(callback),old=reinterpret_cast<std::uintptr_t>(previous);
    if(static_cast<std::uintptr_t>(static_cast<double>(address))!=address ||
        static_cast<std::uintptr_t>(static_cast<double>(old))!=old)return false;
    originals[wave]=previous;double unused=0;set_long(wave,"WNDPROC",static_cast<double>(address),&unused);
    if(get_long(wave,"WNDPROC")!=reinterpret_cast<void*>(callback)){originals.erase(wave);return false;}
  }
  active=wave;parent=me;clock_window=clock;
  AMCursorAttach(wave,clock,lookup);return true;
}
extern "C" const char* AMWavePoll() {
  static std::string result;result.swap(pending);pending.clear();return result.c_str();
}
extern "C" const char* AMWaveDiagnostics() {
  static std::string result;char state[384];
  std::snprintf(state,sizeof(state),"{\"revision\":2,\"attached\":%s,\"pressed\":%s,\"downs\":%u,\"releases\":%u,\"queued_releases\":%u,\"cancellations\":%u,\"last_seek\":",
    active?"true":"false",gesture.pressed?"true":"false",downs,releases,queued_releases,cancellations);
  result=state+(last_event.empty()?"null":last_event)+"}";return result.c_str();
}
