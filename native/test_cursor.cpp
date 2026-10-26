#include "cursor.cpp"
#include <cassert>
#include <iostream>
#include <string>
#ifdef _WIN32
#include <fstream>
#endif
static int storage[4],state=1,paints=0,unlinks=0,timers=0;
static bool shown=true,exists=true,native_file=true;
static int native_selection=0;
static double fraction=.5,position=6,length=12;
static int scrollbar_at=0,scrollbar_page=800,scrollbar_max=800;
static std::string label="0:00.000  /  0:12.000",file="/test.wav";
extern "C" int AMPreviewWavePosition(char* path,int size,double* f,double* p,double* l) {
  std::snprintf(path,size,"/test.wav");*f=fraction;*p=position;*l=length;return state;
}
static int peak_reads=0,peak_opens=0,peak_closes=0,build_steps=0;
static std::vector<int> painted_channels;
static std::vector<std::string> painted_labels;
static int requested_font_height=0;
static int fonts_created=0,fonts_destroyed=0,gdi_created=0,gdi_destroyed=0;
// Deliberately emulate Windows COLORREF packing even on macOS.
static std::map<std::string,int> theme={{"col_mi_bg2",0x918171},{"col_tr1_peaks",0x403020},
  {"col_mi_label",0x302010},{"playcursor_color",0x80c020},{"col_explorer_sel",0xe0d0c0},{"col_explorer_seldm",0x26600}};
