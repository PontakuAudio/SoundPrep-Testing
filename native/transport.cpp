#include "platform.h"
#include "contract.h"
// Audition Macro's transport events and API registration for the embedded bar.
// macOS/SWELL and Windows x64. No decoding, audio processing or plugin hosting happens here.
// The four-field REAPER entry ABI is documented by Cockos in reaper_plugin.h:
// https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h
// JS APIs are resolved after startup to avoid extension load-order dependencies.
#include <array>
#include <cstdint>
#include <unordered_map>
#ifdef AM_EMBEDDED_BAR
#ifdef _WIN32
extern "C" void AMPlatformRegister(int(*)(const char*,void*),void*(*)(const char*));
extern "C" void AMBarKeyboardRegister(int(*)(const char*,void*),bool);
extern "C" void AMWinSearchDetach();
extern "C" const char* AMDropDiagnostics();
#endif
extern "C" bool AMBarAttach(void*, void*);
extern "C" bool AMBarSetState(const char*);
extern "C" const char* AMBarPoll();
extern "C" const char* AMBarGeometry();
extern "C" void AMBarDetach();
extern "C" void AMSearchRegister(int(*)(const char*,void*),void*(*)(const char*));
extern "C" bool AMDropAttach(void*,void*,void*,void*,int,void*(*)(const char*));
extern "C" bool AMDropAttachSources(void*,void*,void*,void*,void*,int,void*(*)(const char*));
extern "C" void AMDropDetach();
extern "C" const char* AMDropContext();
extern "C" void AMDropResult(bool);
extern "C" const char* AMExecutablePath();
extern "C" void AMPrepareFocus(int);
extern "C" void AMPreviewRegister(int(*)(const char*,void*),void*(*)(const char*));
extern "C" void AMPreviewControl(void*);
extern "C" void AMPreviewUnbind();
extern "C" void AMPreviewClose();
extern "C" void AMAnalysisRegister(int(*)(const char*,void*),void*(*)(const char*));
extern "C" void AMAnalysisClose();
extern "C" bool AMWaveAttach(void*,void*,void*,void*(*)(const char*));
extern "C" const char* AMWavePoll();
extern "C" const char* AMWaveDiagnostics();
extern "C" void AMWaveDetach();
extern "C" void AMCursorRegister(int(*)(const char*,void*));
extern "C" void AMCursorRestoreClock();
extern "C" const char* AMCursorState();
extern "C" bool AMWaveSetChannelSubset(const char*,const char*,const char*);
extern "C" bool AMWaveSetChannelNames(const char*,const char*,const char*);
extern "C" bool AMWaveSetChannels(const char*,int,int,const char*);
extern "C" void AMCursorZoom(int);
extern "C" void AMCursorViewportChanged();
#endif

