#pragma once
#include <cstdint>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#define AM_EXPORT __declspec(dllexport)
#else
#define AM_EXPORT __attribute__((visibility("default")))
#endif
using AMProc=std::intptr_t(*)(void*,unsigned,std::uintptr_t,std::intptr_t);
inline std::intptr_t am_call_proc(AMProc proc,void* w,unsigned m,std::uintptr_t p,std::intptr_t l){
#ifdef _WIN32
  return CallWindowProcW(reinterpret_cast<WNDPROC>(proc),static_cast<HWND>(w),m,p,l);
#else
  return proc(w,m,p,l);
#endif
}
