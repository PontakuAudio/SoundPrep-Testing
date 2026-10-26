// Dependencies are included at file scope in bar.cpp (also required by MSVC).
struct EditorPanel {
  HWND window=nullptr,tabs=nullptr,presetTips=nullptr,notice=nullptr,source=nullptr,saved=nullptr,measurement=nullptr;
  HWND save=nullptr,revert=nullptr,fx=nullptr,play=nullptr,replay=nullptr,ab=nullptr;
  HFONT font=nullptr;Json state=Json::object();bool paused=false,closing=false,updating=false;int selected=0,scrollOffset=0,presetOffset=0;
  std::array<HWND,amcontract::max_macros+1> presets{};
  std::array<std::wstring,amcontract::max_macros+1> presetLabels{};
  struct Child{HWND window;int page,x,y,w,h;};std::vector<Child> children;
  std::array<HWND,ameditor::count> controls{},numbers{};std::vector<HWND> actions;
  ~EditorPanel(){close(false);}
  HWND child(const wchar_t* cls,const char* title,DWORD style,int id,int page,int x,int y,int w,int h){
    HWND c=CreateWindowExW(!wcscmp(cls,L"EDIT")?WS_EX_CLIENTEDGE:0,cls,amwin::wide(title).c_str(),WS_CHILD|style,0,0,1,1,window,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),amwin::module(),nullptr);
    children.push_back({c,page,x,y,w,h});SetWindowSubclass(c,keyProc,1,reinterpret_cast<DWORD_PTR>(this));return c;
  }
  void scrollTo(int offset){
    RECT r{};GetClientRect(window,&r);int height=MulDiv(r.bottom-r.top,96,GetDpiForWindow(window));
    scrollOffset=std::max(0,std::min(offset,700+presetOffset-height));layout();
  }
  void reveal(HWND w){
    RECT r{};GetClientRect(window,&r);int height=MulDiv(r.bottom-r.top,96,GetDpiForWindow(window));
    for(const auto& c:children)if(c.window==w){int h=std::min(c.h,32),y=c.y+(c.page==-2?0:presetOffset);
      if(y<scrollOffset)scrollTo(y);else if(y+h>scrollOffset+height)scrollTo(y+h-height);break;}
  }
  void layout(){
    HFONT old=font;font=CreateFontW(-amwin::scale(window,12),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    ameditor::PresetLayout presetLayout;HDC dc=GetDC(window);HGDIOBJ oldFont=SelectObject(dc,font);
    for(auto& c:children)if(c.page==-2){int i=GetDlgCtrlID(c.window)-4400;if(i>=static_cast<int>(state.at("presets").size()))continue;
      SIZE size{};GetTextExtentPoint32W(dc,presetLabels[i].c_str(),static_cast<int>(presetLabels[i].size()),&size);
      auto r=presetLayout.add(MulDiv(size.cx,96,GetDpiForWindow(window)));c.x=20+r.x;c.y=14+r.y;c.w=r.w;c.h=r.h;
    }
    SelectObject(dc,oldFont);ReleaseDC(window,dc);presetOffset=presetLayout.height();
    RECT viewport{};GetClientRect(window,&viewport);scrollOffset=std::max(0,std::min(scrollOffset,700+presetOffset-MulDiv(viewport.bottom,96,GetDpiForWindow(window))));
    for(const auto& c:children){SendMessageW(c.window,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);
      SetWindowPos(c.window,nullptr,amwin::scale(window,c.x),amwin::scale(window,c.y+(c.page==-2?0:presetOffset)-scrollOffset),amwin::scale(window,c.w),amwin::scale(window,c.h),SWP_NOZORDER|SWP_NOACTIVATE);
      bool visible=c.page<0 || c.page==selected;
      int id=GetDlgCtrlID(c.window);if(c.page==-2)visible=id-4400<static_cast<int>(state.at("presets").size());
      if(id==4306 || id==4307)visible=visible && state.value("deleting",false);
      ShowWindow(c.window,visible?SW_SHOWNOACTIVATE:SW_HIDE);
    }
    SetWindowPos(tabs,HWND_BOTTOM,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
    RECT r{};GetClientRect(window,&r);SCROLLINFO info{sizeof(info),SIF_RANGE|SIF_PAGE|SIF_POS};info.nMax=699+presetOffset;info.nPage=MulDiv(r.bottom-r.top,96,GetDpiForWindow(window));info.nPos=scrollOffset;SetScrollInfo(window,SB_VERT,&info,TRUE);
    if(old)DeleteObject(old);
  }
  void create(HWND anchor){
    WNDCLASSW wc{};wc.lpfnWndProc=proc;wc.hInstance=amwin::module();wc.lpszClassName=L"SoundPrepPresetEditor";wc.hbrBackground=GetSysColorBrush(COLOR_BTNFACE);wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);RegisterClassW(&wc);
    RECT a{};GetWindowRect(anchor,&a);RECT frame{0,0,amwin::scale(anchor,700),amwin::scale(anchor,738)};DWORD style=WS_POPUP|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN|WS_VSCROLL;
    AdjustWindowRectExForDpi(&frame,style,FALSE,WS_EX_TOOLWINDOW|WS_EX_CONTROLPARENT,GetDpiForWindow(anchor));
    MONITORINFO monitor{sizeof(monitor)};GetMonitorInfoW(MonitorFromWindow(anchor,MONITOR_DEFAULTTONEAREST),&monitor);
    int width=frame.right-frame.left+GetSystemMetrics(SM_CXVSCROLL),height=std::min(frame.bottom-frame.top,monitor.rcWork.bottom-monitor.rcWork.top);
    int x=std::max(monitor.rcWork.left,std::min(a.left,monitor.rcWork.right-width)),y=std::max(monitor.rcWork.top,std::min(a.bottom,monitor.rcWork.bottom-height));
    window=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_CONTROLPARENT,wc.lpszClassName,L"SoundPrep — Presets & Tools",style,x,y,width,height,GetAncestor(anchor,GA_ROOT),nullptr,wc.hInstance,this);
    if(!window)throw std::runtime_error("Cannot create preset editor");
    presetTips=CreateWindowExW(WS_EX_TOPMOST,TOOLTIPS_CLASSW,nullptr,WS_POPUP|TTS_ALWAYSTIP|TTS_NOPREFIX,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,window,nullptr,wc.hInstance,nullptr);
    SendMessageW(presetTips,TTM_SETMAXTIPWIDTH,0,400);
    for(std::size_t i=0;i<presets.size();++i){
      presets[i]=child(L"BUTTON","",WS_TABSTOP|BS_CHECKBOX|BS_PUSHLIKE,4400+static_cast<int>(i),-2,20,14,72,30);
      TOOLINFOW tip{sizeof(tip)};tip.uFlags=TTF_IDISHWND|TTF_SUBCLASS;tip.hwnd=window;tip.uId=reinterpret_cast<UINT_PTR>(presets[i]);tip.lpszText=const_cast<wchar_t*>(L"");SendMessageW(presetTips,TTM_ADDTOOLW,0,reinterpret_cast<LPARAM>(&tip));
    }
    save=child(L"BUTTON","Save preset",WS_TABSTOP,4001,-1,20,14,110,30);revert=child(L"BUTTON","Revert saved",WS_TABSTOP,4002,-1,136,14,120,30);fx=child(L"BUTTON","Edit FX…",WS_TABSTOP,4003,-1,262,14,96,30);
    saved=child(L"STATIC","",SS_NOPREFIX,0,-1,20,52,660,22);source=child(L"STATIC","",SS_NOPREFIX|SS_PATHELLIPSIS,0,-1,20,78,660,24);
    play=child(L"BUTTON","Play",WS_TABSTOP,4004,-1,20,108,90,28);replay=child(L"BUTTON","Replay",WS_TABSTOP,4005,-1,116,108,90,28);ab=child(L"BUTTON","Raw / Processed",WS_TABSTOP,4006,-1,212,108,150,28);
    child(L"BUTTON","Focus ME",WS_TABSTOP,4007,-1,368,108,100,28);
    tabs=child(WC_TABCONTROLW,"",WS_TABSTOP|WS_CLIPSIBLINGS,4008,-1,14,148,672,486);
    for(int i=0;i<5;++i){auto text=amwin::wide(ameditor::pages[i]);TCITEMW item{};item.mask=TCIF_TEXT;item.pszText=text.data();TabCtrl_InsertItem(tabs,i,&item);}
    for(int i=0;i<ameditor::count;++i){const auto& s=ameditor::controls[i];int y0=182+s.y;
      if(s.kind==ameditor::toggle)controls[i]=child(L"BUTTON",s.label,WS_TABSTOP|BS_AUTOCHECKBOX,4100+i,s.page,30,y0,610,26);
      else {
        child(L"STATIC",s.label,SS_NOPREFIX,0,s.page,30,y0+4,204,28);
        if(s.kind==ameditor::number){controls[i]=child(TRACKBAR_CLASSW,"",WS_TABSTOP|TBS_HORZ|TBS_NOTICKS,4100+i,s.page,238,y0,282,26);
          int scale=!strcmp(s.key,"slot")?1:100;
          SendMessageW(controls[i],TBM_SETRANGEMIN,FALSE,static_cast<LPARAM>(s.low*scale));SendMessageW(controls[i],TBM_SETRANGEMAX,TRUE,static_cast<LPARAM>(s.high*scale));SendMessageW(controls[i],TBM_SETPAGESIZE,0,scale);
          numbers[i]=child(L"EDIT","",WS_TABSTOP|ES_AUTOHSCROLL,4200+i,s.page,530,y0,108,26);SendMessageW(numbers[i],EM_SETLIMITTEXT,32,0);
        }else if(s.kind==ameditor::choice){controls[i]=child(WC_COMBOBOXW,"",WS_TABSTOP|CBS_DROPDOWNLIST,4100+i,s.page,238,y0,400,160);
          for(const char* meter:ameditor::meters)SendMessageW(controls[i],CB_ADDSTRING,0,reinterpret_cast<LPARAM>(amwin::wide(meter).c_str()));
        }else {controls[i]=child(L"EDIT","",WS_TABSTOP|ES_AUTOHSCROLL,4100+i,s.page,238,y0,400,26);SendMessageW(controls[i],EM_SETLIMITTEXT,!strcmp(s.key,"name")?128:4096,0);}
      }
    }
    int i=0;for(const auto& s:ameditor::actions)actions.push_back(child(L"BUTTON",s.title,WS_TABSTOP,4300+i++,s.page,16+s.x,182+s.y,s.w,30));
    measurement=child(L"EDIT","",WS_TABSTOP|ES_MULTILINE|ES_READONLY|WS_VSCROLL,0,4,30,194,608,100);
    const int helpY[]={294,404,208,312,340};for(int p=0;p<5;++p)child(L"STATIC",ameditor::help[p],SS_NOPREFIX,0,p,30,182+helpY[p],608,p==1?42:104);
    notice=child(L"STATIC","",SS_NOPREFIX,0,-1,20,644,554,46);child(L"BUTTON","Done",WS_TABSTOP|BS_DEFPUSHBUTTON,4009,-1,590,650,90,28);
    layout();
  }
  void event(Json e){if(paused || updating)return;e["id"]=state.at("id");enqueue("editor@"+e.dump());}
  void fieldChanged(int i){
    if(updating || closing || paused)return;const auto& s=ameditor::controls[i];HWND w=s.kind==ameditor::number?numbers[i]:controls[i];Json value;
    if(s.kind==ameditor::number){auto text=amwin::text(w);wchar_t* end=nullptr;double n=std::wcstod(text.c_str(),&end);bool parsed=end && end!=text.c_str();while(end && std::iswspace(*end))++end;
      if(!parsed || *end || !std::isfinite(n) || n<s.low || n>s.high || (!strcmp(s.key,"slot") && std::floor(n)!=n)){
        amwin::text(notice,"Enter a valid number within this control's range.");char textValue[64];std::snprintf(textValue,sizeof(textValue),!strcmp(s.key,"slot")?"%.0f":"%.2f",state.at("values").at(s.key).get<double>());amwin::text(w,textValue);return;
      }value=n;
    }else value=amwin::utf8(amwin::text(w));
    if(value!=state.at("values").at(s.key))event({{"op","set"},{"key",s.key},{"value",value}});
  }
  void commitFocused(){for(int i=0;i<ameditor::count;++i)if(GetFocus()==numbers[i] || (ameditor::controls[i].kind==ameditor::text && GetFocus()==controls[i]))fieldChanged(i);}
  void update(const Json& next,bool disabled,HWND anchor){
    bool wasOpen=state.value("open",false),focus=state.value("focus",0)!=next.value("focus",0),changed=state.value("id","")!=next.value("id","");Json previous=state;
    updating=true;if(changed && window)SetFocus(tabs);state=next;paused=disabled;
    if(!next.value("open",false)){close(false);updating=false;return;}
    bool created=!window;if(!window && (!wasOpen || focus))create(anchor);if(!window){updating=false;return;}
    bool raw=next.at("id")=="raw",zwicker=next.at("values").at("metric")!="lufs_m_max";
    bool presetsChanged=created || !previous.contains("presets") || previous.at("presets")!=next.at("presets");
    int index=0;for(const auto& p:next.at("presets")){
      if(presetsChanged){presetLabels[index]=amwin::wide(p.at("label"));SetWindowTextW(presets[index],presetLabels[index].c_str());
        TOOLINFOW tip{sizeof(tip)};tip.hwnd=window;tip.uId=reinterpret_cast<UINT_PTR>(presets[index]);tip.lpszText=presetLabels[index].data();SendMessageW(presetTips,TTM_UPDATETIPTEXTW,0,reinterpret_cast<LPARAM>(&tip));}
      EnableWindow(presets[index],!paused);SendMessageW(presets[index],BM_SETCHECK,p.at("id")==next.at("id")?BST_CHECKED:BST_UNCHECKED,0);++index;
    }
    for(HWND w:{save,revert,play,replay,ab})EnableWindow(w,!paused);EnableWindow(fx,!paused && !raw);
    amwin::text(play,next.at("playing").get<bool>()?"Stop":"Play");amwin::text(saved,next.at("dirty").get<bool>()?"Unsaved changes — auditioning live":"Saved");amwin::text(source,next.at("source"));
    for(int i=0;i<ameditor::count;++i){const auto& s=ameditor::controls[i];bool enabled=!paused && ameditor::enabled(s,raw,zwicker);EnableWindow(controls[i],enabled);const auto& value=next.at("values").at(s.key);
      if(s.kind==ameditor::toggle)SendMessageW(controls[i],BM_SETCHECK,value.get<bool>()?BST_CHECKED:BST_UNCHECKED,0);
      else if(s.kind==ameditor::choice){for(int k=0;k<3;++k)if(value==ameditor::metrics[k])SendMessageW(controls[i],CB_SETCURSEL,k,0);}
      else if(s.kind==ameditor::text){if(GetFocus()!=controls[i])amwin::text(controls[i],value);}
      else {EnableWindow(numbers[i],enabled);if(GetFocus()!=numbers[i] && GetCapture()!=controls[i]){double n=value;int scale=!strcmp(s.key,"slot")?1:100;SendMessageW(controls[i],TBM_SETPOS,TRUE,static_cast<int>(std::round(n*scale)));char text[64];std::snprintf(text,sizeof(text),!strcmp(s.key,"slot")?"%.0f":"%.2f",n);amwin::text(numbers[i],text);}}
    }
    index=0;for(const auto& s:ameditor::actions){bool enabled=!paused && (!s.macroOnly || !raw);if(!strcmp(s.op,"new") || !strcmp(s.op,"duplicate"))enabled=enabled && next.at("presets").size()<10;EnableWindow(actions[index++],enabled);}
    if(amwin::text(measurement)!=amwin::wide(next.at("measurement")))amwin::text(measurement,next.at("measurement"));
    amwin::text(notice,paused?"Paused — return to the attached project to edit.":next.at("notice").get<std::string>());
    if(!wasOpen || focus){if(next.at("page").get<int>()>=0)selected=next.at("page").get<int>();TabCtrl_SetCurSel(tabs,selected);layout();ShowWindow(window,SW_SHOW);SetForegroundWindow(window);SetFocus(tabs);}
    else if(presetsChanged || previous.value("deleting",false)!=next.at("deleting").get<bool>())layout();
    updating=false;
  }
  void close(bool notify){
    if(!window || closing)return;if(notify){commitFocused();enqueue("editor:close");}closing=true;
    HWND old=window;window=nullptr;if(presetTips)DestroyWindow(presetTips);presetTips=nullptr;DestroyWindow(old);presets.fill(nullptr);children.clear();controls.fill(nullptr);numbers.fill(nullptr);actions.clear();if(font)DeleteObject(font);font=nullptr;closing=false;
  }
  static LRESULT CALLBACK keyProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR data){
    auto self=reinterpret_cast<EditorPanel*>(data);if(m==WM_NCDESTROY)RemoveWindowSubclass(w,keyProc,1);
    if(m==WM_SETFOCUS)self->reveal(w);
    if(m==WM_KEYDOWN){
      if(p==VK_ESCAPE){self->close(true);return 0;}
      if(p==VK_TAB){HWND next=GetNextDlgTabItem(self->window,w,(GetKeyState(VK_SHIFT)&0x8000)!=0);if(next)SetFocus(next);return 0;}
      if(p=='A' && (GetKeyState(VK_CONTROL)&0x8000)){wchar_t cls[32]{};GetClassNameW(w,cls,32);if(!wcscmp(cls,L"Edit")){SendMessageW(w,EM_SETSEL,0,-1);return 0;}}
      if(p==VK_RETURN){wchar_t cls[32]{};GetClassNameW(w,cls,32);if(!wcscmp(cls,L"Edit")){self->commitFocused();return 0;}if(!wcscmp(cls,L"Button")){SendMessageW(w,BM_CLICK,0,0);return 0;}}
    }return DefSubclassProc(w,m,p,l);
  }
  static LRESULT CALLBACK proc(HWND w,UINT m,WPARAM p,LPARAM l){
    auto self=reinterpret_cast<EditorPanel*>(GetWindowLongPtrW(w,GWLP_USERDATA));
    if(m==WM_NCCREATE){self=static_cast<EditorPanel*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
    if(!self)return DefWindowProcW(w,m,p,l);
    if(m==WM_CLOSE){self->close(true);return 0;}
    if(m==WM_MOUSEWHEEL){self->scrollTo(self->scrollOffset-static_cast<short>(HIWORD(p))/WHEEL_DELTA*48);return 0;}
    if(m==WM_VSCROLL){SCROLLINFO info{sizeof(info),SIF_ALL};GetScrollInfo(w,SB_VERT,&info);int n=self->scrollOffset;
      switch(LOWORD(p)){case SB_LINEUP:n-=24;break;case SB_LINEDOWN:n+=24;break;case SB_PAGEUP:n-=info.nPage;break;case SB_PAGEDOWN:n+=info.nPage;break;case SB_THUMBTRACK:n=info.nTrackPos;break;case SB_TOP:n=0;break;case SB_BOTTOM:n=700+self->presetOffset;break;}self->scrollTo(n);return 0;}
    if(m==WM_DPICHANGED){auto r=reinterpret_cast<RECT*>(l);SetWindowPos(w,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER|SWP_NOACTIVATE);self->layout();return 0;}
    if(m==WM_NOTIFY && reinterpret_cast<NMHDR*>(l)->hwndFrom==self->tabs && reinterpret_cast<NMHDR*>(l)->code==TCN_SELCHANGE){self->selected=TabCtrl_GetCurSel(self->tabs);self->layout();return 0;}
    try{
      if(m==WM_HSCROLL){for(int i=0;i<ameditor::count;++i)if(reinterpret_cast<HWND>(l)==self->controls[i]){const auto& s=ameditor::controls[i];double n=SendMessageW(self->controls[i],TBM_GETPOS,0,0)/(!strcmp(s.key,"slot")?1.0:100.0);char text[64];std::snprintf(text,sizeof(text),!strcmp(s.key,"slot")?"%.0f":"%.2f",n);amwin::text(self->numbers[i],text);self->event({{"op","set"},{"key",s.key},{"value",n}});return 0;}}
      if(m==WM_COMMAND){int id=LOWORD(p),code=HIWORD(p);if(self->updating)return 0;
        if(id>=4400 && id<4400+static_cast<int>(self->presets.size()) && code==BN_CLICKED){int index=id-4400;
          if(!self->paused && index<static_cast<int>(self->state.at("presets").size())){SetFocus(self->presets[index]);self->event({{"op","select"},{"value",self->state.at("presets").at(index).at("id")}});}}
        else if(id>=4200 && id<4200+ameditor::count && code==EN_KILLFOCUS)self->fieldChanged(id-4200);
        else if(id>=4100 && id<4100+ameditor::count){int i=id-4100;const auto& s=ameditor::controls[i];
          if(s.kind==ameditor::text && code==EN_KILLFOCUS)self->fieldChanged(i);
          else if(s.kind==ameditor::toggle && code==BN_CLICKED)self->event({{"op","set"},{"key",s.key},{"value",SendMessageW(self->controls[i],BM_GETCHECK,0,0)==BST_CHECKED}});
          else if(s.kind==ameditor::choice && code==CBN_SELCHANGE){int k=static_cast<int>(SendMessageW(self->controls[i],CB_GETCURSEL,0,0));if(k>=0 && k<3)self->event({{"op","set"},{"key",s.key},{"value",ameditor::metrics[k]}});}
        }else if(code==BN_CLICKED){self->commitFocused();if(id==4009)self->close(true);
          else if(id>=4001 && id<=4007){const char* op[]={"save","revert","fx","play","replay","ab","focus"};self->event({{"op",op[id-4001]}});}
          else if(id>=4300 && id<4300+static_cast<int>(self->actions.size()))self->event({{"op",ameditor::actions[id-4300].op}});
        }return 0;
      }
    }catch(...){}return DefWindowProcW(w,m,p,l);
  }
};
