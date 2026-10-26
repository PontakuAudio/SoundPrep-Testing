#include "transport.cpp"
#include <cassert>
#include <cstring>
#include <iostream>

static am::Proc current = nullptr;
static int forwarded = 0;
static am::Proc other_original = nullptr;
static std::intptr_t other(am::Window w, unsigned message, std::uintptr_t wp, std::intptr_t lp) {
  return other_original(w,message,wp,lp);
}
static int window_storage;
static void* window = &window_storage;
static bool valid(am::Window w) { return w == window; }
static void* get(am::Window, const char*) { return reinterpret_cast<void*>(current); }
static void set(am::Window, const char*, double value, double* old) {
  *old = static_cast<double>(reinterpret_cast<std::uintptr_t>(current));
  current = reinterpret_cast<am::Proc>(static_cast<std::uintptr_t>(value));
}
static std::intptr_t original(am::Window w, unsigned message, std::uintptr_t wp, std::intptr_t) {
  ++forwarded;
  if (message == 0x111 && wp == 1008) {
    // The nested UI update that overwrote JS_ReaScriptAPI's single notification.
    current(w, 0x111, (768u << 16) | 1456, 0);
  }
  return 42;
}
static void* lookup(const char* name) {
  if (!std::strcmp(name, "JS_Window_GetLongPtr")) return reinterpret_cast<void*>(get);
  if (!std::strcmp(name, "JS_Window_SetLong")) return reinterpret_cast<void*>(set);
  if (!std::strcmp(name, "JS_Window_IsWindow")) return reinterpret_cast<void*>(valid);
  return nullptr;
}
static const char*(*helper_info)();
static void*(*helper_info_var)(void**,int);
static int reg(const char* name, void* value) {
  if(!std::strcmp(name,"API_AM_HelperInfo"))helper_info=reinterpret_cast<decltype(helper_info)>(value);
  if(!std::strcmp(name,"APIvararg_AM_HelperInfo"))helper_info_var=reinterpret_cast<decltype(helper_info_var)>(value);
  return 1;
}
int main() {
  am::PluginInfo info{0x20e, window, reg, lookup};
  assert(ReaperPluginEntry(nullptr, &info) == 1);
  assert(helper_info && helper_info_var);
  assert(!std::strcmp(helper_info(),amcontract::helper_info()));
  assert(!std::strcmp(helper_info(),static_cast<const char*>(helper_info_var(nullptr,0))));
  current = original;
  assert(am::attach(window));
  assert(current(window, 0x111, 1008, 0) == 42);
  assert(forwarded == 2 && am::poll() == 1008 && am::poll() == 0);
  am::suppress(true); current(window, 0x111, 1009, 0); am::suppress(false);
  assert(am::poll() == 0);
  am::own(true);int before=forwarded;
  assert(current(window,0x111,1009,0)==0 && forwarded==before && am::poll()==1009);
  assert(current(window,0x111,1008,0)==0 && forwarded==before && am::poll()==1008);
  assert(current(window,0x111,1068,0)==42 && forwarded==before+1 && am::poll()==1068);
  am::suppress(true);assert(current(window,0x111,1008,0)==42);am::suppress(false);
  assert(am::poll()==0 && forwarded==before+3);
  am::own(false);
  for (int i = 0; i < 100; ++i) current(window, 0x111, 1009, 0);
  int events = 0; while (am::poll()) ++events; assert(events == 64);
  other_original=current;current=other;
  am::detach();assert(current==other);
  assert(am::attach(window));current(window,0x111,1008,0);assert(am::poll()==1008);
  am::detach();assert(current==other);
  current=other_original;
  am::detach(); assert(current == original);
  std::cout << "PASS: nested notifications, forwarding, exclusive audio ownership, suppression, bounded queue, cooperating hook, detach\n";
}
