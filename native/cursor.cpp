#include "path_equal.h"
#include "channel_subset.h"
#include "vendor/json.hpp"
// Overlay selected source peaks and the playhead without intercepting gestures.
// REAPER continues to own the ruler, zoom, range, scrollbar and drag source.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
#include <string>
#include "reaper_audio_abi.h"

extern "C" int AMPreviewWavePosition(char*,int,double*,double*,double*);
#ifndef _WIN32
extern "C" int AMWavePixelScale(void*);
#endif
extern "C" bool AMDrawWaveLabel(void*,const char*,int,int,int,int,unsigned int,unsigned int,int,void*(*)(const char*));
namespace {
void*(*font_lookup)(const char*);
void *wave=nullptr,*clock_view=nullptr,*bitmap=nullptr;
int (*host_register)(const char*,void*);
bool (*window_valid)(void*),(*visible)(void*);
bool (*scroll_info)(void*,const char*,int*,int*,int*,int*,int*);
bool (*client_size)(void*,int*,int*),(*invalidate)(void*,int,int,int,int,bool);
std::intptr_t (*send_message)(void*,unsigned,std::uintptr_t,std::intptr_t);
bool viewport_dirty=true;
void (*get_title)(void*,char*,int);
bool (*set_title)(void*,const char*);
void* (*create_bitmap)(bool,int,int);
void (*destroy_bitmap)(void*),(*clear_bitmap)(void*,int);
int (*composite)(void*,int,int,int,int,void*,int,int,int,int,bool);
void (*unlink_bitmap)(void*,void*,bool);
bool (*file_info)(char*,int,int*,double*,double*,double*,double*,double*,double*,char*,int);
int (*toggle)(int,int);
int (*theme_color)(const char*,int);
void (*color_from_native)(int,int*,int*,int*);
struct WaveStyle {
  int background,peaks,text,cursor,selection,selection_mode;
  bool operator==(const WaveStyle& s)const {
    return background==s.background && peaks==s.peaks && text==s.text && cursor==s.cursor &&
      selection==s.selection && selection_mode==s.selection_mode;
  }
};
WaveStyle peak_style{};
int cursor_color=0;
int theme_pixel(const char* key,unsigned int fallback) {
  const int value=theme_color?theme_color(key,0):-1;
  if(value==-1 || !color_from_native)return static_cast<int>(fallback);
  int r=0,g=0,b=0;color_from_native(value,&r,&g,&b);
  return static_cast<int>(0xff000000u|((r&255)<<16)|((g&255)<<8)|(b&255));
}
WaveStyle wave_style() {
  // Media Explorer uses the unselected media-item colors for every channel.
  // Convert native colors through REAPER: Windows and macOS pack RGB differently.
  const int mode=theme_color?theme_color("col_explorer_seldm",0):-1;
  return {theme_pixel("col_mi_bg2",0xffcccccc),theme_pixel("col_tr1_peaks",0xff404040),
    theme_pixel("col_mi_label",0xff202020),theme_pixel("playcursor_color",0xff000000),
    theme_pixel("col_explorer_sel",0xffffffff),mode==-1?0x26600:mode};
}
bool linked=false,registered=false,suspended=false;
int last_x=-999999;
char native_clock[256]{},written_clock[256]{},last_path[4096]{};
double last_fraction=-1,last_position=0,last_length=0;
double view_start=0,view_span=0;
int view_at=-1,view_page=-1,view_width=-1;
double view_units=-1;
int actual_width=0,scroll_at=0,scroll_page=0,scroll_min=0,scroll_max=0;
char view_path[4096]{};

PCM_source* peak_source=nullptr;
PCM_source* (*open_source)(const char*);
void (*close_source)(PCM_source*);
int (*get_peaks)(PCM_source*,double,double,int,int,int,double*);
void (*fill_rect)(void*,int,int,int,int,int,double,const char*);
void (*draw_char)(void*,int,int,char,int,double,const char*);
void* (*create_font)();
void* (*gdi_font)(int,int,int,bool,bool,bool,const char*);
void (*destroy_font)(void*),(*delete_gdi)(void*),(*set_font)(void*,void*,int);
unsigned int (*font_color)(void*,unsigned int),(*font_background)(void*,unsigned int);
int (*draw_text)(void*,void*,const char*,int,int,int,int,int);
void *label_font=nullptr,*label_gdi=nullptr;
int label_dpi=0,label_font_height=0,peak_label_dpi=0,peak_scale=0;
#ifdef _WIN32
unsigned int (*window_dpi)(void*)=+[](void* window){return GetDpiForWindow(static_cast<HWND>(window));};
#endif
void* peak_bitmap=nullptr;
std::vector<std::string> peak_names;
std::string peak_names_json;
bool labels_dirty=true,label_native=false;
std::string peak_path,peak_stamp;
std::vector<double> peak_values;
std::vector<int> peak_channels;
int peak_left=0,peak_right=0,peak_width=0,peak_height=0,peak_count=0,peak_cursor=-999999;
double peak_start=-1,peak_span=-1,peak_a=-1,peak_b=-1;
bool peak_linked=false,peak_building=false,peak_dirty=true;

void hide_peaks() {
  if(peak_linked && wave && window_valid(wave))unlink_bitmap(wave,peak_bitmap,true);
  peak_linked=false;
}
void clear_peaks() {
  hide_peaks();
  if(peak_source) {
    if(peak_building)peak_source->PeaksBuild_Finish();
    close_source(peak_source);peak_source=nullptr;
  }
  if(peak_bitmap){destroy_bitmap(peak_bitmap);peak_bitmap=nullptr;}
  peak_path.clear();peak_stamp.clear();peak_values.clear();peak_channels.clear();peak_names.clear();peak_names_json.clear();labels_dirty=true;peak_left=peak_right=peak_count=0;
  peak_width=peak_height=0;peak_start=peak_span=-1;peak_building=false;peak_dirty=true;
}
void viewport(const char* path,int at,int page,int minimum,int maximum,int width,double& start,double& span) {
  const double units=static_cast<double>(maximum)-minimum;
  start=units>0?(static_cast<double>(at)-minimum)/units:0;
  span=units>0 && page>0?std::min(1.0,page/units):1;
  if(view_at>=0 && units==view_units && page!=view_page)view_span=0;
  if(view_span>0 && am_path_equal(path,view_path) && width>0 && units>0 && std::abs(page-view_span*units)<=2) {
    if(view_at>=0 && at!=view_at)view_start=start;
    start=view_start;span=view_span;
    view_at=at;view_page=page;view_width=width;view_units=units;
  } else if(view_at>=0 && (page!=view_page || units!=view_units))view_span=0;
}
bool paint_peaks(const char* path,int width,int height,double start,double span,double a,double b,int cursor,const WaveStyle& style) {
  if(!peak_source || !am_path_equal(path,peak_path.c_str()) || width<1 || width>16384 || height<24 || height>4096) {
    hide_peaks();return false;
  }
  // Reserve REAPER's time ruler at the bottom; all coordinates are client units.
#ifdef _WIN32
  const int ruler_height=16;
#else
  const int ruler_height=22;
#endif
  const int client_width=width,client_height=height-ruler_height;
#ifdef _WIN32
  const int scale_factor=1; // Win32 client coordinates are already device pixels.
#else
  const int scale_factor=AMWavePixelScale(wave);
#endif
  // Bitmap pixels and UI font sizing are independent on Windows: the client
  // is already in device pixels, but readable text must follow its monitor DPI.
#ifdef _WIN32
  const unsigned int reported_dpi=window_dpi(wave);
  const int text_dpi=static_cast<int>(reported_dpi?reported_dpi:96);
#else
  const int text_dpi=96*scale_factor;
#endif
  auto text_px=[text_dpi](int value){return static_cast<int>(std::lround(value*text_dpi/96.0));};
#ifdef _WIN32
  // Negative GDI height sizes the glyphs themselves, excluding internal leading.
  const int font_height=-text_px(13),label_height=text_px(22),minimum_lane=text_px(26),text_top=text_px(2);
#else
  const int font_height=text_px(11),label_height=text_px(14),minimum_lane=text_px(24),text_top=text_px(3);
#endif
  width*=scale_factor;
  const int h=client_height*scale_factor,channels=peak_source->GetNumChannels();
  if(cursor>=0 && cursor<client_width)cursor*=scale_factor;else cursor=-999999;
  if(peak_building && !peak_source->PeaksBuild_Run()) {
    peak_source->PeaksBuild_Finish();peak_building=false;peak_dirty=true;
  }
  const bool reload=peak_dirty || scale_factor!=peak_scale || width!=peak_width || start!=peak_start || span!=peak_span;
  const bool repaint=reload || labels_dirty || text_dpi!=peak_label_dpi || !(style==peak_style) || h!=peak_height || a!=peak_a || b!=peak_b || cursor!=peak_cursor || !peak_linked;
  if(!repaint)return true;
  if(width!=peak_width || h!=peak_height) {
    hide_peaks();if(peak_bitmap)destroy_bitmap(peak_bitmap);
    peak_bitmap=create_bitmap(true,width,h);if(!peak_bitmap)return false;
  }
  if(reload) {
    peak_values.assign(static_cast<size_t>(width)*channels*2,0);
    const double length=peak_source->GetLength();
    peak_count=get_peaks(peak_source,width/(length*span),start*length,channels,width,0,peak_values.data())&0xfffff;
    peak_count=std::clamp(peak_count,0,width);
  }
  clear_bitmap(peak_bitmap,style.background);
  const int sa=static_cast<int>(std::clamp((a-start)/span*width,0.0,static_cast<double>(width)));
  const int sb=static_cast<int>(std::clamp((b-start)/span*width,0.0,static_cast<double>(width)));
  const int lanes=static_cast<int>(peak_channels.size());
  for(int lane=0;lane<lanes;++lane) {
    const int channel=peak_channels[lane]-1,top=lane*h/lanes,bottom=(lane+1)*h/lanes;
    const int mid=(top+bottom)/2;const double scale=std::max(0,(bottom-top)/2-2*scale_factor);
    const int color=style.peaks;
    for(int x=0;x<peak_count;++x) {
      const auto index=static_cast<size_t>(x)*channels+channel;
      const double hi=peak_values[index],lo=peak_values[static_cast<size_t>(width)*channels+index];
      if(!std::isfinite(hi) || !std::isfinite(lo))continue;
      const int y1=static_cast<int>(std::lround(mid-std::clamp(hi,-1.0,1.0)*scale));
      const int y2=static_cast<int>(std::lround(mid-std::clamp(lo,-1.0,1.0)*scale));
      if(bottom>top)fill_rect(peak_bitmap,x,std::clamp(std::min(y1,y2),top,bottom-1),1,std::min(bottom-top,std::abs(y2-y1)+1),color,1,"COPY");
    }
    if(bottom-top<minimum_lane)continue;
    const std::string role=lanes==1?"Mono":lanes>2?"Input":lane?"R":"L";
    const std::string number="ch "+std::to_string(channel+1);
    std::string label=role+" "+number;
    if(channel<static_cast<int>(peak_names.size()) && !peak_names[channel].empty())label=role+" "+number+"  "+peak_names[channel];
    if(peak_building)label+=" ...";
#ifdef _WIN32
    label_native=AMDrawWaveLabel(peak_bitmap,label.c_str(),text_px(8),top+text_px(2),width-text_px(16),label_height,style.text,style.background,text_dpi,font_lookup);
    if(label_native){label_font_height=font_height;continue;}
#else
    label_native=AMDrawWaveLabel(peak_bitmap,label.c_str(),8*scale_factor,top+2*scale_factor,width-16*scale_factor,14*scale_factor,style.text,style.background,scale_factor,font_lookup);
    if(label_native){label_font_height=font_height;continue;}
#endif
    if(label_font && label_dpi!=text_dpi) {
      destroy_font(label_font);delete_gdi(label_gdi);label_font=label_gdi=nullptr;
    }
    if(!label_font && create_font && gdi_font && set_font && destroy_font && delete_gdi && draw_text && font_color && font_background) {
      #ifdef _WIN32
      const char* face="Yu Gothic UI";
#else
      const char* face="Hiragino Sans";
#endif
      label_font=create_font();label_gdi=gdi_font(font_height,400,0,false,false,false,face);label_dpi=text_dpi;label_font_height=font_height;
      // The JS wrapper forces PRECALCALL (ASCII-only). The public REAPER
      // setter keeps the live HFONT and permits Unicode glyph caching.
      if(label_font && label_gdi)set_font(label_font,label_gdi,0);
      else {if(label_font)destroy_font(label_font);if(label_gdi)delete_gdi(label_gdi);label_font=label_gdi=nullptr;}
    }
    if(label_font) {
      int units=0;for(unsigned char c:label)if(c<128)++units;else if((c&0xc0)!=0x80)units+=2;
      fill_rect(peak_bitmap,text_px(4),top+text_px(2),std::max(0,std::min(width-text_px(8),text_px(units*8+12))),label_height,style.background,1,"COPY");
      font_color(label_font,style.text);font_background(label_font,style.background);
      draw_text(peak_bitmap,label_font,label.c_str(),static_cast<int>(label.size()),text_px(8),top+text_top,std::max(text_px(8),width-text_px(8)),top+text_px(2)+label_height);
    } else {
      const auto fallback=role+" "+number;
      fill_rect(peak_bitmap,4,top+3,std::min(width-4,static_cast<int>(fallback.size())*8+8),12,style.background,1,"COPY");
      for(size_t i=0;i<fallback.size() && 8+static_cast<int>(i)*8<width-8;++i)draw_char(peak_bitmap,8+static_cast<int>(i)*8,top+5,fallback[i],style.text,1,"COPY");
    }
  }
  // Like the native preview, tint both the peaks and background with the
  // theme's selection blend mode and opacity, rather than replacing the bed.
  if(b>a && sb>sa) {
    const char* modes[]={"COPY","ADD","DODGE","MUL","OVERLAY","HSVADJ"};
    const int mode=style.selection_mode&255;
    const double alpha=((style.selection_mode>>8)&255)/256.0;
    fill_rect(peak_bitmap,sa,0,sb-sa,h,style.selection,alpha,modes[mode<6?mode:0]);
  }
  if(cursor>=0 && cursor<width)fill_rect(peak_bitmap,cursor,0,2*scale_factor,h,style.cursor,1,"COPY");
  peak_linked=composite(wave,0,0,client_width,client_height,peak_bitmap,0,0,width,h,false)>0;
  if(peak_linked)invalidate(wave,0,0,client_width,height,true);
  peak_width=width;peak_height=h;peak_scale=scale_factor;peak_label_dpi=text_dpi;peak_start=start;peak_span=span;peak_a=a;peak_b=b;peak_cursor=cursor;peak_style=style;peak_dirty=false;labels_dirty=false;
  return peak_linked;
}

void restore_clock() {
  if(clock_view && window_valid(clock_view) && *written_clock) {
    char text[256]{};get_title(clock_view,text,sizeof(text));
    if(!std::strcmp(text,written_clock))set_title(clock_view,native_clock);
  }
  *written_clock=0;
}
void unpaint() {
  if(linked && wave && window_valid(wave))unlink_bitmap(wave,bitmap,true);
  linked=false;last_x=-999999;
}
// Scrollbar coordinates need not equal client pixels (e.g. Windows/DPI).
int rounded_pixel(double value) {
  if(!std::isfinite(value) || value<std::numeric_limits<int>::min() || value>std::numeric_limits<int>::max())return -999999;
  return static_cast<int>(std::lround(value));
}
int pixel(double fraction,int position,int page,int minimum,int maximum,int width) {
  if(page<=0 || maximum<=minimum || width<=0 || !std::isfinite(fraction))return -999999;
  return rounded_pixel((fraction*(static_cast<double>(maximum)-minimum)-(static_cast<double>(position)-minimum))*width/page);
}
void format(char* out,int size,double t,bool rounded) {
  const long long ms=std::llround(std::max(0.0,t)*1000);
  const auto seconds=ms/1000;
  if(rounded)std::snprintf(out,size,"%lld:%02lld",seconds/60,seconds%60);
  else std::snprintf(out,size,"%lld:%02lld.%03lld",seconds/60,seconds%60,ms%1000);
}
void tick() {
  // REAPER owns transient range feedback inside its native mouse loop. Do not
  // cover it with the old playhead or an opaque selected-channel composite,
  // even when its last-played API still reports the pre-drag range.
  if(suspended)return;
  if(!wave || !window_valid(wave) || !window_valid(clock_view) || !visible(wave)) {
    unpaint();hide_peaks();restore_clock();return;
  }
  char path[4096]{},extra[128]{};int mode=0;double a=0,b=1,pitch=0,gain=0,rate=1,bpm=0;
  if(!file_info(path,sizeof(path),&mode,&a,&b,&pitch,&gain,&rate,&bpm,extra,sizeof(extra))) {
    unpaint();restore_clock();*last_path=0;
    // Native preview may be cleared while the owned channel controls have
    // focus. Lua still supplies the current selected file and clears it on
    // deselection, so keep its selected lanes visible while stopped.
    if(!peak_source){hide_peaks();return;}
    std::snprintf(path,sizeof(path),"%s",peak_path.c_str());
  }
  char playing_path[4096]{};double fraction=0,position=0,length=0;
  const int playing=AMPreviewWavePosition(playing_path,sizeof(playing_path),&fraction,&position,&length);
  if(playing<0)return; // Audio owns the lock: skip a frame instead of waiting.
  const auto style=wave_style();
  if(cursor_color!=style.cursor){unpaint();clear_bitmap(bitmap,style.cursor);cursor_color=style.cursor;}
  if(playing && am_path_equal(path,playing_path)) {
    std::snprintf(last_path,sizeof(last_path),"%s",path);
    last_fraction=fraction;last_position=position;last_length=length;
  } else if(!am_path_equal(path,last_path)) {
    unpaint();restore_clock();*last_path=0;
  }
  int at=0,page=0,minimum=0,maximum=0,track=0;
  int width=0,height=0;
  // SWELL can leave CoolSB's position/page stale after native zoom actions.
  // Reapply the unchanged client size after input so REAPER refreshes its own
  // scrollbar state before we map peaks to the native ruler.
#ifndef _WIN32
  if(viewport_dirty && send_message && client_size(wave,&width,&height) &&
      width>0 && width<=65535 && height>0 && height<=65535) {
    viewport_dirty=false;
    send_message(wave,0x5,0,(static_cast<std::uintptr_t>(height)<<16)|static_cast<unsigned>(width));
  }
#endif
  if(scroll_info(wave,"h",&at,&page,&minimum,&maximum,&track) && client_size(wave,&width,&height)) {
    actual_width=width;scroll_at=at;scroll_page=page;scroll_min=minimum;scroll_max=maximum;
    double start=0,span=1;viewport(path,at,page,minimum,maximum,width,start,span);
    const int x=!*last_path || suspended?-999999 : view_span>0 && am_path_equal(path,view_path)?
      rounded_pixel((last_fraction-start)/span*width):pixel(last_fraction,at,page,minimum,maximum,width);
    const bool selected=paint_peaks(path,width,height,start,span,(mode&384)?a:0,(mode&384)?b:0,x,style);
    if(!*last_path || suspended){if(!suspended)unpaint();return;}
    if(selected){unpaint();last_x=x;}
    // Do not clamp an offscreen source position
    // to an edge (that would falsely indicate a different part of the sound).
    else if(x<0 || x>=width)unpaint();
    else if(!linked || x!=last_x) {
      // JS_Composite(autoUpdate) can report failure when an overlapping area
      // is already dirty on macOS. Register the bitmap and invalidate through
      // the dedicated API, whose already-dirty path has a defined result.
      const int old=linked?last_x:x;
      linked=composite(wave,x,0,2,-1,bitmap,0,0,1,1,false)>0;
      int w=0,h=0;
      if(linked && client_size(wave,&w,&h))invalidate(wave,std::max(0,std::min(old,x)),0,std::min(w,std::max(old,x)+2),h,true);
      last_x=x;
    }
  } else {unpaint();hide_peaks();}
  if(!*last_path || suspended)return;
  char current[256]{},start[64]{},duration[64]{},next[256]{};
  get_title(clock_view,current,sizeof(current));
  if(std::strcmp(current,written_clock))std::snprintf(native_clock,sizeof(native_clock),"%s",current);
  const bool rounded=toggle(32063,40032)==1;
  format(start,sizeof(start),last_position,rounded);format(duration,sizeof(duration),last_length,false);
  std::snprintf(next,sizeof(next),"%s  /  %s",start,duration);
  if(std::strcmp(current,next))set_title(clock_view,next);
  std::snprintf(written_clock,sizeof(written_clock),"%s",next);
}
}
extern "C" void AMCursorRestoreClock(){restore_clock();}
extern "C" void AMCursorViewportChanged(){viewport_dirty=true;}
extern "C" void AMCursorZoom(int command) {
  AMCursorViewportChanged();
  view_span=0;view_at=-1;
  if((command!=42092 && command!=42093) || !file_info)return;
  int mode=0;double a=0,b=1,p=0,g=0,r=1,bpm=0;char extra[128]{};
  if(!file_info(view_path,sizeof(view_path),&mode,&a,&b,&p,&g,&r,&bpm,extra,sizeof(extra)))return;
  if(command==42093){view_start=0;view_span=1;}
  else if((mode&384) && b>a) {
    view_span=std::min(1.0,(b-a)*1.1);
    view_start=std::clamp(a-(b-a)*.05,0.0,1-view_span);
  }
}
extern "C" void AMCursorAnchor(const char* path,double fraction,int x) {
  if(view_span>0 && view_width>0 && am_path_equal(path,view_path))
    view_start=fraction-static_cast<double>(x)/view_width*view_span;
}
extern "C" void AMCursorRefresh(){
  // Snapshot on mouse-up so an immediate Pause keeps this exact bookmark.
  // Leave REAPER's freshly formatted native clock readable until the timer.
  char path[4096]{};double fraction=0,position=0,length=0;
  if(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==1) {
    std::snprintf(last_path,sizeof(last_path),"%s",path);
    last_fraction=fraction;last_position=position;last_length=length;
  }
}
extern "C" void AMCursorSuspend(bool on){
  suspended=on;
  if(on){unpaint();hide_peaks();restore_clock();}
}
extern "C" void AMCursorClear(){unpaint();restore_clock();*last_path=0;last_fraction=-1;}
extern "C" void AMCursorDetach() {
  if(label_font){destroy_font(label_font);label_font=nullptr;}
  if(label_gdi){delete_gdi(label_gdi);label_gdi=nullptr;}
  if(registered){host_register("-timer",reinterpret_cast<void*>(tick));registered=false;}
  clear_peaks();AMCursorClear();wave=clock_view=nullptr;suspended=false;label_native=false;label_font_height=0;
  view_span=0;view_at=view_page=view_width=view_units=-1;*view_path=0;
  actual_width=scroll_at=scroll_page=scroll_min=scroll_max=0;
  viewport_dirty=true;
  if(bitmap){destroy_bitmap(bitmap);bitmap=nullptr;}
}
extern "C" void AMCursorRegister(int(*reg)(const char*,void*)){host_register=reg;}
extern "C" bool AMCursorAttach(void* w,void* c,void*(*lookup)(const char*)) {
  AMCursorDetach();
  font_lookup=lookup;
#define GET(variable,name) variable=reinterpret_cast<decltype(variable)>(lookup(name))
  GET(window_valid,"JS_Window_IsWindow");GET(visible,"JS_Window_IsVisible");
  GET(scroll_info,"JS_Window_GetScrollInfo");GET(get_title,"JS_Window_GetTitle");GET(set_title,"JS_Window_SetTitle");
  GET(client_size,"JS_Window_GetClientSize");GET(invalidate,"JS_Window_InvalidateRect");
  GET(send_message,"BR_Win32_SendMessage");
  GET(create_bitmap,"JS_LICE_CreateBitmap");GET(destroy_bitmap,"JS_LICE_DestroyBitmap");GET(clear_bitmap,"JS_LICE_Clear");
  GET(composite,"JS_Composite");GET(unlink_bitmap,"JS_Composite_Unlink");
  GET(open_source,"PCM_Source_CreateFromFile");GET(close_source,"PCM_Source_Destroy");GET(get_peaks,"PCM_Source_GetPeaks");
  GET(fill_rect,"JS_LICE_FillRect");GET(draw_char,"JS_LICE_DrawChar");
  GET(create_font,"JS_LICE_CreateFont");GET(destroy_font,"JS_LICE_DestroyFont");GET(set_font,"LICE__SetFromHFont");
  GET(gdi_font,"JS_GDI_CreateFont");GET(delete_gdi,"JS_GDI_DeleteObject");GET(draw_text,"JS_LICE_DrawText");
  GET(font_color,"LICE__SetTextColor");GET(font_background,"LICE__SetBkColor");
  GET(file_info,"MediaExplorerGetLastPlayedFileInfo");GET(toggle,"GetToggleCommandStateEx");
  GET(theme_color,"GetThemeColor");GET(color_from_native,"ColorFromNative");
#undef GET
  if(!host_register || !window_valid || !visible || !scroll_info || !client_size || !invalidate || !get_title || !set_title ||
      !create_bitmap || !destroy_bitmap || !clear_bitmap || !composite || !unlink_bitmap || !file_info || !toggle)return false;
  if(!window_valid(w) || !window_valid(c))return false;
  bitmap=create_bitmap(true,1,1);if(!bitmap)return false;
  cursor_color=wave_style().cursor;clear_bitmap(bitmap,cursor_color);
  wave=w;clock_view=c;
  registered=host_register("timer",reinterpret_cast<void*>(tick))!=0;
  if(!registered){AMCursorDetach();return false;}return true;
}
extern "C" bool AMWaveSetChannelSubset(const char* path,const char* csv,const char* stamp) {
  if(!path || !*path){clear_peaks();return true;}
  std::vector<int> channels;
  if(!amchannels::parse(csv,channels) || !registered || !open_source || !close_source || !get_peaks || !fill_rect || !draw_char || !stamp)return false;
  const int highest=*std::max_element(channels.begin(),channels.end());
  if(am_path_equal(path,peak_path.c_str()) && peak_stamp==stamp && peak_source) {
    if(highest>peak_source->GetNumChannels())return false;
    if(channels!=peak_channels){peak_channels=channels;peak_left=channels.front();peak_right=channels.back();peak_dirty=true;}
    return true;
  }
  clear_peaks();
  PCM_source* source=open_source(path);if(!source)return false;
  if(source->GetNumChannels()>128 || highest>source->GetNumChannels() ||
      !std::isfinite(source->GetLength()) || source->GetLength()<=0){close_source(source);return false;}
  peak_source=source;peak_path=path;peak_stamp=stamp;peak_channels=channels;peak_left=channels.front();peak_right=channels.back();
  peak_building=source->PeaksBuild_Begin()!=0;
  return true;
}
extern "C" bool AMWaveSetChannelNames(const char* path,const char* stamp,const char* text) {
  if(!path || !stamp || !text || std::strlen(text)>131072)return false;
  if(!*path){if(!peak_names.empty()){peak_names.clear();peak_names_json.clear();labels_dirty=true;}return true;}
  if(!peak_source || !am_path_equal(path,peak_path.c_str()) || peak_stamp!=stamp)return false;
  if(peak_names_json==text)return true;
  try {
    const auto value=nlohmann::json::parse(text);
    if(!value.is_array() || value.size()!=static_cast<size_t>(peak_source->GetNumChannels()))return false;
    std::vector<std::string> names;
    for(const auto& name:value){if(!name.is_string())return false;const auto str=name.get<std::string>();
      if(str.size()>4096 || str.find_first_of("\r\n")!=std::string::npos || str.find('\0')!=std::string::npos)return false;
      names.push_back(str);
    }
    if(names!=peak_names){peak_names=std::move(names);labels_dirty=true;}
    peak_names_json=text;
    return true;
  }catch(...){return false;}
}
extern "C" bool AMWaveSetChannels(const char* path,int left,int right,const char* stamp) {
  if(left==0 && right==0)return AMWaveSetChannelSubset("","","");
  char csv[32];
  if(left==right)std::snprintf(csv,sizeof(csv),"%d",left);
  else std::snprintf(csv,sizeof(csv),"%d,%d",left,right);
  return AMWaveSetChannelSubset(path,csv,stamp);
}
extern "C" const char* AMCursorState() {
  static char result[1024];
  std::snprintf(result,sizeof(result),"{\"attached\":%s,\"visible\":%s,\"x\":%d,\"fraction\":%.12f,\"position\":%.9f,\"length\":%.9f,\"client_width\":%d,\"scroll_at\":%d,\"scroll_page\":%d,\"scroll_min\":%d,\"scroll_max\":%d,\"selected_visible\":%s,\"selected_lanes\":%d,\"selected_left\":%d,\"selected_right\":%d,\"peak_count\":%d,\"view_start\":%.12f,\"view_span\":%.12f}",
    registered?"true":"false",(linked || (peak_linked && peak_cursor>=0 && peak_cursor<peak_width))?"true":"false",last_x,last_fraction,last_position,last_length,actual_width,scroll_at,scroll_page,scroll_min,scroll_max,peak_linked?"true":"false",static_cast<int>(peak_channels.size()),peak_left,peak_right,peak_count,peak_start,peak_span);
  static std::string json;
  auto value=nlohmann::json::parse(result);value["selected_names"]=nlohmann::json::array();
  for(int channel:peak_channels)value["selected_names"].push_back(channel<=static_cast<int>(peak_names.size())?peak_names[channel-1]:"");
  value["name_font"]=label_native || label_font!=nullptr;
#ifdef _WIN32
  value["name_renderer"]=label_native?"DirectWrite":"LICE";
#else
  value["name_renderer"]=label_native?"Cocoa":"LICE";
#endif
  value["name_font_pixels"]=std::abs(label_font_height);value["name_dpi"]=peak_label_dpi;json=value.dump();return json.c_str();
}
