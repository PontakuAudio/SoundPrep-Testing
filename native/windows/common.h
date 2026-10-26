#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <commctrl.h>
#include <imm.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <algorithm>
#include "../vendor/json.hpp"
namespace amwin {
using Json=nlohmann::json;
inline std::wstring wide(const std::string& value){
  if(value.empty())return {};
  int size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0);
  if(!size)throw std::runtime_error("Invalid UTF-8");
  std::wstring result(size,L'\0');MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),result.data(),size);return result;
}
inline std::string utf8(const std::wstring& value){
  if(value.empty())return {};
  int size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
  if(!size)throw std::runtime_error("Invalid UTF-16");
  std::string result(size,'\0');WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),result.data(),size,nullptr,nullptr);return result;
}
inline std::wstring text(HWND window){
  int size=GetWindowTextLengthW(window);if(size<0 || size>1024*1024)throw std::runtime_error("Control text is too long");
  std::wstring result(size+1,L'\0');int actual=GetWindowTextW(window,result.data(),size+1);result.resize(actual);return result;
}
inline void text(HWND window,const std::string& value){SetWindowTextW(window,wide(value).c_str());}
inline bool composition(HWND window){
  if(GetPropW(window,L"AuditionMacro.IME"))return true;
  HIMC context=ImmGetContext(window);if(!context)return false;
  bool active=ImmGetCompositionStringW(context,GCS_COMPSTR,nullptr,0)>0;
  ImmReleaseContext(window,context);return active;
}
inline RECT rect(HWND window,HWND parent){RECT r{};GetWindowRect(window,&r);MapWindowPoints(nullptr,parent,reinterpret_cast<POINT*>(&r),2);return r;}
inline bool inside(HWND parent,HWND child){return parent && child && (parent==child || IsChild(parent,child));}
inline int scale(HWND w,int value){return MulDiv(value,static_cast<int>(GetDpiForWindow(w)),96);}
inline HINSTANCE module(){HINSTANCE h=nullptr;GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,reinterpret_cast<LPCWSTR>(&module),&h);return h;}
inline HWND edit(HWND parent){
  HWND field=GetDlgItem(parent,1015);if(!field)return nullptr;
  COMBOBOXINFO info{sizeof(info)};
  if(GetComboBoxInfo(field,&info) && info.hwndItem)return info.hwndItem;
  return field;
}
}
