// Included by bar.cpp inside its anonymous namespace; dependencies belong there
// at file scope so standard-library declarations stay in the global namespace.
// Modeless, owned by Media Explorer. Losing activation never dismisses settings.
struct SettingsPanel {
  HWND window=nullptr,tabs=nullptr,cache=nullptr,diagnostics=nullptr,notice=nullptr,choose=nullptr,defaults=nullptr,render=nullptr;
  HFONT font=nullptr;Json state=Json::object();bool paused=false,closing=false,updating=false;int selected=0;
  struct Child { HWND window;int page,x,y,w,h; };
  std::vector<Child> children;
  std::array<HWND,amsettings::count> controls{},numbers{};
  ~SettingsPanel(){close(false);}
  HWND child(const wchar_t* cls,const std::string& title,DWORD style,int id,int page,int x,int y,int w,int h){
    HWND c=CreateWindowExW(cls==std::wstring(L"EDIT")?WS_EX_CLIENTEDGE:0,cls,amwin::wide(title).c_str(),WS_CHILD|style,0,0,1,1,window,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),amwin::module(),nullptr);
    children.push_back({c,page,x,y,w,h});SetWindowSubclass(c,keyProc,1,reinterpret_cast<DWORD_PTR>(this));return c;
  }
  void layout(){
    HFONT old=font;font=CreateFontW(-amwin::scale(window,12),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    for(const auto& c:children){
      SendMessageW(c.window,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);
      SetWindowPos(c.window,nullptr,amwin::scale(window,c.x),amwin::scale(window,c.y),amwin::scale(window,c.w),amwin::scale(window,c.h),SWP_NOZORDER|SWP_NOACTIVATE);
      ShowWindow(c.window,c.page<0 || c.page==selected?SW_SHOWNOACTIVATE:SW_HIDE);
    }
    SetWindowPos(tabs,HWND_BOTTOM,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
    if(old)DeleteObject(old);
  }
  void create(HWND anchor){
    WNDCLASSW wc{};wc.lpfnWndProc=proc;wc.hInstance=amwin::module();wc.lpszClassName=L"SoundPrepAppSettings";wc.hbrBackground=GetSysColorBrush(COLOR_BTNFACE);wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);RegisterClassW(&wc);
    RECT a{};GetWindowRect(anchor,&a);RECT frame{0,0,amwin::scale(anchor,640),amwin::scale(anchor,476)};
    DWORD style=WS_POPUP|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN;
    AdjustWindowRectExForDpi(&frame,style,FALSE,WS_EX_TOOLWINDOW|WS_EX_CONTROLPARENT,GetDpiForWindow(anchor));
    MONITORINFO monitor{sizeof(monitor)};GetMonitorInfoW(MonitorFromWindow(anchor,MONITOR_DEFAULTTONEAREST),&monitor);
    int width=frame.right-frame.left,height=frame.bottom-frame.top;
    int x=std::max(monitor.rcWork.left,std::min(a.left,monitor.rcWork.right-width)),y=std::max(monitor.rcWork.top,std::min(a.bottom,monitor.rcWork.bottom-height));
    window=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_CONTROLPARENT,wc.lpszClassName,L"SoundPrep — App settings",style,x,y,width,height,GetAncestor(anchor,GA_ROOT),nullptr,wc.hInstance,this);
    if(!window)throw std::runtime_error("Cannot create app settings");
    child(L"STATIC","App settings",SS_NOPREFIX,0,-1,20,12,600,24);
    tabs=child(WC_TABCONTROLW,"",WS_TABSTOP|WS_CLIPSIBLINGS,3000,-1,14,46,612,366);
    for(int i=0;i<4;++i){auto text=amwin::wide(amsettings::pages[i]);TCITEMW item{};item.mask=TCIF_TEXT;item.pszText=text.data();TabCtrl_InsertItem(tabs,i,&item);}
    TabCtrl_SetCurSel(tabs,selected);
    for(int i=0;i<amsettings::count;++i){
      const auto& s=amsettings::controls[i];int y0=80+s.y;
      if(s.kind==amsettings::toggle)controls[i]=child(L"BUTTON",s.label,WS_TABSTOP|BS_AUTOCHECKBOX,3100+i,s.page,30,y0,574,24);
      else {
        child(L"STATIC",s.label,SS_NOPREFIX,0,s.page,30,y0,450,20);
        controls[i]=child(TRACKBAR_CLASSW,"",WS_TABSTOP|TBS_HORZ|TBS_NOTICKS,3100+i,s.page,30,y0+24,456,24);
        SendMessageW(controls[i],TBM_SETRANGE,TRUE,MAKELPARAM(static_cast<int>(s.low*10),static_cast<int>(s.high*10)));
        SendMessageW(controls[i],TBM_SETPAGESIZE,0,10);
        numbers[i]=child(L"EDIT","",WS_TABSTOP|ES_AUTOHSCROLL,3200+i,s.page,498,y0+24,80,24);
        SendMessageW(numbers[i],EM_SETLIMITTEXT,32,0);
      }
      child(L"STATIC",s.help,SS_NOPREFIX,0,s.page,34,y0+(s.kind==amsettings::toggle?28:52),554,38);
    }
    render=child(L"BUTTON","Render selected drops",WS_TABSTOP,3300,1,30,346,190,28);
    child(L"STATIC","Analysis cache folder",SS_NOPREFIX,0,2,30,92,548,24);
    cache=child(L"EDIT","",WS_TABSTOP|ES_MULTILINE|ES_READONLY|WS_VSCROLL,0,2,30,124,548,80);
    choose=child(L"BUTTON","Choose folder…",WS_TABSTOP,3301,2,30,218,154,28);
    defaults=child(L"BUTTON","Use default",WS_TABSTOP,3302,2,196,218,138,28);
    child(L"STATIC","New analysis jobs use this folder. Running jobs finish in their original folder; existing files stay where they are. Rendered project media uses its own location.",SS_NOPREFIX,0,2,30,264,548,90);
    diagnostics=child(L"STATIC","",SS_NOPREFIX,0,3,30,178,548,42);
    child(L"STATIC","Source analysis runs in the native helper. No Python or FFmpeg setup is required.\r\n\r\nAssign the supplied 0–9 actions in Media Explorer for keyboard preset switching.",SS_NOPREFIX,0,3,30,232,548,110);
    notice=child(L"STATIC","",SS_NOPREFIX,0,-1,20,422,492,44);
    child(L"BUTTON","Done",WS_TABSTOP|BS_DEFPUSHBUTTON,3303,-1,530,426,90,28);
    layout();
  }
  void event(Json event){if(!paused)enqueue("settings@"+event.dump());}
  void numberChanged(int i){
    if(updating || paused || !numbers[i])return;
    auto text=amwin::text(numbers[i]);wchar_t* end=nullptr;double value=std::wcstod(text.c_str(),&end);
    const bool parsed=end && end!=text.c_str();
    while(end && std::iswspace(*end))++end;
    const auto& s=amsettings::controls[i];
    if(!parsed || *end || !std::isfinite(value) || value<s.low || value>s.high){
      char message[128];std::snprintf(message,sizeof(message),"Enter a number between %.0f and %.0f.",s.low,s.high);amwin::text(notice,message);
      if(state.contains("values")){char textValue[64];std::snprintf(textValue,sizeof(textValue),"%.1f",state["values"][s.key].get<double>());amwin::text(numbers[i],textValue);}return;
    }
    if(state.contains("values") && value==state["values"][s.key].get<double>())return;
    event({{"op","set"},{"key",s.key},{"value",value}});
  }
  void update(const Json& next,bool disabled,HWND anchor){
    bool wasOpen=state.value("open",false),focus=state.value("focus",0)!=next.value("focus",0);
    state=next;paused=disabled;
    if(!next.value("open",false)){close(false);return;}
    if(!window && (!wasOpen || focus))create(anchor);if(!window)return;
    updating=true;
    for(int i=0;i<amsettings::count;++i){
      const auto& s=amsettings::controls[i];EnableWindow(controls[i],!paused);
      if(s.kind==amsettings::toggle)SendMessageW(controls[i],BM_SETCHECK,next.at("values").at(s.key).get<bool>()?BST_CHECKED:BST_UNCHECKED,0);
      else {
        EnableWindow(numbers[i],!paused);
        if(GetFocus()!=numbers[i] && GetCapture()!=controls[i]){
          double value=next.at("values").at(s.key);SendMessageW(controls[i],TBM_SETPOS,TRUE,static_cast<int>(std::round(value*10)));
          char text[64];std::snprintf(text,sizeof(text),"%.1f",value);amwin::text(numbers[i],text);
        }
      }
    }
    if(amwin::text(cache)!=amwin::wide(next.at("cache_path")))amwin::text(cache,next.at("cache_path"));
    EnableWindow(choose,!paused && next.at("cache_available").get<bool>());EnableWindow(defaults,!paused && next.at("cache_available").get<bool>() && !next.at("cache_default").get<bool>());
    EnableWindow(render,!paused);amwin::text(diagnostics,next.at("diagnostics"));
    amwin::text(notice,paused?"Paused — return to the attached project to change settings.":next.at("notice").get<std::string>());updating=false;
    if(!wasOpen || focus){ShowWindow(window,SW_SHOW);SetForegroundWindow(window);SetFocus(tabs);}
  }
  void close(bool notify){
    if(!window || closing)return;closing=true;
    if(notify){for(int i=0;i<amsettings::count;++i)if(GetFocus()==numbers[i])numberChanged(i);enqueue("settings:close");}
    HWND old=window;window=nullptr;DestroyWindow(old);children.clear();controls.fill(nullptr);numbers.fill(nullptr);
    if(font)DeleteObject(font);font=nullptr;closing=false;
  }
  static LRESULT CALLBACK keyProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR data){
    auto self=reinterpret_cast<SettingsPanel*>(data);
    if(m==WM_NCDESTROY)RemoveWindowSubclass(w,keyProc,1);
    if(m==WM_KEYDOWN){
      if(p==VK_ESCAPE){self->close(true);return 0;}
      if(p==VK_TAB){HWND next=GetNextDlgTabItem(self->window,w,(GetKeyState(VK_SHIFT)&0x8000)!=0);if(next)SetFocus(next);return 0;}
      if(p==VK_RETURN){int id=GetDlgCtrlID(w);if(id>=3200 && id<3200+amsettings::count){self->numberChanged(id-3200);return 0;}}
    }
    return DefSubclassProc(w,m,p,l);
  }
  static LRESULT CALLBACK proc(HWND w,UINT m,WPARAM p,LPARAM l){
    auto self=reinterpret_cast<SettingsPanel*>(GetWindowLongPtrW(w,GWLP_USERDATA));
    if(m==WM_NCCREATE){self=static_cast<SettingsPanel*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
    if(!self)return DefWindowProcW(w,m,p,l);
    if(m==WM_CLOSE){self->close(true);return 0;}
    if(m==WM_DPICHANGED){auto rect=reinterpret_cast<RECT*>(l);SetWindowPos(w,nullptr,rect->left,rect->top,rect->right-rect->left,rect->bottom-rect->top,SWP_NOZORDER|SWP_NOACTIVATE);self->layout();return 0;}
    if(m==WM_NOTIFY && reinterpret_cast<NMHDR*>(l)->hwndFrom==self->tabs && reinterpret_cast<NMHDR*>(l)->code==TCN_SELCHANGE){self->selected=TabCtrl_GetCurSel(self->tabs);self->layout();return 0;}
    try {
      if(m==WM_HSCROLL){for(int i=0;i<amsettings::count;++i)if(reinterpret_cast<HWND>(l)==self->controls[i]){
        double value=SendMessageW(self->controls[i],TBM_GETPOS,0,0)/10.0;char text[64];std::snprintf(text,sizeof(text),"%.1f",value);amwin::text(self->numbers[i],text);
        self->event({{"op","set"},{"key",amsettings::controls[i].key},{"value",value},{"commit",LOWORD(p)!=TB_THUMBTRACK}});return 0;
      }}
      if(m==WM_COMMAND){int id=LOWORD(p),code=HIWORD(p);
        if(id>=3100 && id<3100+amsettings::count && code==BN_CLICKED){int i=id-3100;
          if(amsettings::controls[i].kind==amsettings::toggle)self->event({{"op","set"},{"key",amsettings::controls[i].key},{"value",SendMessageW(self->controls[i],BM_GETCHECK,0,0)==BST_CHECKED}});
        }else if(id>=3200 && id<3200+amsettings::count && code==EN_KILLFOCUS && !self->closing)self->numberChanged(id-3200);
        else if(code==BN_CLICKED){if(id==3303)self->close(true);else if(id>=3300 && id<=3302){const char* actions[]={"render_drops","cache_choose","cache_default"};self->event({{"op",actions[id-3300]}});}}
        return 0;
      }
    }catch(...){}
    return DefWindowProcW(w,m,p,l);
  }
};
