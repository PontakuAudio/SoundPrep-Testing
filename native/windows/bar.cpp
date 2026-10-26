// Native child controls; REAPER retains its list, shortcuts, waveform and drag sources.
#include "common.h"
#include "../contract.h"
#include "../settings_layout.h"
#include <cstring>
#include "../editor_layout.h"
#include <cmath>
#include <cwchar>
#include <cwctype>
#include <deque>
#include <memory>
#include <array>
#include <cstdio>
using amwin::Json;
namespace {
struct AMWinValue {
  const Json* value;
  amcontract::Kind kind() const {
    if(!value)return amcontract::Kind::missing;
    if(value->is_object())return amcontract::Kind::object;
    if(value->is_array())return amcontract::Kind::array;
    if(value->is_string())return amcontract::Kind::string;
    if(value->is_boolean())return amcontract::Kind::boolean;
    if(value->is_number() && std::isfinite(value->get<double>()))return amcontract::Kind::number;
    return amcontract::Kind::null_value;
  }
  AMWinValue child(const char* name) const { auto found=value->find(name);return {found==value->end()?nullptr:&*found}; }
  std::size_t size() const { return value->size(); }
  double number() const { return value->get<double>(); }
  AMWinValue at(std::size_t index) const { return {&value->at(index)}; }
};

std::deque<std::string> events;
void enqueue(const std::string& value){if(events.size()==64)events.pop_front();events.push_back(value);}
// Panel implementations share this namespace; include their dependencies above.
#include "channel_panel.h"
#include "settings_panel.h"
#include "editor_panel.h"
constexpr UINT_PTR barHook=0x414d4241,focusHook=0x414d4246;
struct Bar {
  HWND parent=nullptr,list=nullptr,window=nullptr,status=nullptr,focus=nullptr;
  HFONT font=nullptr;DWORD selectionStart=0,selectionEnd=0;bool hasSelection=false,adjusting=false,paused=false,multichannel=false;
  RECT base{},applied{};int height=0;bool hidden=false;Json state=Json::object();
  std::array<HWND,amcontract::control_count> controls{};std::array<HWND,amcontract::max_macros> presets{};
  std::array<std::wstring,amcontract::control_count> controlTips{};HWND tips=nullptr;
  std::vector<std::string> macroIds,targetIds,monitorIds;std::vector<std::wstring> presetLabels;
  ChannelPanel channels;SettingsPanel settings;EditorPanel editor;
  ~Bar(){detach();}
  void remember(){
    HWND current=GetFocus();if(!amwin::inside(parent,current) || amwin::inside(window,current))return;
    focus=current;wchar_t cls[64]{};GetClassNameW(current,cls,64);hasSelection=_wcsicmp(cls,L"Edit")==0;
    if(hasSelection)SendMessageW(current,EM_GETSEL,reinterpret_cast<WPARAM>(&selectionStart),reinterpret_cast<LPARAM>(&selectionEnd));
  }
  void restoreFocus(){
    HWND root=GetAncestor(parent,GA_ROOT);if(GetForegroundWindow()!=root && GetActiveWindow()!=root)return;
    if(IsWindow(focus) && IsWindowVisible(focus) && amwin::inside(parent,focus)){
      SetFocus(focus);if(hasSelection)SendMessageW(focus,EM_SETSEL,selectionStart,selectionEnd);
    }else if(IsWindow(list))SetFocus(list);
  }
  static LRESULT CALLBACK controlProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR ref){
    auto b=reinterpret_cast<Bar*>(ref);if(m==WM_LBUTTONDOWN)b->remember();
    if(m==WM_NCDESTROY)RemoveWindowSubclass(w,controlProc,focusHook);
    return DefSubclassProc(w,m,p,l);
  }
  static LRESULT CALLBACK listProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR ref){
    auto b=reinterpret_cast<Bar*>(ref);LRESULT result=DefSubclassProc(w,m,p,l);
    if(m==WM_WINDOWPOSCHANGED && !b->adjusting && IsWindow(w)){
      RECT current=amwin::rect(w,b->parent);
      if(!EqualRect(&current,&b->applied)){b->base=current;b->reflow();}
    }
    if(m==WM_NCDESTROY){RemoveWindowSubclass(w,listProc,barHook);b->list=nullptr;}
    return result;
  }
  static LRESULT CALLBACK proc(HWND w,UINT m,WPARAM p,LPARAM l){
    auto b=reinterpret_cast<Bar*>(GetWindowLongPtrW(w,GWLP_USERDATA));
    if(m==WM_NCCREATE){b=static_cast<Bar*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(b));}
    if(b && m==WM_COMMAND){try{b->command(LOWORD(p),HIWORD(p));}catch(...){}return 0;}
    if(m==WM_ERASEBKGND){RECT r{};GetClientRect(w,&r);FillRect(reinterpret_cast<HDC>(p),&r,GetSysColorBrush(COLOR_BTNFACE));return 1;}
    return DefWindowProcW(w,m,p,l);
  }
  bool attach(HWND fileList){
    list=fileList;parent=GetParent(list);if(!parent)return false;base=applied=amwin::rect(list,parent);
    WNDCLASSW wc{};wc.lpfnWndProc=proc;wc.hInstance=amwin::module();wc.lpszClassName=L"AuditionMacroBar";wc.hbrBackground=GetSysColorBrush(COLOR_BTNFACE);wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);RegisterClassW(&wc);
    window=CreateWindowExW(WS_EX_CONTROLPARENT,wc.lpszClassName,L"SoundPrep",WS_CHILD|WS_CLIPCHILDREN,0,0,0,0,parent,nullptr,wc.hInstance,this);if(!window)return false;
    font=CreateFontW(-amwin::scale(parent,12),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    for(int i=0;i<amcontract::control_count;++i){const auto &spec=amcontract::controls[i];bool combo=spec.kind==amcontract::ControlKind::popup;
      DWORD style=WS_CHILD|WS_VISIBLE|WS_TABSTOP|(combo?CBS_DROPDOWNLIST|WS_VSCROLL:(spec.kind==amcontract::ControlKind::toggle?BS_AUTOCHECKBOX|BS_PUSHLIKE:BS_PUSHBUTTON));
      controls[i]=CreateWindowExW(0,combo?L"COMBOBOX":L"BUTTON",amwin::wide(spec.title).c_str(),style,0,0,1,1,window,reinterpret_cast<HMENU>(static_cast<INT_PTR>(100+i)),wc.hInstance,nullptr);
      SendMessageW(controls[i],WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);SetWindowSubclass(controls[i],controlProc,focusHook,reinterpret_cast<DWORD_PTR>(this));
    }
    tips=CreateWindowExW(WS_EX_TOPMOST,TOOLTIPS_CLASSW,nullptr,WS_POPUP|TTS_ALWAYSTIP|TTS_NOPREFIX,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,window,nullptr,wc.hInstance,nullptr);
    SendMessageW(tips,TTM_SETMAXTIPWIDTH,0,400);
    for(int i=0;i<amcontract::control_count;++i){
      controlTips[i]=amwin::wide(amcontract::controls[i].tooltip);
      TOOLINFOW tip{sizeof(tip)};tip.uFlags=TTF_IDISHWND|TTF_SUBCLASS;tip.hwnd=window;tip.uId=reinterpret_cast<UINT_PTR>(controls[i]);
      tip.lpszText=controlTips[i].data();SendMessageW(tips,TTM_ADDTOOLW,0,reinterpret_cast<LPARAM>(&tip));
    }
    for(std::size_t i=0;i<amcontract::max_macros;++i){
      presets[i]=CreateWindowExW(0,L"BUTTON",L"",WS_CHILD|WS_TABSTOP|BS_AUTOCHECKBOX|BS_PUSHLIKE,0,0,1,1,window,reinterpret_cast<HMENU>(static_cast<INT_PTR>(200+i)),wc.hInstance,nullptr);
      SendMessageW(presets[i],WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);SetWindowSubclass(presets[i],controlProc,focusHook,reinterpret_cast<DWORD_PTR>(this));
      TOOLINFOW tool{sizeof(tool)};tool.uFlags=TTF_IDISHWND|TTF_SUBCLASS;tool.hwnd=window;tool.uId=reinterpret_cast<UINT_PTR>(presets[i]);tool.lpszText=const_cast<wchar_t*>(L"");SendMessageW(tips,TTM_ADDTOOLW,0,reinterpret_cast<LPARAM>(&tool));
    }
    status=CreateWindowExW(0,L"STATIC",L"",WS_CHILD|WS_VISIBLE|SS_LEFTNOWORDWRAP,0,0,1,1,window,nullptr,wc.hInstance,nullptr);SendMessageW(status,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);
    if(!SetWindowSubclass(list,listProc,barHook,reinterpret_cast<DWORD_PTR>(this)))return false;
    remember();reflow();return true;
  }
  void reflow(){
    if(!IsWindow(list) || adjusting)return;adjusting=true;
    int s=static_cast<int>(GetDpiForWindow(parent));auto px=[s](int v){return MulDiv(v,s,96);};
    int width=base.right-base.left,bh=base.bottom-base.top;int logical=MulDiv(width,96,s);
    bool compact=width<px(amcontract::compact_width) || bh<px(amcontract::compact_height),minimal=bh<px(amcontract::minimal_height);
    int rows=1,x=3;
    for(int i=1;i<amcontract::control_count;++i){if(i==amcontract::downmix && !multichannel)continue;int cw=compact?amcontract::controls[i].compact_width:amcontract::controls[i].width;if(!cw)continue;if(x+cw>logical-3){++rows;x=3;}x+=cw+3;}
    height=px(minimal?30:28+rows*26+(compact?0:18));hidden=width<px(amcontract::min_width) || bh<height+px(amcontract::min_list_height);
    if(hidden){ShowWindow(window,SW_HIDE);applied=base;SetWindowPos(list,nullptr,base.left,base.top,width,bh,SWP_NOZORDER|SWP_NOACTIVATE);adjusting=false;return;}
    SetWindowPos(window,nullptr,base.left,base.top,width,height,SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW);
    applied=base;applied.top+=height;SetWindowPos(list,nullptr,applied.left,applied.top,width,bh-height,SWP_NOZORDER|SWP_NOACTIVATE);
    int count=1+static_cast<int>(macroIds.size());int available=width-px(minimal?84:6),gap=px(3);
    int cw=std::min(px(156),(available-(count-1)*gap)/count);
    amwin::text(controls[amcontract::raw],cw<px(50)?"0":"0 Raw");ShowWindow(controls[amcontract::raw],SW_SHOWNOACTIVATE);
    SetWindowPos(controls[amcontract::raw],nullptr,px(3),px(2),cw,px(24),SWP_NOZORDER|SWP_NOACTIVATE);
    for(std::size_t i=0;i<amcontract::max_macros;++i){bool visible=i<macroIds.size();ShowWindow(presets[i],visible?SW_SHOWNOACTIVATE:SW_HIDE);if(!visible)continue;
      auto label=presetLabels[i];
      if(cw<px(64)){auto end=label.find(L"  ");label=end==std::wstring::npos?label.substr(0,3):label.substr(0,end);if(label==L"–")label=presetLabels[i].substr(end+2,3);}
      SetWindowTextW(presets[i],label.c_str());
      SetWindowPos(presets[i],nullptr,px(3)+static_cast<int>(i+1)*(cw+gap),px(2),cw,px(24),SWP_NOZORDER|SWP_NOACTIVATE);
    }
    for(int i=1;i<amcontract::control_count;++i)if(amcontract::controls[i].kind!=amcontract::ControlKind::popup)
      amwin::text(controls[i],compact?amcontract::controls[i].compact_title:amcontract::controls[i].title);
    x=minimal?logical-78:3;int y=minimal?2:28;
    for(int i=1;i<amcontract::control_count;++i){
      bool hide=(i==amcontract::downmix && !multichannel) || (minimal?!amcontract::controls[i].minimal:(compact && !amcontract::controls[i].compact_width));ShowWindow(controls[i],hide?SW_HIDE:SW_SHOWNOACTIVATE);if(hide)continue;
      int toolWidth=compact?amcontract::controls[i].compact_width:amcontract::controls[i].width;const auto &spec=amcontract::controls[i];bool combo=spec.kind==amcontract::ControlKind::popup;
      if(!minimal && x+toolWidth>logical-3){x=3;y+=26;}
      SetWindowPos(controls[i],nullptr,px(x),px(y),px(toolWidth),px(combo?300:24),SWP_NOZORDER|SWP_NOACTIVATE);x+=toolWidth+3;
    }
    ShowWindow(status,compact?SW_HIDE:SW_SHOWNOACTIVATE);SetWindowPos(status,nullptr,px(6),height-px(18),std::max(0,width-px(12)),px(16),SWP_NOZORDER|SWP_NOACTIVATE);
    channels.position();adjusting=false;
  }
  void fill(int index,const std::vector<std::pair<std::string,std::string>>& values,const std::string& selected,std::vector<std::string>& ids){
    SendMessageW(controls[index],CB_RESETCONTENT,0,0);ids.clear();int selection=0;
    for(const auto& pair:values){if(pair.first==selected)selection=static_cast<int>(ids.size());ids.push_back(pair.first);auto label=amwin::wide(pair.second);SendMessageW(controls[index],CB_ADDSTRING,0,reinterpret_cast<LPARAM>(label.c_str()));}
    SendMessageW(controls[index],CB_SETCURSEL,selection,0);
  }
  void update(const Json& next){
    paused=next.at("paused").get<bool>();
    bool layoutChanged=multichannel!=next.value("multichannel",false);multichannel=next.value("multichannel",false);
    if(!state.contains("macros") || state["macros"]!=next["macros"]){
      macroIds.clear();presetLabels.clear();
      for(const auto& m:next["macros"]){macroIds.push_back(m.at("id"));presetLabels.push_back(amwin::wide(m.at("label")));}
      for(size_t i=0;i<macroIds.size();++i){
        TOOLINFOW tool{sizeof(tool)};tool.hwnd=window;tool.uId=reinterpret_cast<UINT_PTR>(presets[i]);tool.lpszText=presetLabels[i].data();SendMessageW(tips,TTM_UPDATETIPTEXTW,0,reinterpret_cast<LPARAM>(&tool));
      }
      layoutChanged=true;
    }
    if(layoutChanged)reflow();
    for(size_t i=0;i<macroIds.size();++i){EnableWindow(presets[i],!paused);SendMessageW(presets[i],BM_SETCHECK,next["active"]==macroIds[i]?BST_CHECKED:BST_UNCHECKED,0);}
    for(int i=0;i<amcontract::control_count;++i)if(amcontract::controls[i].kind==amcontract::ControlKind::toggle) {
      bool checked=i==amcontract::raw?next["active"]=="raw":next.value(amcontract::controls[i].command,false);
      SendMessageW(controls[i],BM_SETCHECK,checked?BST_CHECKED:BST_UNCHECKED,0);
    }
    auto number=[](double n){char value[32];std::snprintf(value,sizeof(value),"%.1f",n);return std::string(value);};
    if(!state.contains("target") || state["target"]!=next["target"] || state.value("target_label",std::string{})!=next.value("target_label",std::string{})){
      std::vector<std::pair<std::string,std::string>> values;auto chosen=number(next.at("target"));
      if(next.contains("target_label"))values.emplace_back(chosen,next.at("target_label").get<std::string>());
      else{
        for(double n:amcontract::target_options)values.emplace_back(number(n),"Norm "+number(n)+" LUFS");
        if(std::none_of(values.begin(),values.end(),[&](const auto& v){return v.first==chosen;}))values.emplace_back(chosen,"Norm "+chosen+" LUFS");
      }
      values.emplace_back("custom","Custom...");
      fill(amcontract::target,values,chosen,targetIds);
    }
    if(!state.contains("monitor") || state["monitor"]!=next["monitor"]){std::vector<std::pair<std::string,std::string>> values;for(double n:amcontract::monitor_options)values.emplace_back(number(n),"Monitor "+number(n)+" dB");auto chosen=number(next.at("monitor"));if(std::none_of(values.begin(),values.end(),[&](const auto& v){return v.first==chosen;}))values.emplace_back(chosen,"Monitor "+chosen+" dB");fill(amcontract::monitor,values,chosen,monitorIds);}
    for(int i=0;i<amcontract::control_count;++i)EnableWindow(controls[i],!paused || i==amcontract::quit);amwin::text(status,next.at("status"));state=next;
    bool channelWasOpen=channels.window!=nullptr;
    HWND channelAnchor=IsWindowVisible(controls[amcontract::channels])?controls[amcontract::channels]:controls[amcontract::edit];
    channels.update(next.value("channels",Json::object()),paused,channelAnchor,font);
    settings.update(next.value("settings",Json::object()),paused,controls[amcontract::edit]);
    editor.update(next.value("editor",Json::object()),paused,controls[amcontract::edit]);
    if(channelWasOpen && !channels.window)restoreFocus();

  }
  void command(int id,int code){
    if(id>=200 && id<200+static_cast<int>(amcontract::max_macros)){if(!paused && code==BN_CLICKED && id-200<static_cast<int>(macroIds.size())){enqueue("macro:"+macroIds[id-200]);restoreFocus();}return;}
    int i=id-100;if(i<0 || i>=amcontract::control_count || (paused && i!=amcontract::quit))return;
    if(i==amcontract::target || i==amcontract::monitor){if(code!=CBN_SELCHANGE)return;int selected=static_cast<int>(SendMessageW(controls[i],CB_GETCURSEL,0,0));auto& ids=i==amcontract::target?targetIds:monitorIds;if(selected<0 || selected>=static_cast<int>(ids.size()))return;
        enqueue(std::string(amcontract::controls[i].command)+":"+ids[selected]);
        if(i==amcontract::target && ids[selected]=="custom") {
          // Opening the editor does not change the target. Keep its current
          // numeric value visible, including when the user cancels the editor.
          char chosen[32];std::snprintf(chosen,sizeof(chosen),"%.1f",state.at("target").get<double>());
          auto current=std::find(ids.begin(),ids.end(),chosen);
          SendMessageW(controls[i],CB_SETCURSEL,current==ids.end()?0:current-ids.begin(),0);
        }
    }else if(code==BN_CLICKED){enqueue(amcontract::controls[i].command);}
    restoreFocus();
  }
  void detach(){
    channels.close(false);settings.close(false);editor.close(false);
    if(IsWindow(list)){RemoveWindowSubclass(list,listProc,barHook);RECT current=amwin::rect(list,parent);if(EqualRect(&current,&applied))SetWindowPos(list,nullptr,base.left,base.top,base.right-base.left,base.bottom-base.top,SWP_NOZORDER|SWP_NOACTIVATE);}
    if(IsWindow(window))DestroyWindow(window);window=list=parent=nullptr;if(font)DeleteObject(font);font=nullptr;
  }
};
std::unique_ptr<Bar> bar;
// Public REAPER SDK accelerator_register_t layout. Scope routing to our popup;
// ME's own list, search field and waveform retain their normal shortcuts.
struct Accelerator {int(*translate)(MSG*,Accelerator*);bool local;void* user;};
int keyboard(MSG* message,Accelerator*){
  return message && bar && (amwin::inside(bar->channels.window,message->hwnd) || amwin::inside(bar->settings.window,message->hwnd) || amwin::inside(bar->editor.window,message->hwnd))?-1:0;
}
int hwndInfo(HWND window,INT_PTR kind){
  if(kind!=0 || !bar || !(amwin::inside(bar->channels.window,window) || amwin::inside(bar->settings.window,window) || amwin::inside(bar->editor.window,window)))return 0;
  wchar_t cls[32]{};GetClassNameW(window,cls,32);return _wcsicmp(cls,L"Edit")==0?1:-1;
}
Accelerator accelerator{keyboard,true,nullptr};
bool keyboardRegistered=false;
}
extern "C" void AMBarKeyboardRegister(int(*reg)(const char*,void*),bool enable){
  if(!reg || enable==keyboardRegistered)return;
  reg(enable?"accelerator":"-accelerator",&accelerator);
  reg(enable?"hwnd_info":"-hwnd_info",reinterpret_cast<void*>(hwndInfo));
  keyboardRegistered=enable;
}
extern "C" bool AMBarAttach(void*,void* files){
  HWND list=static_cast<HWND>(files);if(!IsWindow(list))return false;
  if(bar && bar->list==list && IsWindow(bar->window))return true;
  try{bar.reset();events.clear();auto candidate=std::make_unique<Bar>();if(!candidate->attach(list))return false;bar=std::move(candidate);return true;}catch(...){return false;}
}
extern "C" bool AMBarSetState(const char* text){
  try{if(!bar || !text || std::strlen(text)>amcontract::max_json_bytes)return false;auto state=Json::parse(text);
    if(!amcontract::valid_bar_state(AMWinValue{&state}))return false;
    bar->update(state);return true;
  }catch(...){return false;}
}
extern "C" const char* AMBarPoll(){static std::string result;result.clear();if(!events.empty()){result=std::move(events.front());events.pop_front();}return result.c_str();}
extern "C" void AMBarDetach(){bar.reset();events.clear();}
extern "C" const char* AMBarGeometry(){
  static std::string result;result="{}";
  if(bar && IsWindow(bar->list)){RECT actual=amwin::rect(bar->list,bar->parent);result=Json{{"attached",true},{"same_window",GetParent(bar->window)==GetParent(bar->list)},{"hidden",bar->hidden},{"height",bar->height},{"width",bar->base.right-bar->base.left},{"base_height",bar->base.bottom-bar->base.top},{"list_height",actual.bottom-actual.top},
    {"microphones_open",bar->channels.window!=nullptr},{"settings_open",bar->settings.window!=nullptr},{"editor_open",bar->editor.window!=nullptr},{"downmix_visible",IsWindowVisible(bar->controls[amcontract::downmix])!=FALSE},{"downmix",SendMessageW(bar->controls[amcontract::downmix],BM_GETCHECK,0,0)==BST_CHECKED},
    {"control_count",amcontract::control_count+bar->macroIds.size()}}.dump();}return result.c_str();
}
