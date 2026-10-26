// Windows' native file-drop delivery, scoped to a gesture in the attached ME.
// REAPER performs placement; Lua reuses the existing Source+FX / Rendered transaction.
#include "common.h"
#include <shellapi.h>
#include <unordered_set>
#include <array>
extern "C" void AMDropDetach();
namespace {
constexpr UINT_PTR targetId=0x414d4454,sourceId=0x414d4453;
std::array<HWND,3> targets{};HWND wave=nullptr,files=nullptr;
void* project=nullptr;int command=0;bool busy=false,pendingDetach=false,result=false;
unsigned long long serial=0;std::string context;
void*(*enumProjects)(int,char*,int);void(*action)(int,int,void*);
int(*countItems)(void*);void*(*getItem)(void*,int);bool(*itemString)(void*,const char*,char*,bool);
void(*beginUndo)(void*);void(*endUndo)(void*,const char*,int);const char*(*canUndo)(void*);int(*undo)(void*);int(*stateCount)(void*);
bool(*fileInfo)(char*,int,int*,double*,double*,double*,double*,double*,double*,char*,int);
int(*toggleState)(int,int);
struct Gesture {HWND source=nullptr;int origin=0,x=0,y=0,depth=0;bool armed=false,dragging=false,released=false,targeted=false,listCaptured=false;DWORD begin=0,end=0;std::vector<std::string> paths;amwin::Json preview;};
Gesture gesture;
struct NativeDrag {bool armed=false;int state=0;std::unordered_set<void*> before;};
NativeDrag* nativeDrag=nullptr;
std::vector<HWND> targetChildren;
amwin::Json diagnostics={{"revision",3},{"events",amwin::Json::array()}};
void trace(const char* event,HWND w=nullptr){
  auto value=amwin::Json{{"event",event},{"origin",gesture.origin},{"preview",gesture.preview}};
  if(w){wchar_t cls[128]{};GetClassNameW(w,cls,128);value["window_class"]=amwin::utf8(cls);value["window_id"]=GetDlgCtrlID(w);}
  auto& events=diagnostics["events"];if(events.size()>=16)events.erase(events.begin());events.push_back(value);
}
void capturePreview(){
  char path[32768]{},extra[128]{};int mode=0;double a=0,b=1,p=0,g=0,r=1,bpm=0;
  gesture.preview=nullptr;
  if(fileInfo(path,sizeof(path),&mode,&a,&b,&p,&g,&r,&bpm,extra,sizeof(extra)))
    gesture.preview={{"path",path},{"mode",mode},{"start",a},{"end",b},{"pitch",p},{"rate",r}};
}
bool inTarget(POINT point){for(size_t i=1;i<targets.size();++i){RECT rect{};if(IsWindowVisible(targets[i]) && GetWindowRect(targets[i],&rect) && PtInRect(&rect,point))return true;}return false;}
void armNative(POINT point){
  if(!nativeDrag || nativeDrag->armed || !inTarget(point) || enumProjects(-1,nullptr,0)!=project)return;
  for(int i=0;i<countItems(project);++i)nativeDrag->before.insert(getItem(project,i));
  nativeDrag->state=stateCount(project);beginUndo(project);nativeDrag->armed=true;
}
void releasedAt(POINT point){if(!gesture.released){gesture.released=true;gesture.targeted=inTarget(point);}}
void captureListDrag(POINT point);
LRESULT CALLBACK dragMessage(int code,WPARAM p,LPARAM l){
  if(code>=0 && p==PM_REMOVE){auto* message=reinterpret_cast<MSG*>(l);
    if(message->message==WM_MOUSEMOVE || message->message==WM_LBUTTONUP){captureListDrag(message->pt);armNative(message->pt);}
    if(message->message==WM_LBUTTONUP)releasedAt(message->pt);
  }
  return CallNextHookEx(nullptr,code,p,l);
}
void setContext(const char*,const std::vector<std::string>&,int,const amwin::Json& =amwin::Json::array());
void finish();
unsigned long long gestureGeneration=0;
std::wstring canonical(const std::string& path){auto p=amwin::wide(path);std::replace(p.begin(),p.end(),L'/',L'\\');return p;}
bool samePath(const std::string& a,const std::string& b){auto x=canonical(a),y=canonical(b);return CompareStringOrdinal(x.c_str(),static_cast<int>(x.size()),y.c_str(),static_cast<int>(y.size()),TRUE)==CSTR_EQUAL;}
bool absolutePath(const std::wstring& path){return !path.empty() && (path[0]==L'\\' || path[0]==L'/' || (path.size()>2 && path[1]==L':' && (path[2]==L'\\' || path[2]==L'/')));}
struct ListPathDisplay {
  HWND explorer;std::array<int,3> ids{42091,42026,42134},saved{};
  void set(int id,int value){if(value>=0 && toggleState(32063,id)!=value)SendMessageW(explorer,WM_COMMAND,id,0);}
  explicit ListPathDisplay(HWND w):explorer(w){
    for(size_t i=0;i<ids.size();++i)saved[i]=toggleState(32063,ids[i]);
    set(42026,1);set(42091,1);
  }
  ~ListPathDisplay(){for(size_t i=0;i<ids.size();++i)set(ids[i],saved[i]);}
};
std::vector<std::string> selectedPaths(int origin){
  if(origin==1){char path[32768]{},extra[128]{};int mode=0;double a=0,b=1,p=0,g=0,r=1,bpm=0;if(fileInfo(path,sizeof(path),&mode,&a,&b,&p,&g,&r,&bpm,extra,sizeof(extra)))return {path};return {};}
  // Lua no longer forces display options for the entire session. A modal list
  // drag must resolve every selected row itself, restoring even on early return.
  ListPathDisplay display(GetParent(files));
  // Ordinary folders display basenames even with "full paths" enabled; database
  // and recursive-search rows may already be absolute. Resolve at drag start,
  // never against the process working directory or a later browser selection.
  const auto directory=amwin::text(GetDlgItem(GetParent(files),1002));
  std::vector<std::string> paths;int index=-1;
  while((index=static_cast<int>(SendMessageW(files,LVM_GETNEXTITEM,index,LVNI_SELECTED)))>=0){
    std::wstring text(32768,L'\0');LVITEMW item{};item.iSubItem=0;item.pszText=text.data();item.cchTextMax=static_cast<int>(text.size());
    int count=static_cast<int>(SendMessageW(files,LVM_GETITEMTEXTW,index,reinterpret_cast<LPARAM>(&item)));text.resize(count);
    if(text.empty())return {};
    if(!absolutePath(text)){if(!absolutePath(directory))return {};text=directory+(directory.back()==L'/' || directory.back()==L'\\'?L"":L"/")+text;}
    paths.push_back(amwin::utf8(text));if(paths.size()>4096)return {};
  }return paths;
}
void captureListDrag(POINT point){
  if(gesture.origin!=2 || gesture.listCaptured || !gesture.source)return;
  POINT start{gesture.x,gesture.y};ClientToScreen(gesture.source,&start);
  if(std::abs(point.x-start.x)<=3 && std::abs(point.y-start.y)<=3)return;
  // ListView selects the row inside its button-down handler, then runs a modal
  // drag loop. Capture AFTER selection, before the drop, including multi-select.
  gesture.listCaptured=true;
  try{capturePreview();gesture.paths=selectedPaths(2);}catch(...){gesture.paths.clear();}
  if(!gesture.paths.empty())setContext("gesture",gesture.paths,2);
}
LRESULT CALLBACK sourceProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR origin){
  if(m==WM_LBUTTONDOWN){++gestureGeneration;gesture={};gesture.source=w;gesture.origin=static_cast<int>(origin);gesture.armed=true;gesture.begin=GetTickCount();gesture.x=static_cast<short>(LOWORD(l));gesture.y=static_cast<short>(HIWORD(l));}
  const auto generation=gestureGeneration;
  bool scope=w==gesture.source && gesture.armed && (m==WM_MOUSEMOVE || m==WM_LBUTTONUP || m==WM_LBUTTONDOWN);
  bool nativeGesture=false,captured=false;NativeDrag transaction;HHOOK dragHook=nullptr;
  if(busy && m==WM_LBUTTONUP){POINT point{};GetCursorPos(&point);armNative(point);releasedAt(point);}
  if(scope){
    const bool moved=m==WM_MOUSEMOVE && (p&MK_LBUTTON) && (std::abs(static_cast<short>(LOWORD(l))-gesture.x)>3 || std::abs(static_cast<short>(HIWORD(l))-gesture.y)>3);
    if(moved && origin==2){POINT point{static_cast<short>(LOWORD(l)),static_cast<short>(HIWORD(l))};ClientToScreen(w,&point);captureListDrag(point);}
    // Both waveform and ListView can enter a modal drag during button-down;
    // those nested mouse moves never pass through this subclass first.
    if(!gesture.dragging && (moved || m==WM_LBUTTONDOWN)){
      gesture.dragging=true;try{capturePreview();gesture.paths=selectedPaths(gesture.origin);}catch(...){gesture.paths.clear();}
      // Windows can insert directly from its modal source drag loop, without
      // sending WM_DROPFILES to Arrange. Wrap that native gesture as well.
      if(!busy && command && (origin==2 || !gesture.paths.empty()) && enumProjects(-1,nullptr,0)==project){
        nativeGesture=true;busy=true;result=false;++serial;trace("gesture begin",w);
        nativeDrag=&transaction;
        // Keep the companion state fixed during the modal native call, but do
        // no Lua/FX/file work for an ordinary waveform click or range edit.
        if(!gesture.paths.empty())setContext("gesture",gesture.paths,gesture.origin);
        POINT point{};GetCursorPos(&point);armNative(point);
        dragHook=SetWindowsHookExW(WH_GETMESSAGE,dragMessage,nullptr,GetCurrentThreadId());
      }
    }
    ++gesture.depth;
  }
  LRESULT value=DefSubclassProc(w,m,p,l);
  if(dragHook)UnhookWindowsHookEx(dragHook);
  if(nativeGesture){
    nativeDrag=nullptr;
    auto items=amwin::Json::array();
    if(transaction.armed)for(int i=0;i<countItems(project);++i){void* item=getItem(project,i);if(!transaction.before.count(item)){char id[128]{};if(itemString(item,"GUID",id,false))items.push_back(id);}}
    POINT point{};GetCursorPos(&point);
    const bool target=gesture.released?gesture.targeted:inTarget(point);
    bool candidate=!items.empty() && target && enumProjects(-1,nullptr,0)==project;
    result=false;
    if(candidate && items.size()==gesture.paths.size()){
      setContext("capture",gesture.paths,gesture.origin);action(command,0,project);captured=result;
      if(captured){
        result=false;setContext("prepare_captured",gesture.paths,gesture.origin,items);action(command,0,project);
        if(result){result=false;setContext("finish",gesture.paths,gesture.origin,items);action(command,0,project);}
      }
    }
    diagnostics["last_gesture"]={{"new_items",items.size()},{"inside_target",target},{"captured",captured},{"same_project",enumProjects(-1,nullptr,0)==project}};
    const bool processed=result;
    const std::string label=candidate ? (processed?"Insert SoundPrep":"Cancelled SoundPrep drop "+std::to_string(serial)) : "Media Explorer drag";
    if(transaction.armed)endUndo(project,label.c_str(),-1);
    if(candidate && !processed && stateCount(project)!=transaction.state){const char* top=canUndo(project);if(top && label==top)undo(project);}
    trace(processed?"gesture processed":(candidate?"gesture rejected":"gesture no insertion"),w);
    if(candidate){setContext(!processed?"cancel":"discard",gesture.paths,gesture.origin,items);action(command,0,project);}
    if(candidate)gesture.dragging=false;
    finish();
  }
  if(scope && generation==gestureGeneration){--gesture.depth;if(gesture.depth==0 && (m==WM_LBUTTONUP || !(GetAsyncKeyState(VK_LBUTTON)&0x8000))){gesture.end=GetTickCount();gesture.armed=false;}}
  if(!busy && gesture.depth==0 && (m==WM_CANCELMODE || (m==WM_CAPTURECHANGED && !gesture.dragging)) && w==gesture.source){++gestureGeneration;gesture={};}
  if(m==WM_NCDESTROY){RemoveWindowSubclass(w,sourceProc,sourceId);if(w==gesture.source){if(busy)pendingDetach=true;else{++gestureGeneration;gesture={};}}}
  return value;
}
void setContext(const char* phase,const std::vector<std::string>& paths,int origin,const amwin::Json& items){
  context=amwin::Json{{"phase",phase},{"path",paths.empty()?"":paths.front()},{"paths",paths},{"origin",origin==1?"waveform":"list"},{"id",serial},{"items",items},{"preview",gesture.preview}}.dump();
}
void finish(){context.clear();busy=false;if(pendingDetach){pendingDetach=false;AMDropDetach();}}
bool provenance(const std::vector<std::string>& paths){
  if(!gesture.dragging || gesture.paths.size()!=paths.size() || paths.empty())return false;
  if(gesture.depth==0){DWORD posted=static_cast<DWORD>(GetMessageTime());if(!gesture.end || GetTickCount()-gesture.end>2000 || posted-gesture.begin>gesture.end-gesture.begin)return false;}
  auto remaining=gesture.paths;
  for(const auto& path:paths){auto match=std::find_if(remaining.begin(),remaining.end(),[&](const auto& expected){return samePath(path,expected);});if(match==remaining.end())return false;remaining.erase(match);}
  return true;
}
LRESULT CALLBACK targetProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR){
  if(m==WM_NCDESTROY){RemoveWindowSubclass(w,targetProc,targetId);return DefSubclassProc(w,m,p,l);}
  if(m==WM_DROPFILES && busy && nativeDrag){
    POINT point{};if(DragQueryPoint(reinterpret_cast<HDROP>(p),&point))ClientToScreen(w,&point);
    captureListDrag(point);armNative(point);releasedAt(point);
  }
  if(m!=WM_DROPFILES || busy || !wave || !command || enumProjects(-1,nullptr,0)!=project)return DefSubclassProc(w,m,p,l);
  HDROP drop=reinterpret_cast<HDROP>(p);std::vector<std::string> paths;
  try{
    POINT point{};if(DragQueryPoint(drop,&point))ClientToScreen(w,&point);
    bool area=inTarget(point);
    if(!area)return DefSubclassProc(w,m,p,l);
    UINT count=DragQueryFileW(drop,0xffffffff,nullptr,0);if(!count || count>4096)return DefSubclassProc(w,m,p,l);
    for(UINT i=0;i<count;++i){UINT size=DragQueryFileW(drop,i,nullptr,0);if(!size || size>32767)return DefSubclassProc(w,m,p,l);std::wstring path(size+1,L'\0');DragQueryFileW(drop,i,path.data(),size+1);path.resize(size);paths.push_back(amwin::utf8(path));}
    if(!provenance(paths)){
      diagnostics["rejected_payload"]={{"expected",gesture.paths},{"received",paths},{"dragging",gesture.dragging},{"depth",gesture.depth},{"begin",gesture.begin},{"end",gesture.end},{"posted",static_cast<DWORD>(GetMessageTime())},{"now",GetTickCount()}};
      trace("drop provenance mismatch",w);return DefSubclassProc(w,m,p,l);
    }
  }catch(...){return DefSubclassProc(w,m,p,l);}
  int origin=gesture.origin;gesture.dragging=false;
  trace("WM_DROPFILES",w);
  if(origin==1 && paths.size()!=1){DragFinish(drop);return 0;}
  busy=true;result=false;++serial;bool forwarded=false,undoOpen=false;int state=stateCount(project);
  std::string label="Cancelled SoundPrep drop "+std::to_string(serial);
  try{
    setContext("prepare",paths,origin);action(command,0,project);
    if(!result || enumProjects(-1,nullptr,0)!=project){DragFinish(drop);finish();return 0;}
    std::unordered_set<void*> before;for(int i=0;i<countItems(project);++i)before.insert(getItem(project,i));
    state=stateCount(project);beginUndo(project);undoOpen=true;
    forwarded=true;DefSubclassProc(w,m,p,l); // Native receiver owns/frees the HDROP.
    auto items=amwin::Json::array();
    for(int i=0;i<countItems(project);++i){void* item=getItem(project,i);if(!before.count(item)){char id[128]{};if(itemString(item,"GUID",id,false))items.push_back(id);}}
    result=false;if(items.size()==paths.size()){setContext("finish",paths,origin,items);action(command,0,project);}
    if(result)label="Insert SoundPrep";
    endUndo(project,label.c_str(),-1);undoOpen=false;
    if(!result && stateCount(project)!=state){const char* top=canUndo(project);if(top && label==top)undo(project);}
    if(!result){setContext("cancel",paths,origin,items);action(command,0,project);}
  }catch(...){
    if(!forwarded)DragFinish(drop);
    if(undoOpen){endUndo(project,label.c_str(),-1);const char* top=canUndo(project);if(stateCount(project)!=state && top && label==top)undo(project);}
  }
  finish();return 0;
}
BOOL CALLBACK findTcp(HWND w,LPARAM data){wchar_t name[128]{};GetClassNameW(w,name,128);if(_wcsicmp(name,L"REAPERTCPDisplay")==0){*reinterpret_cast<HWND*>(data)=w;return FALSE;}return TRUE;}
BOOL CALLBACK hookChild(HWND w,LPARAM){
  if(std::find(targets.begin(),targets.end(),w)==targets.end() && SetWindowSubclass(w,targetProc,targetId,0))targetChildren.push_back(w);
  return TRUE;
}
}
extern "C" void AMDropDetach(){
  if(busy){pendingDetach=true;return;}
  for(HWND w:targets)if(IsWindow(w))RemoveWindowSubclass(w,targetProc,targetId);
  for(HWND w:targetChildren)if(IsWindow(w))RemoveWindowSubclass(w,targetProc,targetId);targetChildren.clear();
  for(HWND w:{wave,files})if(IsWindow(w))RemoveWindowSubclass(w,sourceProc,sourceId);
  targets={};wave=files=nullptr;project=nullptr;command=0;++gestureGeneration;gesture={};context.clear();
}
extern "C" bool AMDropAttachSources(void* main,void* arrange,void* source,void* list,void* proj,int cmd,void*(*get)(const char*)){
  if(busy)return false;HWND m=static_cast<HWND>(main),a=static_cast<HWND>(arrange),w=static_cast<HWND>(source),f=static_cast<HWND>(list),tcp=nullptr;
  if(!IsWindow(m) || !IsWindow(a) || !IsWindow(w) || (list && !IsWindow(f)))return false;
  EnumChildWindows(m,findTcp,reinterpret_cast<LPARAM>(&tcp));if(!tcp)return false;
  if(targets==std::array<HWND,3>{m,a,tcp} && wave==w && files==f && project==proj && command==cmd)return true;
  AMDropDetach();
#define GET(v,n) v=reinterpret_cast<decltype(v)>(get(n));if(!v)return false
  GET(enumProjects,"EnumProjects");GET(action,"Main_OnCommandEx");GET(countItems,"CountMediaItems");GET(getItem,"GetMediaItem");GET(itemString,"GetSetMediaItemInfo_String");GET(beginUndo,"Undo_BeginBlock2");GET(endUndo,"Undo_EndBlock2");GET(canUndo,"Undo_CanUndo2");GET(undo,"Undo_DoUndo2");GET(stateCount,"GetProjectStateChangeCount");GET(fileInfo,"MediaExplorerGetLastPlayedFileInfo");
  GET(toggleState,"GetToggleCommandStateEx");
#undef GET
  targets={m,a,tcp};wave=w;files=f;project=proj;command=cmd;
  for(HWND target:targets)if(!SetWindowSubclass(target,targetProc,targetId,0)){AMDropDetach();return false;}
  EnumChildWindows(a,hookChild,0);EnumChildWindows(tcp,hookChild,0);
  if(!SetWindowSubclass(wave,sourceProc,sourceId,1) || (files && !SetWindowSubclass(files,sourceProc,sourceId,2))){AMDropDetach();return false;}return true;
}
extern "C" bool AMDropAttach(void* main,void* arrange,void* source,void* project,int command,void*(*get)(const char*)){return AMDropAttachSources(main,arrange,source,nullptr,project,command,get);}
extern "C" const char* AMDropContext(){return context.c_str();}
extern "C" void AMDropResult(bool value){if(busy)result=value;}
extern "C" const char* AMDropDiagnostics(){static std::string text;diagnostics["attached"]=IsWindow(wave)!=FALSE;text=diagnostics.dump();return text.c_str();}