struct Fill {int x,y,w,h,color;double alpha;std::string mode;};
static std::vector<Fill> fills;
static std::vector<int> cleared_colors;
static int composite_width=0,composite_source_width=0,allocated_width=0;
static int viewport_syncs=0;
static bool stale_scroll=false;
#ifndef _WIN32
static int backing_scale=1;
extern "C" int AMWavePixelScale(void*){return backing_scale;}
#endif
extern "C" bool AMDrawWaveLabel(void*,const char*,int,int,int,int,unsigned int,unsigned int,int,void*(*)(const char*)){return false;}
class Peaks final:public PCM_source {
public:
  PCM_source* Duplicate()override{return new Peaks;}
  bool IsAvailable()override{return true;}
  const char* GetType()override{return "WAVE";}
  bool SetFileName(const char*)override{return false;}
  int GetNumChannels()override{return 6;}
  double GetSampleRate()override{return 48000;}
  double GetLength()override{return 12;}
  int PropertiesWindow(HWND)override{return 0;}
  void GetSamples(PCM_source_transfer_t*)override{}
  void GetPeakInfo(PCM_source_peaktransfer_t*)override{}
  void SaveState(ProjectStateContext*)override{}
  int LoadState(const char*,ProjectStateContext*)override{return 0;}
  void Peaks_Clear(bool)override{}
  int PeaksBuild_Begin()override{return 1;}
  int PeaksBuild_Run()override{return ++build_steps<2;}
  void PeaksBuild_Finish()override{}
};
static void* api(const char* name) {
  if(!std::strcmp(name,"BR_Win32_SendMessage"))return reinterpret_cast<void*>(+[](void*,unsigned message,std::uintptr_t wp,std::intptr_t lp)->std::intptr_t{
    assert(message==0x5 && wp==0 && lp==((100<<16)|800));++viewport_syncs;
    if(stale_scroll){scrollbar_at=200;scrollbar_page=400;scrollbar_max=800;stale_scroll=false;}
    return 0;
  });
  if(!std::strcmp(name,"GetThemeColor"))return reinterpret_cast<void*>(+[](const char* key,int flags){assert(flags==0);auto i=theme.find(key);return i==theme.end()?-1:i->second;});
  if(!std::strcmp(name,"ColorFromNative"))return reinterpret_cast<void*>(+[](int value,int* r,int* g,int* b){*r=value&255;*g=(value>>8)&255;*b=(value>>16)&255;});
  if(!std::strcmp(name,"JS_LICE_CreateFont"))return reinterpret_cast<void*>(+[]()->void*{++fonts_created;return &storage[3];});
  if(!std::strcmp(name,"JS_LICE_DestroyFont"))return reinterpret_cast<void*>(+[](void*){++fonts_destroyed;});
  if(!std::strcmp(name,"JS_GDI_CreateFont"))return reinterpret_cast<void*>(+[](int height,int,int,bool,bool,bool,const char*)->void*{requested_font_height=height;++gdi_created;return &storage[3];});
  if(!std::strcmp(name,"JS_GDI_DeleteObject"))return reinterpret_cast<void*>(+[](void*){++gdi_destroyed;});
  if(!std::strcmp(name,"LICE__SetFromHFont"))return reinterpret_cast<void*>(+[](void*,void*,int flags){assert(flags==0);});
  if(!std::strcmp(name,"LICE__SetTextColor") || !std::strcmp(name,"LICE__SetBkColor"))return reinterpret_cast<void*>(+[](void*,unsigned int)->unsigned int{return 0;});
  if(!std::strcmp(name,"JS_LICE_DrawText"))return reinterpret_cast<void*>(+[](void*,void*,const char* text,int size,int x,int y,int right,int bottom){assert(x==static_cast<int>(std::lround(8*label_dpi/96.0)) && right==allocated_width-x && bottom>y);painted_labels.emplace_back(text,size);return 12;});
  if(!std::strcmp(name,"PCM_Source_CreateFromFile"))return reinterpret_cast<void*>(+[](const char*)->PCM_source*{++peak_opens;return new Peaks;});
  if(!std::strcmp(name,"PCM_Source_Destroy"))return reinterpret_cast<void*>(+[](PCM_source* src){++peak_closes;delete src;});
  if(!std::strcmp(name,"PCM_Source_GetPeaks"))return reinterpret_cast<void*>(+[](PCM_source*,double rate,double start,int channels,int count,int,double* values){
    ++peak_reads;assert(rate>0 && start>=0 && channels==6);
    for(int i=0;i<count;++i)for(int c=0;c<channels;++c){values[i*channels+c]=(c+1)*.1;values[(count+i)*channels+c]=-(c+1)*.1;}
    return count;
  });
  if(!std::strcmp(name,"JS_LICE_FillRect"))return reinterpret_cast<void*>(+[](void*,int x,int y,int w,int h,int color,double alpha,const char* mode){
    fills.push_back({x,y,w,h,color,alpha,mode});
    if(w==1 && color==theme_pixel("col_tr1_peaks",0xff404040))painted_channels.push_back(h);
  });
  if(!std::strcmp(name,"JS_LICE_DrawChar"))return reinterpret_cast<void*>(+[](void*,int,int,char,int,double,const char* mode){assert(!std::strcmp(mode,"COPY"));});
  if(!std::strcmp(name,"JS_Window_IsWindow"))return reinterpret_cast<void*>(+[](void*){return exists;});
  if(!std::strcmp(name,"JS_Window_IsVisible"))return reinterpret_cast<void*>(+[](void*){return shown;});
  if(!std::strcmp(name,"JS_Window_GetClientSize"))return reinterpret_cast<void*>(+[](void*,int* w,int* h){*w=800;*h=100;return true;});
  if(!std::strcmp(name,"JS_Window_InvalidateRect"))return reinterpret_cast<void*>(+[](void*,int l,int t,int r,int b,bool){assert(l>=0 && t==0 && r<=800 && b==100);return true;});
  if(!std::strcmp(name,"JS_Window_GetScrollInfo"))return reinterpret_cast<void*>(+[](void*,const char*,int* p,int* page,int* min,int* max,int* track){*p=scrollbar_at;*page=scrollbar_page;*max=scrollbar_max;*min=*track=0;return true;});
  if(!std::strcmp(name,"JS_Window_GetTitle"))return reinterpret_cast<void*>(+[](void*,char* out,int size){std::snprintf(out,size,"%s",label.c_str());});
  if(!std::strcmp(name,"JS_Window_SetTitle"))return reinterpret_cast<void*>(+[](void*,const char* t){label=t;return true;});
  if(!std::strcmp(name,"JS_LICE_CreateBitmap"))return reinterpret_cast<void*>(+[](bool,int width,int)->void*{allocated_width=width;return &storage[2];});
  if(!std::strcmp(name,"JS_LICE_DestroyBitmap"))return reinterpret_cast<void*>(+[](void*){});
  if(!std::strcmp(name,"JS_LICE_Clear"))return reinterpret_cast<void*>(+[](void*,int color){cleared_colors.push_back(color);});
  if(!std::strcmp(name,"JS_Composite"))return reinterpret_cast<void*>(+[](void*,int,int,int w,int,void*,int,int,int sw,int,bool automatic){assert(!automatic);composite_width=w;composite_source_width=sw;++paints;return 1;});
  if(!std::strcmp(name,"JS_Composite_Unlink"))return reinterpret_cast<void*>(+[](void*,void*,bool){++unlinks;});
  if(!std::strcmp(name,"MediaExplorerGetLastPlayedFileInfo"))return reinterpret_cast<void*>(+[](char* path,int size,int* mode,double* a,double* b,double*,double*,double*,double*,char*,int){std::snprintf(path,size,"%s",file.c_str());*mode=native_selection;*a=.25;*b=.75;return native_file;});
  if(!std::strcmp(name,"GetToggleCommandStateEx"))return reinterpret_cast<void*>(+[](int,int){return 0;});
  return nullptr;
}
#ifdef _WIN32
static void test_font_raster() {
  // Verify real Windows font metrics as well as the stubbed rendering calls.
  constexpr int width=1200,height=560;
  HDC dc=CreateCompatibleDC(nullptr);assert(dc);
  BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=width;
  info.bmiHeader.biHeight=height;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
  void* pixels=nullptr;HBITMAP bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&pixels,nullptr,0);assert(bitmap && pixels);
  auto old_bitmap=SelectObject(dc,bitmap);std::fill_n(static_cast<unsigned int*>(pixels),width*height,0xffeeeeeeu);
  SetTextColor(dc,RGB(32,32,32));SetBkColor(dc,RGB(238,238,238));
  int row=0;
  for(int dpi:{96,120,144,192,288}) {
    const int font_pixels=MulDiv(13,dpi,96),box=MulDiv(22,dpi,96),top=20+row++*108;
    HFONT old_font=CreateFontW(11,0,0,0,400,FALSE,FALSE,FALSE,ANSI_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Yu Gothic UI");
    HFONT font=CreateFontW(-font_pixels,0,0,0,400,FALSE,FALSE,FALSE,ANSI_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Yu Gothic UI");
    assert(font && old_font);auto previous=SelectObject(dc,font);TEXTMETRICW metrics{};assert(GetTextMetricsW(dc,&metrics));
    assert(metrics.tmHeight<=box && metrics.tmHeight-metrics.tmInternalLeading>=font_pixels-1);
    RECT bounds{500,top,1180,top+box};DrawTextW(dc,L"Mono ch 1  Boom & 風鈴",-1,&bounds,DT_SINGLELINE|DT_NOPREFIX);
    SelectObject(dc,old_font);bounds={20,top,480,top+30};
    const std::wstring label=std::to_wstring(MulDiv(dpi,100,96))+L"%  old: Mono ch 1  Boom & 風鈴";
    DrawTextW(dc,label.c_str(),-1,&bounds,DT_SINGLELINE|DT_NOPREFIX);
    SelectObject(dc,previous);DeleteObject(old_font);DeleteObject(font);
  }
  GdiFlush();BITMAPFILEHEADER header{};header.bfType=0x4d42;header.bfOffBits=sizeof(header)+sizeof(BITMAPINFOHEADER);header.bfSize=header.bfOffBits+width*height*4;
  std::ofstream out("wave-label-fonts.bmp",std::ios::binary);assert(out);
  out.write(reinterpret_cast<const char*>(&header),sizeof(header));out.write(reinterpret_cast<const char*>(&info.bmiHeader),sizeof(info.bmiHeader));out.write(static_cast<const char*>(pixels),width*height*4);assert(out);
  SelectObject(dc,old_bitmap);DeleteObject(bitmap);DeleteDC(dc);
}
#endif
int main() {
#ifdef _WIN32
  test_font_raster();
#endif
  AMCursorRegister(+[](const char* name,void*){timers+=*name=='-'?-1:1;return 1;});
  assert(AMCursorAttach(&storage[0],&storage[1],api));tick();
  assert(paints==1 && last_x==400 && label=="0:06.000  /  0:12.000" && timers==1);
  tick();assert(paints==1); // No repaint/allocations when position is unchanged.
  AMCursorRestoreClock();assert(label=="0:00.000  /  0:12.000");
  label="0:03.000  /  0:12.000";tick();AMCursorRestoreClock();assert(label=="0:03.000  /  0:12.000");
  // A native range drag must own the entire waveform, including repainting.
  // Pausing cursor movement alone leaves the old composite over its selection.
  AMCursorSuspend(true);assert(!linked);const int before_drag=paints;
  fraction=.75;tick();assert(!linked && paints==before_drag);
  label="native range drag";tick();assert(label=="native range drag" && paints==before_drag);
  label="0:03.000  /  0:12.000";
  AMCursorSuspend(false);tick();assert(last_x==600);
  state=-1;fraction=.2;tick();assert(last_x==600);state=0;tick();assert(last_x==600);
  file="/different.wav";tick();assert(!linked && unlinks==2 && label=="0:03.000  /  0:12.000");
  file="/test.wav";state=1;tick();shown=false;tick();assert(!linked);shown=true;tick();
  label="native changed it";AMCursorDetach();assert(label=="native changed it" && timers==0);
  assert(pixel(.5,200,400,0,800,800)==400 && pixel(.1,200,400,0,800,800)<0);
  assert(pixel(.5,0,0,0,800,800)==-999999);
  // Scroll endpoints are signed ints; their difference need not fit an int.
  // A page spanning half the file maps its quarter point to half the width.
  assert(pixel(.5,std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),
    std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),800)==800);
  assert(pixel(.25,std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),
    std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),800)==400);
  assert(pixel(1e100,0,1,0,800,800)==-999999);
  assert(pixel(NAN,0,800,0,800,800)==-999999);
  // Independently scale scroll units and pixels, including zoom and scrolling.
  assert(AMCursorAttach(&storage[0],&storage[1],api));fraction=.5;
  scrollbar_max=scrollbar_page=1600;tick();assert(last_x==400);
  scrollbar_at=400;scrollbar_page=800;tick();assert(last_x==400);
  fraction=.1;tick();assert(!linked);
  fraction=.75;scrollbar_at=0;scrollbar_page=1600;
  AMCursorZoom(42093);tick();assert(last_x==600 && view_width==800 && view_units==1600);
  // Selected peaks stay visible while stopped; requests and cursor movement
  // never reopen/re-read a source unless the viewport or file identity changes.
  state=0;*last_path=0;
  assert(AMWaveSetChannels("/test.wav",5,2,"v1"));tick();tick();
  assert(peak_linked && peak_count==800 && peak_reads==2 && peak_opens==1);
  assert(painted_channels[0]>painted_channels[800]);
  assert(cleared_colors.back()==static_cast<int>(0xff718191));
  assert(peak_style.peaks==static_cast<int>(0xff203040) && peak_style.text==static_cast<int>(0xff102030));
  int reads=peak_reads,paints_before=paints;
  assert(AMWaveSetChannels("/test.wav",5,2,"v1"));tick();assert(peak_reads==reads && paints==paints_before);
  // Theme edits repaint a stopped preview without reopening or re-reading PCM.
  theme["col_mi_bg2"]=0x181818;tick();assert(peak_reads==reads && paints==paints_before+1);
  assert(cleared_colors.back()==static_cast<int>(0xff181818));
  paints_before=paints;tick();assert(paints==paints_before);
  // A range tints the finished waveform, not only the empty background.
  fills.clear();assert(paint_peaks("/test.wav",800,100,0,1,.25,.75,-999999,wave_style()));
  const auto selection=fills.back();
  assert(selection.x==200 && selection.w==400 && selection.color==static_cast<int>(0xffc0d0e0));
  assert(selection.alpha==102.0/256 && selection.mode=="COPY");
  theme["col_explorer_seldm"]=0x28003;fills.clear();tick();
  assert(paint_peaks("/test.wav",800,100,0,1,.25,.75,-999999,wave_style()));
  assert(fills.back().mode=="MUL" && fills.back().alpha==.5 && peak_reads==reads);
  theme["col_explorer_seldm"]=0x26600;
  // Both native selection flags tint selected channels and anchor zoom.
  for(int flag:{128,256,384}) {
    native_selection=flag;fills.clear();tick();
    assert(peak_a==.25 && peak_b==.75);
    AMCursorZoom(42092);
    assert(std::abs(view_start-.225)<1e-9 && std::abs(view_span-.55)<1e-9);
    AMCursorZoom(42093);
  }
  native_selection=0;tick();
  state=1;fraction=.25;tick();fraction=.3;tick();assert(peak_reads==reads);
  // Native selection feedback is transient during the modal Windows mouse
  // loop. A full opaque channel overlay must not hide it, even if the timer
  // runs while the audio thread holds its lock or the source changes.
  for(int playing:{1,0,-1}) {
    state=playing;const int before=paints,opened=peak_opens;
    AMCursorSuspend(true);assert(!linked && !peak_linked);
    AMCursorSuspend(true); // Repeated suspend must not clear source ownership.
    fraction=.6;tick();tick();
    assert(!linked && !peak_linked && paints==before && peak_reads==reads && peak_opens==opened);
    assert(peak_source && peak_channels==std::vector<int>({5,2}));
    AMCursorSuspend(false);state=1;tick();
    assert(peak_linked && peak_reads==reads && peak_opens==opened && peak_cursor==480);
  }
  assert(AMWaveSetChannels("/test.wav",4,4,"v1"));painted_channels.clear();tick();
  assert(painted_channels.size()==800 && peak_left==peak_right && peak_opens==1);
  scrollbar_at=400;scrollbar_page=800;tick();assert(peak_start==.25 && peak_span==.5);
  file="/different.wav";tick();assert(!peak_linked);
  file="/test.wav";tick();assert(peak_linked);
  shown=false;tick();assert(!peak_linked);shown=true;tick();assert(peak_linked);
  assert(!AMWaveSetChannels("/test.wav",7,7,"v1"));assert(peak_left==4);
  assert(AMWaveSetChannels("/test.wav",1,2,"v2"));tick();assert(peak_opens==2 && peak_closes==1);
  assert(AMWaveSetChannelSubset("/test.wav","1,3,5","v2"));painted_channels.clear();tick();
  assert(peak_channels==std::vector<int>({1,3,5}) && painted_channels.size()==2400);
  assert(painted_channels[0]<painted_channels[800] && painted_channels[800]<painted_channels[1600]);
  assert(std::strstr(AMCursorState(),"\"selected_lanes\":3"));
  const char* names=R"(["Boom & L","","風鈴 🎤","Spare","Room ##R",""])";
  int before_names=peak_reads;painted_labels.clear();
  assert(AMWaveSetChannelNames("/test.wav","v2",names));tick();
  assert(peak_reads==before_names && painted_labels==std::vector<std::string>({"Input ch 1  Boom & L","Input ch 3  風鈴 🎤","Input ch 5  Room ##R"}));
  paints_before=paints;assert(AMWaveSetChannelNames("/test.wav","v2",names));tick();assert(paints==paints_before);
  for(const char* bad:{"{}","[42]","[]","[1,2,3,4,5,6]","[\"bad\\nname\",\"\",\"\",\"\",\"\",\"\"]"})assert(!AMWaveSetChannelNames("/test.wav","v2",bad));
  assert(!AMWaveSetChannelNames("/other.wav","v2",names) && !AMWaveSetChannelNames("/test.wav","old",names));
  assert(AMWaveSetChannels("/test.wav",5,2,"v2"));painted_labels.clear();tick();
  assert(painted_labels==std::vector<std::string>({"L ch 5  Room ##R","R ch 2"}));
  assert(AMWaveSetChannels("/test.wav",3,3,"v2"));painted_labels.clear();tick();assert(painted_labels[0]=="Mono ch 3  風鈴 🎤");
  native_file=false;tick();assert(peak_linked && peak_channels==std::vector<int>({3}));native_file=true;
  for(const char* bad:{"","1,1","1,7","1,","0","129","1;3","3,2,1"})
    assert(!AMWaveSetChannelSubset("/test.wav",bad,"v2"));
  assert(AMWaveSetChannels("",0,0,""));assert(!peak_linked && !peak_source && peak_closes==2);
  assert(AMWaveSetChannels("/test.wav",1,1,"v3"));AMCursorDetach();assert(peak_closes==3 && !peak_bitmap);
  assert(fonts_created==1 && fonts_destroyed==1 && gdi_created==gdi_destroyed);