namespace am {
static void* helper_info_var(void**,int) { return const_cast<char*>(amcontract::helper_info()); }
using Window = void*;
using Proc = std::intptr_t (*)(Window, unsigned, std::uintptr_t, std::intptr_t);
struct PluginInfo {
  int caller_version;
  Window main_window;
  int (*Register)(const char*, void*);
  void* (*GetFunc)(const char*);
};
static PluginInfo host{};
static void* (*get_long)(Window, const char*) = nullptr;
static void (*set_long)(Window, const char*, double, double*) = nullptr;
static bool (*is_window)(Window) = nullptr;
static std::unordered_map<Window, Proc> originals;
static Window active = nullptr;
static std::array<int, 64> queue{};
static unsigned read_index = 0, write_index = 0;
static unsigned suppression = 0;
static bool own_audio = false;

static bool transport(int command) {
  switch (command) {
    case 1008: case 1009: case 1010: case 1068: case 40016:
    case 40024: case 40025: case 40027: case 40028: case 40031: case 40033: case 40034:
    case 40039: case 40040: case 42185: case 42186: return true;
    default: return false;
  }
}
static void push(int command) {
  if (write_index - read_index == queue.size()) ++read_index;
  queue[write_index++ % queue.size()] = command;
}
static std::intptr_t callback(Window window, unsigned message, std::uintptr_t wp, std::intptr_t lp) {
  const auto it = originals.find(window);
  if (it == originals.end()) return 0;
  const Proc original = it->second;
#ifdef AM_EMBEDDED_BAR
  if(window==active && (message==0x111 || message==0x114 || message==0x115))AMCursorRestoreClock();
#endif
  // Capture before calling REAPER: its handler synchronously emits many more
  // WM_COMMAND notifications, which is why JS's single-message mailbox failed.
  const int command=static_cast<int>(wp & 0xffff);
  if (window == active && suppression == 0 && message == 0x111 && transport(command)) {
    push(command);
    // CF owns playback while the companion is attached. Native Stop on an
    // already-stopped preview unloads the waveform; native Play also starts a
    // second EOF clock. Keep both away from the native audio handler. Repeat
    // still forwards so its standard toggle and toolbar remain authoritative.
    if (own_audio && command!=1068 && command!=40039 && command!=40040 && command!=40016) return 0;
  }
  const auto result = am_call_proc(original,window,message,wp,lp);
#ifdef AM_EMBEDDED_BAR
  if(window==active && message==0x111 && command>=42092 && command<=42095)AMCursorZoom(command);
  if(window==active && (message==0x7b || message==0x111 || message==0x114 || message==0x115))AMCursorViewportChanged();
  if(window==active && own_audio && suppression==0 && (message==0x111 || message==0x114))AMPreviewControl(window);
#endif
  if (message == 0x0002 && window == active) {
    active = nullptr; read_index = write_index = 0;
  }
  if (message == 0x0082) originals.erase(window);
  return result;
}
static bool resolve() {
  get_long = reinterpret_cast<decltype(get_long)>(host.GetFunc("JS_Window_GetLongPtr"));
  set_long = reinterpret_cast<decltype(set_long)>(host.GetFunc("JS_Window_SetLong"));
  is_window = reinterpret_cast<decltype(is_window)>(host.GetFunc("JS_Window_IsWindow"));
  return get_long && set_long && is_window;
}
static void detach() {
#ifdef AM_EMBEDDED_BAR
  AMPreviewUnbind();
  AMWaveDetach();
#endif
  active = nullptr; read_index = write_index = 0; suppression = 0; own_audio = false;
  if (!get_long || !set_long || !is_window) return;
  for (auto it = originals.begin(); it != originals.end();) {
    if (!is_window(it->first)) { it = originals.erase(it); continue; }
    if (get_long(it->first, "WNDPROC") == reinterpret_cast<void*>(callback)) {
      double unused = 0;
      set_long(it->first, "WNDPROC", static_cast<double>(reinterpret_cast<std::uintptr_t>(it->second)), &unused);
      it = originals.erase(it);
    } else {
      // Another extension is above us. Preserve its callback chain; our inactive
      // callback continues forwarding. Never overwrite another owner's WndProc.
      ++it;
    }
  }
}
static bool attach(Window window) {
  if (!resolve() || !window || !is_window(window)) return false;
  detach();
  const auto address = reinterpret_cast<std::uintptr_t>(callback);
  if (static_cast<std::uintptr_t>(static_cast<double>(address)) != address) return false;
  const auto previous = reinterpret_cast<Proc>(get_long(window, "WNDPROC"));
  if (!previous) return false;
  const auto previous_address = reinterpret_cast<std::uintptr_t>(previous);
  if (static_cast<std::uintptr_t>(static_cast<double>(previous_address)) != previous_address) return false;
  if (originals.count(window)) {
    // We may still be underneath another extension. Adding a second copy of
    // this callback above that extension would create a recursive chain.
    active = window; return true;
  }
  if (previous != callback) {
    originals[window] = previous;
    double old = 0;
    set_long(window, "WNDPROC", static_cast<double>(address), &old);
    if (get_long(window, "WNDPROC") != reinterpret_cast<void*>(callback)) {
      originals.erase(window); return false;
    }
  } else if (!originals.count(window)) return false;
  active = window;
  return true;
}
static int poll() {
  return read_index == write_index ? 0 : queue[read_index++ % queue.size()];
}
static void suppress(bool on) {
  if (on) ++suppression;
  else if (suppression) --suppression;
}
static void own(bool on) { own_audio = active && on; }
static void* attach_var(void** p, int n) { return reinterpret_cast<void*>(static_cast<std::intptr_t>(n == 1 && attach(p[0]))); }
static void* poll_var(void**, int) { return reinterpret_cast<void*>(static_cast<std::intptr_t>(poll())); }
static void* detach_var(void**, int) { detach(); return nullptr; }
static void* suppress_var(void** p, int n) { if (n == 1) suppress(p[0] != nullptr); return nullptr; }
static void* own_var(void** p, int n) { if (n == 1) own(p[0] != nullptr); return nullptr; }
#ifdef AM_EMBEDDED_BAR
static bool bar_attach(Window parent, Window list) {
  return resolve() && is_window(parent) && is_window(list) && AMBarAttach(parent,list);
}
static void* bar_attach_var(void** p,int n) { return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==2 && bar_attach(p[0],p[1]))); }
static void* bar_state_var(void** p,int n) { return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==1 && AMBarSetState(static_cast<const char*>(p[0])))); }
static void* bar_poll_var(void**,int) { return const_cast<char*>(AMBarPoll()); }
static void* bar_geometry_var(void**,int) { return const_cast<char*>(AMBarGeometry()); }
static void* bar_detach_var(void**,int) { AMBarDetach(); return nullptr; }
static bool drop_attach(Window main,Window arrange,Window wave,void* project,int command) {
  return AMDropAttach(main,arrange,wave,project,command,host.GetFunc);
}
static void* drop_attach_var(void** p,int n) { return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==5 && drop_attach(p[0],p[1],p[2],p[3],static_cast<int>(reinterpret_cast<std::intptr_t>(p[4]))))); }
static bool drop_sources(Window main,Window arrange,Window wave,Window list,void* project,int command) {
  return AMDropAttachSources(main,arrange,wave,list,project,command,host.GetFunc);
}
static void* drop_sources_var(void** p,int n) { return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==6 && drop_sources(p[0],p[1],p[2],p[3],p[4],static_cast<int>(reinterpret_cast<std::intptr_t>(p[5]))))); }
static void* drop_context_var(void**,int) { return const_cast<char*>(AMDropContext()); }
static void* drop_result_var(void** p,int n) { if(n==1)AMDropResult(p[0]!=nullptr);return nullptr; }
static void* drop_detach_var(void**,int) { AMDropDetach();return nullptr; }
static void* executable_var(void**,int) { return const_cast<char*>(AMExecutablePath()); }
static void* prepare_focus_var(void** p,int n) { if(n==1)AMPrepareFocus(static_cast<int>(reinterpret_cast<std::intptr_t>(p[0])));return nullptr; }
static bool wave_attach(Window parent,Window wave,Window clock) {return AMWaveAttach(parent,wave,clock,host.GetFunc);}
static void* wave_attach_var(void** p,int n) {return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==3 && wave_attach(p[0],p[1],p[2])));}
static void* wave_poll_var(void**,int) {return const_cast<char*>(AMWavePoll());}
static void* cursor_state_var(void**,int) {return const_cast<char*>(AMCursorState());}
#endif

