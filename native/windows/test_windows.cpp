// Owned Win32 controls and fake REAPER APIs. No user REAPER is controlled.
#include "common.h"
#include "../test_bar_contract.h"
#include "../contract.h"
#include <shlobj.h>
#include "drop.cpp"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <map>
#include <iostream>
extern "C" bool AMBarAttach(void*,void*);
extern "C" bool AMBarSetState(const char*);
extern "C" const char* AMBarPoll();
extern "C" const char* AMBarGeometry();
extern "C" void AMBarDetach();
extern "C" void AMBarKeyboardRegister(int(*)(const char*,void*),bool);
extern "C" void AMSearchRegister(int(*)(const char*,void*),void*(*)(const char*));
extern "C" void AMWinSearchDetach();
extern "C" void AMPlatformRegister(int(*)(const char*,void*),void*(*)(const char*));
namespace test {
using Json=amwin::Json;
HWND root;std::map<std::string,void*> apis;
std::vector<std::unique_ptr<int>> items;int changes=0,nativeDrops=0,processed=0,captures=0,undoBlocks=0;bool reject=false;std::string undoLabel;size_t beforeUndo=0;
bool modalInsert=false,dialogMovesPointer=false;double selectionStart=.2,selectionEnd=.7;
std::map<int,int> displayOptions{{42026,1},{42091,1},{42134,0}};
std::vector<std::wstring> canonicalRows;
int registerApi(const char* name,void* value){apis[name]=value;return 1;}
void* get(const char* name){
#define API(n,fn) if(std::string(name)==n)return reinterpret_cast<void*>(fn)
  API("GetMainHwnd",+[]()->HWND{return root;});
  API("EnumProjects",+[](int,char*,int)->void*{return &root;});
  API("Main_OnCommandEx",+[](int,int,void*){auto ctx=Json::parse(AMDropContext());if(ctx["phase"]=="prepare" || ctx["phase"]=="capture"){if(ctx["phase"]=="capture")++captures;AMDropResult(!reject);}else if(ctx["phase"]=="prepare_captured"){
    assert(ctx["preview"]["start"]==.2 && ctx["preview"]["end"]==.7);AMDropResult(!reject);
  }else if(ctx["phase"]=="finish"){assert(ctx["items"].size()==ctx["paths"].size());++processed;AMDropResult(true);}});
  API("CountMediaItems",+[](void*){return static_cast<int>(items.size());});
  API("GetMediaItem",+[](void*,int i)->void*{return items.at(i).get();});
  API("GetSetMediaItemInfo_String",+[](void* item,const char*,char* out,bool){std::snprintf(out,128,"item-%d",*static_cast<int*>(item));return true;});
  API("Undo_BeginBlock2",+[](void*){beforeUndo=items.size();++undoBlocks;});
  API("Undo_EndBlock2",+[](void*,const char* label,int){undoLabel=label;});
  API("Undo_CanUndo2",+[](void*)->const char*{return undoLabel.c_str();});
  API("Undo_DoUndo2",+[](void*){items.resize(beforeUndo);return 1;});
  API("GetProjectStateChangeCount",+[](void*){return changes;});
  API("GetToggleCommandStateEx",+[](int,int id){return displayOptions.at(id);});
  API("MediaExplorerGetLastPlayedFileInfo",+[](char* path,int size,int* mode,double* a,double* b,double*,double*,double*,double*,char*,int){std::snprintf(path,size,"C:\\素材\\slam.wav");*mode=256;*a=selectionStart;*b=selectionEnd;return true;});
#undef API
  return nullptr;
}
LRESULT CALLBACK native(HWND w,UINT m,WPARAM p,LPARAM l){
  if(m==WM_COMMAND && displayOptions.count(LOWORD(p))){
    int id=LOWORD(p);displayOptions[id]=1-displayOptions[id];
    if(displayOptions[id] && (id==42026 || id==42134))displayOptions[id==42026?42134:42026]=0;
    HWND list=GetDlgItem(w,1001);
    for(size_t i=0;i<canonicalRows.size();++i){
      auto text=canonicalRows[i];
      if(!displayOptions[42026])text=text.substr(text.find_last_of(L"/\\")+1);
      if(!displayOptions[42091])text=text.substr(0,text.find_last_of(L'.'));
      ListView_SetItemText(list,static_cast<int>(i),0,text.data());
    }
    return 0;
  }
  if(m==WM_LBUTTONDOWN && modalInsert){
    SendMessageW(w,WM_CANCELMODE,0,0); // Nested drag-loop cancellation notification must not discard the snapshot.
    if(dialogMovesPointer){MSG release{};release.message=WM_LBUTTONUP;GetCursorPos(&release.pt);dragMessage(HC_ACTION,PM_REMOVE,reinterpret_cast<LPARAM>(&release));SetCursorPos(0,0);}
    items.push_back(std::make_unique<int>(++changes));selectionStart=0;selectionEnd=1;return 0;
  }
  if(m==WM_DROPFILES){auto h=reinterpret_cast<HDROP>(p);UINT count=DragQueryFileW(h,0xffffffff,nullptr,0);for(UINT i=0;i<count;++i)items.push_back(std::make_unique<int>(++changes));++nativeDrops;DragFinish(h);return 0;}
  return DefWindowProcW(w,m,p,l);
}
HWND create(const wchar_t* cls,int x,int y,int width,int height,HWND parent=nullptr,int id=0){
  WNDCLASSW wc{};wc.lpszClassName=cls;wc.lpfnWndProc=native;wc.hInstance=amwin::module();RegisterClassW(&wc);
  return CreateWindowExW(0,cls,L"SoundPrep test fixture",(parent?WS_CHILD:WS_OVERLAPPEDWINDOW)|WS_VISIBLE,x,y,width,height,parent,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),wc.hInstance,nullptr);
}
HDROP payload(){
  const std::wstring path=L"C:\\素材\\slam.wav";size_t size=sizeof(DROPFILES)+(path.size()+2)*sizeof(wchar_t);HGLOBAL h=GlobalAlloc(GHND,size);assert(h);auto* data=static_cast<DROPFILES*>(GlobalLock(h));data->pFiles=sizeof(DROPFILES);data->fWide=TRUE;data->pt={20,20};std::memcpy(reinterpret_cast<char*>(data)+sizeof(DROPFILES),path.c_str(),(path.size()+1)*sizeof(wchar_t));GlobalUnlock(h);return reinterpret_cast<HDROP>(h);
}
// Model ListView's button-down loop: selection changes inside the default
// handler, then queued motion and a synchronous drop arrive without another
// WM_MOUSEMOVE passing through the source subclass.
bool modalList=false,postListDrop=false;
LRESULT CALLBACK listNative(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR target){
  if(m==WM_LBUTTONDOWN && modalList){
    ListView_SetItemState(w,-1,0,LVIS_SELECTED);
    ListView_SetItemState(w,1,LVIS_SELECTED,LVIS_SELECTED);
    MSG move{};move.message=WM_MOUSEMOVE;move.pt={20,20};ClientToScreen(reinterpret_cast<HWND>(target),&move.pt);
    dragMessage(HC_ACTION,PM_REMOVE,reinterpret_cast<LPARAM>(&move));
    if(postListDrop)PostMessageW(reinterpret_cast<HWND>(target),WM_DROPFILES,reinterpret_cast<WPARAM>(payload()),0);
    else SendMessageW(reinterpret_cast<HWND>(target),WM_DROPFILES,reinterpret_cast<WPARAM>(payload()),0);
    return 0;
  }
  return DefSubclassProc(w,m,p,l);
}
HWND panelWindow(){HWND result=nullptr;EnumThreadWindows(GetCurrentThreadId(),+[](HWND w,LPARAM p)->BOOL{wchar_t cls[128]{};GetClassNameW(w,cls,128);if(std::wstring(cls)==L"AuditionMacroSearch"){*reinterpret_cast<HWND*>(p)=w;return FALSE;}return TRUE;},reinterpret_cast<LPARAM>(&result));return result;}
}
int main(){using namespace test;
  INITCOMMONCONTROLSEX cc{sizeof(cc),ICC_WIN95_CLASSES};assert(InitCommonControlsEx(&cc));
  root=create(L"AMTestRoot",10,10,1280,900);assert(root);
  HWND list=CreateWindowExW(0,WC_LISTVIEWW,L"",WS_CHILD|WS_VISIBLE|LVS_REPORT,170,40,1000,500,root,reinterpret_cast<HMENU>(1001),amwin::module(),nullptr);assert(list);
  HWND search=CreateWindowExW(0,L"COMBOBOX",L"",WS_CHILD|WS_VISIBLE|CBS_DROPDOWN|WS_TABSTOP,200,5,250,200,root,reinterpret_cast<HMENU>(1015),amwin::module(),nullptr);assert(search);
  AMSearchRegister(registerApi,get);AMPlatformRegister(registerApi,get);
  auto read=reinterpret_cast<const char*(*)(void*)>(apis.at("API_AM_SearchRead"));auto write=reinterpret_cast<bool(*)(void*,const char*,const char*)>(apis.at("API_AM_SearchWrite"));
  SetWindowTextW(search,L"金属 slam");assert(Json::parse(read(root))["text"]=="金属 slam");
  assert(!write(root,"stale","lost") && write(root,"金属 slam","metal"));
  HWND edit=amwin::edit(root);assert(edit);SendMessageW(edit,WM_IME_STARTCOMPOSITION,0,0);assert(Json::parse(read(root))["composing"]==true);assert(!write(root,"metal","lost"));
  SendMessageW(edit,WM_IME_ENDCOMPOSITION,0,0);SendMessageW(edit,EM_SETSEL,4,5);assert(write(root,"metal","hit"));DWORD start=0,end=0;SendMessageW(edit,EM_GETSEL,reinterpret_cast<WPARAM>(&start),reinterpret_cast<LPARAM>(&end));assert(start==3 && end==3);
  auto replace=reinterpret_cast<bool(*)(const char*,const char*)>(apis.at("API_AM_FileReplace"));
  auto equal=reinterpret_cast<bool(*)(const char*,const char*)>(apis.at("API_AM_PathEqual"));
  assert(equal("C:\\音\\Ä.WAV","c:/音/ä.wav") && !equal("C:/音/a.wav","D:/音/a.wav"));
  auto directory=std::filesystem::temp_directory_path()/std::filesystem::u8path("AM-test-素材-"+std::to_string(GetCurrentProcessId()));std::filesystem::create_directories(directory);
  auto old=directory/"old.json",next=directory/"next.json";std::ofstream(old)<<"old";std::ofstream(next)<<"new";assert(replace(next.u8string().c_str(),old.u8string().c_str()));std::string bytes;std::ifstream(old)>>bytes;assert(bytes=="new" && !std::filesystem::exists(next));std::filesystem::remove_all(directory);
  RECT original=amwin::rect(list,root);assert(AMBarAttach(root,list));assert(!AMBarSetState("[]"));
  test_bar_contract(AMBarSetState);
  Json state{{"active","raw"},{"macros",Json::array({{{"id","heavy"},{"label","1 Heavy"}}})},{"reverse",false},{"normalize",false},{"target",-14},{"monitor",-6},{"status","Ready"},{"paused",false},{"search",{{"open",false}}}};
  assert(AMBarSetState(state.dump().c_str()));auto geometry=Json::parse(AMBarGeometry());assert(geometry["same_window"]==true && geometry["base_height"].get<int>()==geometry["height"].get<int>()+geometry["list_height"].get<int>());
  auto invalidState=state;invalidState["paused"]=true;invalidState["macros"]=Json::array();invalidState["search"]["open"]=Json::array();
  assert(!AMBarSetState(invalidState.dump().c_str()));assert(Json::parse(AMBarGeometry())==geometry);
  HWND bar=FindWindowExW(root,nullptr,L"AuditionMacroBar",nullptr);assert(bar);SendMessageW(bar,WM_COMMAND,MAKEWPARAM(100+amcontract::edit,BN_CLICKED),0);assert(std::string(AMBarPoll())=="edit");
  assert(IsWindowEnabled(GetDlgItem(bar,100+amcontract::raw)) && IsWindowEnabled(GetDlgItem(bar,200)));
  HWND target=GetDlgItem(bar,100+amcontract::target);
  SendMessageW(target,CB_SETCURSEL,SendMessageW(target,CB_GETCOUNT,0,0)-1,0);
  SendMessageW(bar,WM_COMMAND,MAKEWPARAM(100+amcontract::target,CBN_SELCHANGE),reinterpret_cast<LPARAM>(target));
  assert(std::string(AMBarPoll())=="target:custom");
  assert(SendMessageW(target,CB_GETCURSEL,0,0)==2); // Custom opens the editor; -14 remains active.
  HWND monitor=GetDlgItem(bar,100+amcontract::monitor);
  assert(amwin::text(target)==L"Norm -14.0 LUFS" && amwin::text(monitor)==L"Monitor -6.0 dB");
  state["target_label"]="Norm 36.00 sones";assert(AMBarSetState(state.dump().c_str()));
  assert(amwin::text(target)==L"Norm 36.00 sones" && SendMessageW(target,CB_GETCOUNT,0,0)==2);
  SendMessageW(target,CB_SETCURSEL,1,0);
  SendMessageW(bar,WM_COMMAND,MAKEWPARAM(100+amcontract::target,CBN_SELCHANGE),reinterpret_cast<LPARAM>(target));
  assert(std::string(AMBarPoll())=="target:custom" && amwin::text(target)==L"Norm 36.00 sones");
  state["target_label"]="Norm 12.00 sones";assert(AMBarSetState(state.dump().c_str()));assert(amwin::text(target)==L"Norm 12.00 sones");
  state.erase("target_label");state["target"]=-15.5;state["monitor"]=-18.5;assert(AMBarSetState(state.dump().c_str()));
  assert(amwin::text(target)==L"Norm -15.5 LUFS" && amwin::text(monitor)==L"Monitor -18.5 dB");
  SendMessageW(bar,WM_COMMAND,MAKEWPARAM(100+amcontract::target,CBN_SELCHANGE),reinterpret_cast<LPARAM>(target));
  assert(std::string(AMBarPoll())=="target:-15.5");
  SendMessageW(bar,WM_COMMAND,MAKEWPARAM(100+amcontract::monitor,CBN_SELCHANGE),reinterpret_cast<LPARAM>(monitor));
  assert(std::string(AMBarPoll())=="monitor:-18.5");
  state["target"]=-14;state["monitor"]=-6;assert(AMBarSetState(state.dump().c_str()));
  state["search"]={{"open",true},{"revision",1},{"input","金属"},{"query","( metal OR metallic )"},{"mode","natural"},{"broad",false},{"can_restore",true},{"groups",Json::array({{{"label","金属"},{"query","metal"},{"enabled",true}}})}};
  // A late payload from the withdrawn feature must not recreate its UI.
  assert(AMBarSetState(state.dump().c_str()) && !panelWindow() && std::string(AMBarPoll()).empty());
  state.erase("search");assert(AMBarSetState(state.dump().c_str()));
  AMBarKeyboardRegister(registerApi,true);
  struct Accelerator {int(*translate)(MSG*,Accelerator*);bool local;void* user;};
  auto accel=static_cast<Accelerator*>(apis.at("accelerator"));
  auto info=reinterpret_cast<int(*)(HWND,INT_PTR)>(apis.at("hwnd_info"));
  MSG key{};key.hwnd=list;key.message=WM_KEYDOWN;key.wParam='R';
  assert(accel->local && accel->translate(&key,accel)==0 && info(list,0)==0);
  SendMessageW(GetDlgItem(bar,100+amcontract::channels),BM_CLICK,0,0);assert(std::string(AMBarPoll())=="channels");
  state["channels"]={{"open",true},{"source","/six.wav:6"},{"file","six.wav"},{"summary","Ch 1, 3, 5"},
    {"items",Json::array({{{"channel",1},{"name","Boom & L"},{"selected",true}},{{"channel",2},{"name",""},{"selected",false}},{{"channel",3},{"name","風鈴 🎤"},{"selected",true}}})},
    {"previous",false},{"next",false},{"all",false},{"downmix",false},{"can_downmix",true},{"can_swap",false},{"enabled",true},{"playing",false},{"page","1–6 / 6"},{"notice",""}};
  assert(AMBarSetState(state.dump().c_str()));
  HWND microphones=FindWindowW(L"SoundPrepMicrophones",nullptr);assert(microphones && GetWindow(microphones,GW_OWNER)==root);
  assert(amwin::text(GetDlgItem(microphones,2100))==L"Boom && L\nch 1" && amwin::text(GetDlgItem(microphones,2101))==L"2");
  assert(!IsWindowVisible(GetDlgItem(microphones,2103)) && !IsWindowEnabled(GetDlgItem(microphones,2204)));
  SendMessageW(GetDlgItem(microphones,2102),BM_CLICK,0,0);auto channelEvent=std::string(AMBarPoll());
  assert(channelEvent.rfind("channels@",0)==0 && Json::parse(channelEvent.substr(9))["channel"]==3);
  SendMessageW(microphones,WM_CLOSE,0,0);assert(std::string(AMBarPoll())=="channels:close");
  state["channels"]["open"]=false;assert(AMBarSetState(state.dump().c_str()));
  std::ifstream settingsFile("tests/native-settings-state.json");state["settings"]=Json::parse(settingsFile);
  assert(AMBarSetState(state.dump().c_str()));HWND settings=FindWindowW(L"SoundPrepAppSettings",nullptr);assert(settings && GetWindow(settings,GW_OWNER)==root);
  SendMessageW(settings,WM_ACTIVATE,WA_INACTIVE,0);assert(IsWindowVisible(settings));
  HWND monitorEdit=GetDlgItem(settings,3202);assert(amwin::text(monitorEdit)==L"-6.0");
  key.hwnd=monitorEdit;key.wParam='1';assert(accel->translate(&key,accel)==-1 && info(monitorEdit,0)==1 && info(monitorEdit,1)==0);
  SendMessageW(GetDlgItem(settings,3101),BM_CLICK,0,0);auto settingsEvent=std::string(AMBarPoll());
  assert(Json::parse(settingsEvent.substr(9))["key"]=="loop");
  SetFocus(monitorEdit);SetWindowTextW(monitorEdit,L"-18.5");state["settings"]["values"]["monitor_gain_db"]=-12;
  assert(AMBarSetState(state.dump().c_str()) && amwin::text(monitorEdit)==L"-18.5");
  SendMessageW(monitorEdit,WM_KEYDOWN,VK_RETURN,0);assert(Json::parse(std::string(AMBarPoll()).substr(9))["value"]==-18.5);
  SetWindowTextW(monitorEdit,L"-18bad");SendMessageW(monitorEdit,WM_KEYDOWN,VK_RETURN,0);
  assert(std::string(AMBarPoll()).empty() && amwin::text(monitorEdit)==L"-12.0");
  SetWindowTextW(monitorEdit,L"   ");SendMessageW(monitorEdit,WM_KEYDOWN,VK_RETURN,0);
  assert(std::string(AMBarPoll()).empty() && amwin::text(monitorEdit)==L"-12.0");
  state["paused"]=true;assert(AMBarSetState(state.dump().c_str()));assert(IsWindowVisible(settings) && !IsWindowEnabled(GetDlgItem(settings,3101)));
  SendMessageW(settings,WM_CLOSE,0,0);assert(!IsWindow(settings) && std::string(AMBarPoll())=="settings:close");
  assert(AMBarSetState(state.dump().c_str()) && !FindWindowW(L"SoundPrepAppSettings",nullptr));
  state["settings"]["open"]=false;state["paused"]=false;assert(AMBarSetState(state.dump().c_str()));
  state["settings"]["open"]=true;state["settings"]["focus"]=2;assert(AMBarSetState(state.dump().c_str()));
  settings=FindWindowW(L"SoundPrepAppSettings",nullptr);assert(settings);
  std::ifstream editorFile("tests/native-editor-state.json");state["editor"]=Json::parse(editorFile);
  state["editor"]["presets"][2]["label"]="Heavy"; // Duplicate names retain distinct IDs.
  assert(AMBarSetState(state.dump().c_str()));HWND editor=FindWindowW(L"SoundPrepPresetEditor",nullptr);assert(editor && GetWindow(editor,GW_OWNER)==root);
  assert(!GetDlgItem(editor,4000) && IsWindowVisible(GetDlgItem(editor,4400)) && !IsWindowVisible(GetDlgItem(editor,4404)));
  assert(SendMessageW(GetDlgItem(editor,4401),BM_GETCHECK,0,0)==BST_CHECKED && SendMessageW(GetDlgItem(editor,4402),BM_GETCHECK,0,0)==BST_UNCHECKED);
  assert(amwin::rect(GetDlgItem(editor,4400),editor).top==amwin::rect(GetDlgItem(editor,4403),editor).top);
  SendMessageW(GetDlgItem(editor,4402),BM_CLICK,0,0);assert(Json::parse(std::string(AMBarPoll()).substr(7))["value"]=="dark");
  SendMessageW(editor,WM_ACTIVATE,WA_INACTIVE,0);assert(IsWindowVisible(editor));
  HWND rateEdit=GetDlgItem(editor,4203);assert(amwin::text(rateEdit)==L"0.72");
  key.hwnd=rateEdit;assert(accel->translate(&key,accel)==-1 && info(rateEdit,0)==1);
  SetFocus(rateEdit);SetWindowTextW(rateEdit,L"0.63");state["editor"]["values"]["rate"]=1.2;
  assert(AMBarSetState(state.dump().c_str()) && amwin::text(rateEdit)==L"0.63");
  SendMessageW(rateEdit,WM_KEYDOWN,VK_RETURN,0);auto editEvent=Json::parse(std::string(AMBarPoll()).substr(7));
  assert(editEvent["id"]=="heavy" && editEvent["key"]=="rate" && editEvent["value"]==.63);
  SetWindowTextW(rateEdit,L"bad");SendMessageW(rateEdit,WM_KEYDOWN,VK_RETURN,0);assert(std::string(AMBarPoll()).empty());
  SetWindowTextW(rateEdit,L"0.81");SendMessageW(GetDlgItem(editor,4400),BM_CLICK,0,0);
  editEvent=Json::parse(std::string(AMBarPoll()).substr(7));assert(editEvent["id"]=="heavy" && editEvent["key"]=="rate" && editEvent["value"]==.81);
  assert(Json::parse(std::string(AMBarPoll()).substr(7))["value"]=="raw");
  state["editor"]["id"]="raw";state["editor"]["values"]["metric"]="zwicker_p95";
  assert(AMBarSetState(state.dump().c_str()));assert(!IsWindowEnabled(GetDlgItem(editor,4100)) && !IsWindowEnabled(GetDlgItem(editor,4003)));
  assert(SendMessageW(GetDlgItem(editor,4400),BM_GETCHECK,0,0)==BST_CHECKED && SendMessageW(GetDlgItem(editor,4401),BM_GETCHECK,0,0)==BST_UNCHECKED);
  assert(!IsWindowEnabled(GetDlgItem(editor,4208)) && IsWindowEnabled(GetDlgItem(editor,4209)));
  state["paused"]=true;assert(AMBarSetState(state.dump().c_str()));assert(IsWindowVisible(editor) && !IsWindowEnabled(GetDlgItem(editor,4106)));
  for(int i=0;i<4;++i)assert(!IsWindowEnabled(GetDlgItem(editor,4400+i)));
  SendMessageW(editor,WM_CLOSE,0,0);assert(!IsWindow(editor) && std::string(AMBarPoll())=="editor:close");
  assert(AMBarSetState(state.dump().c_str()) && !FindWindowW(L"SoundPrepPresetEditor",nullptr));
  state["paused"]=false;state["editor"]["focus"]=2;assert(AMBarSetState(state.dump().c_str()));editor=FindWindowW(L"SoundPrepPresetEditor",nullptr);assert(editor);
  assert(amwin::text(GetDlgItem(editor,4401))==L"Heavy"); // Recreated windows refill unchanged choices.
  auto originalPresets=state["editor"]["presets"];
  while(state["editor"]["presets"].size()<10){auto i=state["editor"]["presets"].size();state["editor"]["presets"].push_back({{"id","preset"+std::to_string(i)},{"label","長いプリセット名 — Microphone 🎤 ambience"}});}
  assert(AMBarSetState(state.dump().c_str()));
  assert(amwin::rect(GetDlgItem(editor,4409),editor).top>amwin::rect(GetDlgItem(editor,4400),editor).top);
  for(int i=0;i<10;++i){HWND b=GetDlgItem(editor,4400+i);RECT r=amwin::rect(b,editor);assert(IsWindowVisible(b) && r.left>=0 && r.right<=amwin::scale(editor,680) && r.bottom<amwin::rect(GetDlgItem(editor,4001),editor).top);}
  SendMessageW(GetDlgItem(editor,4409),BM_CLICK,0,0);assert(Json::parse(std::string(AMBarPoll()).substr(7))["value"]=="preset9");
  RECT editorRect{};GetWindowRect(editor,&editorRect);SetWindowPos(editor,nullptr,0,0,editorRect.right-editorRect.left,amwin::scale(editor,500),SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);
  SendMessageW(editor,WM_VSCROLL,SB_BOTTOM,0);RECT editorClient{};GetClientRect(editor,&editorClient);RECT doneRect=amwin::rect(GetDlgItem(editor,4009),editor);
  assert(doneRect.top>=0 && doneRect.bottom<=editorClient.bottom);
  SetWindowPos(editor,nullptr,0,0,editorRect.right-editorRect.left,editorRect.bottom-editorRect.top,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);SendMessageW(editor,WM_VSCROLL,SB_TOP,0);
  state["editor"]["presets"]=Json::array({originalPresets[0],originalPresets[3],originalPresets[1]});assert(AMBarSetState(state.dump().c_str()));
  assert(!IsWindowVisible(GetDlgItem(editor,4403)) && SendMessageW(GetDlgItem(editor,4400),BM_GETCHECK,0,0)==BST_CHECKED);
  SendMessageW(GetDlgItem(editor,4401),BM_CLICK,0,0);assert(Json::parse(std::string(AMBarPoll()).substr(7))["value"]=="reverse");
  auto openSettings=state["settings"],openEditor=state["editor"];
  state.erase("channels");state.erase("settings");state.erase("editor");
  assert(AMBarSetState(state.dump().c_str()) && !IsWindow(settings) && !IsWindow(editor));
  assert(!FindWindowW(L"SoundPrepMicrophones",nullptr) && std::string(AMBarPoll()).empty());
  state["settings"]=openSettings;state["editor"]=openEditor;assert(AMBarSetState(state.dump().c_str()));
  settings=FindWindowW(L"SoundPrepAppSettings",nullptr);editor=FindWindowW(L"SoundPrepPresetEditor",nullptr);
  assert(settings && editor && amwin::text(GetDlgItem(editor,4401))==L"Reverse");
  HWND downmix=GetDlgItem(bar,100+amcontract::downmix);assert(downmix && !IsWindowVisible(downmix));
  assert(SendMessageW(downmix,BM_GETCHECK,0,0)==BST_UNCHECKED);
  assert(Json::parse(AMBarGeometry())["downmix_visible"]==false && Json::parse(AMBarGeometry())["downmix"]==false);
  // At 700 logical pixels the Downmix control wraps to a second row.
  // At 800 pixels the reduced toolbar fits on one row on both platforms.
  SetWindowPos(list,nullptr,original.left,original.top,amwin::scale(root,700),amwin::scale(root,400),SWP_NOZORDER|SWP_NOACTIVATE);
  assert(Json::parse(AMBarGeometry())["height"]==amwin::scale(root,72));
  state["multichannel"]=true;assert(AMBarSetState(state.dump().c_str()));
  assert(IsWindowVisible(downmix) && amwin::text(downmix)==L"Downmix");
  assert(Json::parse(AMBarGeometry())["height"]==amwin::scale(root,98));
  SendMessageW(downmix,BM_CLICK,0,0);assert(std::string(AMBarPoll())=="downmix");
  state["downmix"]=true;assert(AMBarSetState(state.dump().c_str()));
  assert(SendMessageW(downmix,BM_GETCHECK,0,0)==BST_CHECKED);
  assert(Json::parse(AMBarGeometry())["downmix_visible"]==true && Json::parse(AMBarGeometry())["downmix"]==true);
  SendMessageW(downmix,BM_CLICK,0,0);assert(std::string(AMBarPoll())=="downmix");
  state["downmix"]=false;assert(AMBarSetState(state.dump().c_str()));
  assert(SendMessageW(downmix,BM_GETCHECK,0,0)==BST_UNCHECKED);
  SetWindowPos(list,nullptr,original.left,original.top,amwin::scale(root,300),amwin::scale(root,129),SWP_NOZORDER|SWP_NOACTIVATE);
  assert(amwin::text(downmix)==L"DM" && Json::parse(AMBarGeometry())["height"]==amwin::scale(root,80));
  state["multichannel"]=false;assert(AMBarSetState(state.dump().c_str()));
  assert(!IsWindowVisible(downmix) && Json::parse(AMBarGeometry())["height"]==amwin::scale(root,80));
  state["multichannel"]=true;assert(AMBarSetState(state.dump().c_str()));
  SetWindowPos(list,nullptr,original.left,original.top,original.right-original.left,original.bottom-original.top,SWP_NOZORDER|SWP_NOACTIVATE);
  state["macros"]=Json::array();
  for(int i=1;i<=9;++i)state["macros"].push_back({{"id","preset"+std::to_string(i)},{"label",std::to_string(i)+"  Long preset name 日本語"}});
  state["active"]="preset4";assert(AMBarSetState(state.dump().c_str()));
  assert(SendMessageW(GetDlgItem(bar,203),BM_GETCHECK,0,0)==BST_CHECKED);
  SendMessageW(GetDlgItem(bar,208),BM_CLICK,0,0);assert(std::string(AMBarPoll())=="macro:preset9");
  state["paused"]=true;assert(AMBarSetState(state.dump().c_str()));
  for(int i=200;i<209;++i)assert(!IsWindowEnabled(GetDlgItem(bar,i)));
  assert(!IsWindowEnabled(GetDlgItem(bar,100+amcontract::normalize)) && !IsWindowEnabled(downmix));
  SendMessageW(bar,WM_COMMAND,MAKEWPARAM(100+amcontract::downmix,BN_CLICKED),0);assert(std::string(AMBarPoll()).empty());
  SendMessageW(bar,WM_COMMAND,MAKEWPARAM(200,BN_CLICKED),0);assert(std::string(AMBarPoll()).empty());
  state["paused"]=false;assert(AMBarSetState(state.dump().c_str()));
  // Exercise both sides of every compact/two-row breakpoint using real HWNDs.
  // Visible controls must fit; narrow docks must keep Edit/Quit reachable.
  for(bool multichannel:{false,true}) {
    state["multichannel"]=multichannel;assert(AMBarSetState(state.dump().c_str()));
    for(int width:{299,300,320,359,360,415,416,736,737,879,880,1000})for(int height:{53,54,87,88,113,114,180}) {
      SetWindowPos(list,nullptr,original.left,original.top,amwin::scale(root,width),amwin::scale(root,height),SWP_NOZORDER|SWP_NOACTIVATE);
      auto g=Json::parse(AMBarGeometry());
      assert(g["list_height"].get<int>()>0 && g["height"].get<int>()>=0);
      if(g["hidden"].get<bool>())continue;
      RECT client{};GetClientRect(bar,&client);
      for(int id=100;id<100+amcontract::control_count;++id) {
        HWND control=GetDlgItem(bar,id);if(!IsWindowVisible(control))continue;
        RECT r=amwin::rect(control,bar);
        assert(r.left>=0 && r.top>=0 && r.right<=client.right && r.bottom<=client.bottom);
      }
      assert(IsWindowVisible(GetDlgItem(bar,100+amcontract::edit)) && IsWindowVisible(GetDlgItem(bar,100+amcontract::quit)));
      assert(static_cast<bool>(IsWindowVisible(downmix))==(multichannel && height>=amcontract::minimal_height));
      int right=0;
      for(int id=200;id<209;++id){HWND button=GetDlgItem(bar,id);assert(IsWindowVisible(button));auto r=amwin::rect(button,bar);
        assert(r.left>=right && r.right<=client.right && r.top>=0 && r.bottom<=client.bottom);right=r.right;
      }
    }
  }
  state.erase("downmix");state.erase("multichannel");assert(AMBarSetState(state.dump().c_str()));
  assert(!IsWindowVisible(downmix) && SendMessageW(downmix,BM_GETCHECK,0,0)==BST_UNCHECKED);
  SetWindowPos(list,nullptr,original.left,original.top,original.right-original.left,original.bottom-original.top,SWP_NOZORDER|SWP_NOACTIVATE);
  AMBarDetach();assert(!IsWindow(settings) && !IsWindow(editor));RECT restored=amwin::rect(list,root);assert(EqualRect(&original,&restored));assert(std::string(AMBarGeometry())=="{}");
  HWND arrange=create(L"AMTestArrange",500,550,600,180,root,1000),tcp=create(L"REAPERTCPDisplay",10,550,450,180,root),wave=create(L"AMTestWave",10,750,1000,80,root,1046);assert(tcp);
  HWND canvas=create(L"AMTestCanvas",0,0,500,150,arrange);assert(canvas);
  SetWindowSubclass(list,listNative,1,reinterpret_cast<DWORD_PTR>(arrange));
  assert(AMDropAttachSources(root,arrange,wave,list,&root,9000,get));
  gesture={};SendMessageW(arrange,WM_DROPFILES,reinterpret_cast<WPARAM>(payload()),0);assert(nativeDrops==1 && processed==0);items.clear();
  for(int source:{1,2})for(HWND target:{arrange,tcp}){
    gesture={};gesture.origin=source;gesture.source=source==1?wave:list;gesture.depth=1;gesture.dragging=true;gesture.paths={"c:/素材/slam.wav"};
    SendMessageW(target,WM_DROPFILES,reinterpret_cast<WPARAM>(payload()),0);assert(items.size()==1 && undoLabel=="Insert SoundPrep");items.clear();
  }
  assert(processed==4 && nativeDrops==5);
  // Child canvas and screen-coordinate delivery were absent from the old fixture.
  for(HWND target:{canvas,root}){
    gesture={};gesture.origin=1;gesture.source=wave;gesture.depth=1;gesture.dragging=true;gesture.paths={"C:\\素材\\slam.wav"};
    auto h=payload();if(target==root){auto* d=static_cast<DROPFILES*>(GlobalLock(h));d->pt={20,20};ClientToScreen(arrange,&d->pt);d->fNC=TRUE;GlobalUnlock(h);}
    SendMessageW(target,WM_DROPFILES,reinterpret_cast<WPARAM>(h),0);assert(items.size()==1 && undoLabel=="Insert SoundPrep");items.clear();
  }
  assert(processed==6);
  // Real subclass chain, no WM_DROPFILES and no manufactured Gesture state.
  // The receiver clears its live selection during insertion; the frozen range survives.
  POINT saved{},point{30,30};GetCursorPos(&saved);ClientToScreen(arrange,&point);SetCursorPos(point.x,point.y);
  modalInsert=true;dialogMovesPointer=true;selectionStart=.2;selectionEnd=.7;
  SendMessageW(wave,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));
  assert(items.size()==1 && processed==7 && undoLabel=="Insert SoundPrep" && !busy);items.clear();
  reject=true;selectionStart=.2;selectionEnd=.7;SetCursorPos(point.x,point.y);
  SendMessageW(wave,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));assert(items.empty() && processed==7 && !busy);
  const auto beforeClick=captures,blocksBeforeClick=undoBlocks;
  modalInsert=false;dialogMovesPointer=false;reject=false;SendMessageW(wave,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));assert(items.empty() && processed==7 && !busy && captures==beforeClick);
  assert(undoBlocks==blocksBeforeClick && nativeDrag==nullptr);
  // A newly clicked row must replace the old selection in the captured paths.
  LVCOLUMNW column{};column.mask=LVCF_WIDTH;column.cx=600;ListView_InsertColumn(list,0,&column);
  HWND pathField=CreateWindowExW(0,L"EDIT",L"C:\\素材",WS_CHILD,0,0,100,20,root,reinterpret_cast<HMENU>(1002),amwin::module(),nullptr);assert(pathField);
  for(auto text:{L"C:\\素材\\old.wav",L"slam.wav"}){
    LVITEMW row{};row.mask=LVIF_TEXT;row.iItem=ListView_GetItemCount(list);row.pszText=const_cast<wchar_t*>(text);ListView_InsertItem(list,&row);
  }
  ListView_SetItemState(list,0,LVIS_SELECTED,LVIS_SELECTED);modalList=true;selectionStart=.2;selectionEnd=.7;
  SendMessageW(list,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));
  assert(items.size()==1 && processed==8 && undoLabel=="Insert SoundPrep" && !busy);
  assert(gesture.paths.size()==1 && samePath(gesture.paths[0],"C:\\素材\\slam.wav"));items.clear();modalList=false;
  // REAPER 7.81 posts WM_DROPFILES after its button-down loop returns.
  modalList=true;postListDrop=true;ListView_SetItemState(list,-1,0,LVIS_SELECTED);
  SendMessageW(list,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(10,10));assert(items.empty());
  MSG delivery{};assert(PeekMessageW(&delivery,arrange,WM_DROPFILES,WM_DROPFILES,PM_REMOVE));DispatchMessageW(&delivery);
  assert(items.size()==1 && processed==9 && undoLabel=="Insert SoundPrep");items.clear();modalList=false;
  // Absolute search rows and relative folder rows may occur in the same batch.
  ListView_SetItemState(list,0,LVIS_SELECTED,LVIS_SELECTED);SetWindowTextW(pathField,L"C:\\素材\\");
  auto selected=selectedPaths(2);assert(selected.size()==2 && samePath(selected[0],"C:\\素材\\old.wav") && samePath(selected[1],"C:\\素材\\slam.wav"));
  SetWindowTextW(pathField,L"Unresolved database");assert(selectedPaths(2).empty());
  canonicalRows={L"C:\\素材\\a\\same.wav",L"C:\\素材\\b\\same.wav"};
  SendMessageW(root,WM_COMMAND,42026,0);SendMessageW(root,WM_COMMAND,42091,0);
  auto displayBefore=displayOptions;selected=selectedPaths(2);
  assert(selected.size()==2 && samePath(selected[0],"C:\\素材\\a\\same.wav") && samePath(selected[1],"C:\\素材\\b\\same.wav"));
  assert(displayOptions==displayBefore);
  SendMessageW(root,WM_COMMAND,42134,0);displayBefore=displayOptions;
  assert(selectedPaths(2).size()==2 && displayOptions==displayBefore);
  canonicalRows[1]=L"unresolved.wav";
  assert(selectedPaths(2).empty() && displayOptions==displayBefore);
  SetCursorPos(saved.x,saved.y);
  reject=true;int before=nativeDrops;gesture={};gesture.origin=1;gesture.source=wave;gesture.depth=1;gesture.dragging=true;gesture.paths={"C:\\素材\\slam.wav"};SendMessageW(arrange,WM_DROPFILES,reinterpret_cast<WPARAM>(payload()),0);assert(items.empty() && nativeDrops==before);
  AMDropDetach();AMWinSearchDetach();AMBarKeyboardRegister(registerApi,false);
  assert(apis.count("-accelerator") && apis.count("-hwnd_info"));DestroyWindow(root);
  std::cout<<"PASS: Win32 Unicode search/IME/CAS, atomic replacement, embedded layout/restore, search draft/edit/error, drop provenance/transaction/rollback guard\n";
}