#ifndef _WIN32
  backing_scale=2;state=1;fraction=.5;scrollbar_at=0;scrollbar_page=scrollbar_max=800;
  assert(AMCursorAttach(&storage[0],&storage[1],api));assert(AMWaveSetChannels("/test.wav",3,3,"retina"));tick();
  assert(peak_count==1600 && composite_width==800 && composite_source_width==1600);
  assert(last_x==400 && peak_cursor==800 && peak_height==156);
  reads=peak_reads;tick();assert(peak_reads==reads);
  backing_scale=1;tick();assert(peak_count==800 && peak_cursor==400 && peak_reads==reads+1);
  // Native menu/wheel zoom can leave CoolSB stale until the unchanged size is
  // reapplied. Refresh only after input, then use the updated position/page.
  stale_scroll=true;int syncs=viewport_syncs;AMCursorViewportChanged();tick();
  assert(viewport_syncs==syncs+1 && peak_start==.25 && peak_span==.5 && peak_cursor==400);
  tick();assert(viewport_syncs==syncs+1);
  AMCursorDetach();assert(fonts_created==fonts_destroyed && gdi_created==gdi_destroyed);
#endif
#ifdef _WIN32
  // A monitor change recreates fonts and repaints labels without re-decoding
  // the waveform. Include fractional desktop scaling and a missing-DPI fallback.
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  assert(AMWaveSetChannels("/test.wav",1,1,"dpi"));
  tick();tick();
  const auto saved_dpi=window_dpi;
  for(unsigned int dpi:{96u,120u,144u,192u,288u,0u,96u}) {
    static unsigned int value;value=dpi;window_dpi=+[](void*){return value;};
    const int before=peak_reads;tick();
    assert(requested_font_height==-static_cast<int>(std::lround(13*(dpi?dpi:96)/96.0)));
    assert(peak_width==800 && composite_width==800 && composite_source_width==800);
    assert(peak_reads==before);
    const int made=gdi_created,painted=paints;tick();
    assert(gdi_created==made && paints==painted);
  }
  window_dpi=saved_dpi;AMCursorDetach();
  assert(fonts_created==fonts_destroyed && gdi_created==gdi_destroyed);
#endif
  theme.clear();assert(wave_style().background==static_cast<int>(0xffcccccc));
  assert(wave_style().selection_mode==0x26600);
  std::cout<<"PASS: cursor mapping, unchanged-frame budget, clock ownership, pause, hidden/stale sources, detach\n";
}