static void register_api(const char* name, void* api, void* wrapper, const char* definition) {
  // Names are compile-time literals below; avoid any allocation in callbacks.
  char key[128];
  const auto register_one = [&](const char* prefix, void* function) {
    unsigned i = 0;
    for (const char* p = prefix; *p; ++p) key[i++] = *p;
    for (const char* p = name; *p; ++p) key[i++] = *p;
    key[i] = 0; host.Register(key, function);
  };
  register_one("API_", api); register_one("APIvararg_", wrapper);
  register_one("APIdef_", const_cast<char*>(definition));
}
} // namespace am

extern "C" AM_EXPORT int ReaperPluginEntry(void*, am::PluginInfo* info) {
  if (!info) {
#ifdef AM_EMBEDDED_BAR
    AMBarDetach();
#ifdef _WIN32
    AMBarKeyboardRegister(am::host.Register,false);
    AMWinSearchDetach();
#endif
    AMDropDetach();
    AMAnalysisClose();
    AMPreviewClose();
#endif
    // JS can be unloaded before this extension during REAPER shutdown.
    if (am::host.GetFunc && am::resolve()) am::detach();
    return 0;
  }
  if (info->caller_version != 0x20e || !info->Register || !info->GetFunc) return 0;
  am::host = *info;
  am::register_api("AM_HelperInfo", reinterpret_cast<void*>(amcontract::helper_info), reinterpret_cast<void*>(am::helper_info_var),
    "const char*\0\0\0Read the loaded native helper version, platform and supported feature revisions. No project changes.");
  am::register_api("AM_TransportAttach", reinterpret_cast<void*>(am::attach), reinterpret_cast<void*>(am::attach_var),
    "bool\0void*\0window\0Attach a main-thread Media Explorer transport observer.");
  am::register_api("AM_TransportPoll", reinterpret_cast<void*>(am::poll), reinterpret_cast<void*>(am::poll_var),
    "int\0\0\0Pop a transport action ID, or zero. Call from ReaScript only.");
  am::register_api("AM_TransportDetach", reinterpret_cast<void*>(am::detach), reinterpret_cast<void*>(am::detach_var),
    "void\0\0\0Detach only this observer and preserve other extensions' callback chains.");
  am::register_api("AM_TransportSuppress", reinterpret_cast<void*>(am::suppress), reinterpret_cast<void*>(am::suppress_var),
    "void\0bool\0on\0Nestable suppression of commands sent by the companion itself.");
  am::register_api("AM_TransportOwnAudio", reinterpret_cast<void*>(am::own), reinterpret_cast<void*>(am::own_var),
    "void\0bool\0on\0Route attached native audio commands exclusively to the companion queue, preserving waveform media. Repeat and suppressed commands still forward.");
#ifdef AM_EMBEDDED_BAR
  AMPreviewRegister(info->Register,info->GetFunc);
  AMAnalysisRegister(info->Register,info->GetFunc);
  AMCursorRegister(info->Register);
  AMSearchRegister(info->Register,info->GetFunc);
#ifdef _WIN32
  AMPlatformRegister(info->Register,info->GetFunc);
  AMBarKeyboardRegister(info->Register,true);
  am::register_api("AM_DropDiagnostics",reinterpret_cast<void*>(AMDropDiagnostics),
    reinterpret_cast<void*>(+[](void**,int)->void*{return const_cast<char*>(AMDropDiagnostics());}),
    "const char*\0\0\0Read the bounded Windows drop trace and adapter revision. No project changes.");
#endif
  am::register_api("AM_WaveSetChannelNames",reinterpret_cast<void*>(AMWaveSetChannelNames),
    reinterpret_cast<void*>(+[](void** p,int n)->void*{return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==3 && AMWaveSetChannelNames(static_cast<const char*>(p[0]),static_cast<const char*>(p[1]),static_cast<const char*>(p[2]))));}),
    "bool\0const char*,const char*,const char*\0path,identity,names\0Label selected waveform lanes with a source-channel-indexed JSON array of microphone names. Empty names retain channel numbers.");
  am::register_api("AM_WaveSetChannelSubset",reinterpret_cast<void*>(AMWaveSetChannelSubset),
    reinterpret_cast<void*>(+[](void** p,int n)->void*{return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==3 && AMWaveSetChannelSubset(static_cast<const char*>(p[0]),static_cast<const char*>(p[1]),static_cast<const char*>(p[2]))));}),
    "bool\0const char*,const char*,const char*\0path,channels,identity\0Display only the comma-separated 1-based source channels. Empty path restores native peaks.");
  am::register_api("AM_WaveSetChannels",reinterpret_cast<void*>(AMWaveSetChannels),
    reinterpret_cast<void*>(+[](void** p,int n)->void*{return reinterpret_cast<void*>(static_cast<std::intptr_t>(n==4 && AMWaveSetChannels(static_cast<const char*>(p[0]),static_cast<int>(reinterpret_cast<std::intptr_t>(p[1])),static_cast<int>(reinterpret_cast<std::intptr_t>(p[2])),static_cast<const char*>(p[3]))));}),
    "bool\0const char*,int,int,const char*\0path,left,right,identity\0Display selected source peaks in Media Explorer; 0/0 restores native peaks. Mouse gestures remain native.");
  am::register_api("AM_WaveCursorState",reinterpret_cast<void*>(AMCursorState),reinterpret_cast<void*>(am::cursor_state_var),
    "const char*\0\0\0Read cursor rendering diagnostics; no audio or UI changes.");
  am::register_api("AM_WaveAttach",reinterpret_cast<void*>(am::wave_attach),reinterpret_cast<void*>(am::wave_attach_var),
    "bool\0void*,void*,void*\0parent,wave,clock\0Observe native waveform seeks after REAPER resolves zoom and scroll; forwards all gestures.");
  am::register_api("AM_WavePoll",reinterpret_cast<void*>(AMWavePoll),reinterpret_cast<void*>(am::wave_poll_var),
    "const char*\0\0\0Consume the last native waveform seek as JSON; empty when unchanged.");
  am::register_api("AM_WaveDiagnostics",reinterpret_cast<void*>(AMWaveDiagnostics),
    reinterpret_cast<void*>(+[](void**,int)->void*{return const_cast<char*>(AMWaveDiagnostics());}),
    "const char*\0\0\0Read waveform gesture delivery and the last resolved seek without consuming events.");
  am::register_api("AM_ExecutablePath", reinterpret_cast<void*>(AMExecutablePath), reinterpret_cast<void*>(am::executable_var),
    "const char*\0\0\0Executable path of this REAPER process.");
  am::register_api("AM_PrepareFocus", reinterpret_cast<void*>(AMPrepareFocus), reinterpret_cast<void*>(am::prepare_focus_var),
    "void\0int\0pid\0Restore parent focus only if its owned render worker is foreground.");
  am::register_api("AM_DropAttach", reinterpret_cast<void*>(am::drop_attach), reinterpret_cast<void*>(am::drop_attach_var),
    "bool\0void*,void*,void*,ReaProject*,int\0main,arrange,wave,project,command\0Attach an instance-local native waveform-to-Arrange/TCP drop transaction.");
  am::register_api("AM_DropAttachSources", reinterpret_cast<void*>(am::drop_sources), reinterpret_cast<void*>(am::drop_sources_var),
    "bool\0void*,void*,void*,void*,ReaProject*,int\0main,arrange,wave,list,project,command\0Attach processed waveform and file-list drops to Arrange and track control panels.");
  am::register_api("AM_DropContext", reinterpret_cast<void*>(AMDropContext), reinterpret_cast<void*>(am::drop_context_var),
    "const char*\0\0\0Current synchronous drop transaction, or empty outside a drop.");
  am::register_api("AM_DropResult", reinterpret_cast<void*>(AMDropResult), reinterpret_cast<void*>(am::drop_result_var),
    "void\0bool\0ok\0Acknowledge the current synchronous transaction phase.");
  am::register_api("AM_DropDetach", reinterpret_cast<void*>(AMDropDetach), reinterpret_cast<void*>(am::drop_detach_var),
    "void\0\0\0Detach waveform drop processing and restore native view classes.");
  am::register_api("AM_BarAttach", reinterpret_cast<void*>(am::bar_attach), reinterpret_cast<void*>(am::bar_attach_var),
    "bool\0void*,void*\0parent,list\0Attach a native child toolbar above Media Explorer's file list.");
  am::register_api("AM_BarSetState", reinterpret_cast<void*>(AMBarSetState), reinterpret_cast<void*>(am::bar_state_var),
    "bool\0const char*\0json\0Update the toolbar from the companion's JSON state.");
  am::register_api("AM_BarPoll", reinterpret_cast<void*>(AMBarPoll), reinterpret_cast<void*>(am::bar_poll_var),
    "const char*\0\0\0Pop a toolbar command, or an empty string.");
  am::register_api("AM_BarGeometry", reinterpret_cast<void*>(AMBarGeometry), reinterpret_cast<void*>(am::bar_geometry_var),
    "const char*\0\0\0Return toolbar geometry diagnostics as JSON.");
  am::register_api("AM_BarDetach", reinterpret_cast<void*>(AMBarDetach), reinterpret_cast<void*>(am::bar_detach_var),
    "void\0\0\0Remove only our child view and restore the native list size.");
#endif
  return 1;
}
