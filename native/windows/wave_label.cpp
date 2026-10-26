// Shape complete Unicode labels and rasterize smooth grayscale text. The
// waveform is composited/tinted later, so LCD subpixel color fringes are unsafe.
#include "common.h"
#include <dwrite_1.h>
#include <wrl/client.h>
#include <atomic>
#include <cmath>
#include <map>
#include <tuple>

namespace amwavelabel {
using Microsoft::WRL::ComPtr;
// The GDI bitmap target can quantize grayscale coverage. Render at twice the
// final resolution and area-average it to retain smooth small-text contours.
constexpr int sample_scale=2;
struct GlyphRenderer final:IDWriteTextRenderer {
  std::atomic<ULONG> refs{1};
  ComPtr<IDWriteBitmapRenderTarget> target;
  ComPtr<IDWriteRenderingParams> params;
  COLORREF color;
  GlyphRenderer(IDWriteBitmapRenderTarget* t,IDWriteRenderingParams* p,COLORREF c):target(t),params(p),color(c){}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void** out)override {
    if(!out)return E_POINTER;*out=nullptr;
    if(id==__uuidof(IUnknown) || id==__uuidof(IDWritePixelSnapping) || id==__uuidof(IDWriteTextRenderer)) {
      *out=static_cast<IDWriteTextRenderer*>(this);AddRef();return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}
  ULONG STDMETHODCALLTYPE Release()override{const ULONG n=--refs;if(!n)delete this;return n;}
  HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*,BOOL* disabled)override{*disabled=FALSE;return S_OK;}
  HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*,DWRITE_MATRIX* matrix)override{*matrix={1,0,0,1,0,0};return S_OK;}
  HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*,FLOAT* value)override{*value=1;return S_OK;}
  HRESULT STDMETHODCALLTYPE DrawGlyphRun(void*,FLOAT x,FLOAT y,DWRITE_MEASURING_MODE mode,
    const DWRITE_GLYPH_RUN* run,const DWRITE_GLYPH_RUN_DESCRIPTION*,IUnknown*)override {
    return target->DrawGlyphRun(x,y,mode,run,params.Get(),color,nullptr);
  }
  HRESULT STDMETHODCALLTYPE DrawUnderline(void*,FLOAT,FLOAT,const DWRITE_UNDERLINE*,IUnknown*)override{return E_NOTIMPL;}
  HRESULT STDMETHODCALLTYPE DrawStrikethrough(void*,FLOAT,FLOAT,const DWRITE_STRIKETHROUGH*,IUnknown*)override{return E_NOTIMPL;}
  HRESULT STDMETHODCALLTYPE DrawInlineObject(void* context,FLOAT x,FLOAT y,IDWriteInlineObject* object,BOOL sideways,BOOL rtl,IUnknown* effect)override {
    return object->Draw(context,this,x,y,sideways,rtl,effect);
  }
};
struct Raster {int width=0,height=0;std::vector<unsigned int> pixels;};
using Key=std::tuple<std::string,int,int,int,unsigned int,unsigned int>;
struct Cache {
  ComPtr<IDWriteFactory> factory;
  ComPtr<IDWriteGdiInterop> interop;
  ComPtr<IDWriteRenderingParams> params;
  std::map<Key,Raster> entries;
  size_t bytes=0,renders=0;
  static constexpr size_t limit=8*1024*1024;
  bool initialize() {
    if(params)return true;
    if(!factory && FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,__uuidof(IDWriteFactory),
      reinterpret_cast<IUnknown**>(factory.GetAddressOf()))))return false;
    if(!interop && FAILED(factory->GetGdiInterop(&interop)))return false;
    ComPtr<IDWriteRenderingParams> defaults;
    if(FAILED(factory->CreateRenderingParams(&defaults)))return false;
    return SUCCEEDED(factory->CreateCustomRenderingParams(defaults->GetGamma(),defaults->GetEnhancedContrast(),
      0,DWRITE_PIXEL_GEOMETRY_FLAT,DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,&params));
  }
  const Raster* get(const std::string& text,int width,int height,int dpi,unsigned int foreground,unsigned int background) {
    if(text.empty() || text.size()>4096 || width<1 || width>16384 || height<1 || height>1024 || dpi<48 || dpi>768)return nullptr;
    const Key key{text,width,height,dpi,foreground,background};
    const auto found=entries.find(key);if(found!=entries.end())return &found->second;
    if(!initialize())return nullptr;
    const auto wide=amwin::wide(text);
    ComPtr<IDWriteTextFormat> format;
    if(FAILED(factory->CreateTextFormat(L"Yu Gothic UI",nullptr,DWRITE_FONT_WEIGHT_NORMAL,DWRITE_FONT_STYLE_NORMAL,
      DWRITE_FONT_STRETCH_NORMAL,13.0f*dpi/96.0f*sample_scale,L"ja-JP",&format)))return nullptr;
    if(FAILED(format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)))return nullptr;
    ComPtr<IDWriteTextLayout> layout;
    if(FAILED(factory->CreateTextLayout(wide.data(),static_cast<UINT32>(wide.size()),format.Get(),
      static_cast<FLOAT>(width*sample_scale),static_cast<FLOAT>(height*sample_scale),&layout)))return nullptr;
    ComPtr<IDWriteInlineObject> ellipsis;
    DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER,0,0};
    if(FAILED(factory->CreateEllipsisTrimmingSign(format.Get(),&ellipsis)) || FAILED(layout->SetTrimming(&trim,ellipsis.Get())))return nullptr;
    DWRITE_TEXT_METRICS metrics{};if(FAILED(layout->GetMetrics(&metrics)))return nullptr;
    Raster raster;raster.width=std::min(width,static_cast<int>(std::ceil(metrics.widthIncludingTrailingWhitespace/sample_scale))+2);raster.height=height;
    const size_t bytes_needed=static_cast<size_t>(raster.width)*height*sizeof(unsigned int);
    if(raster.width<1 || bytes_needed>limit)return nullptr;
    const int render_width=raster.width*sample_scale,render_height=height*sample_scale;
    ComPtr<IDWriteBitmapRenderTarget> target;
    if(FAILED(interop->CreateBitmapRenderTarget(nullptr,render_width,render_height,&target)))return nullptr;
    ComPtr<IDWriteBitmapRenderTarget1> antialias;
    if(FAILED(target.As(&antialias)) || FAILED(antialias->SetTextAntialiasMode(DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE)) ||
      FAILED(target->SetPixelsPerDip(1)))return nullptr;
    auto color=[](unsigned int value){return RGB((value>>16)&255,(value>>8)&255,value&255);};
    HDC dc=target->GetMemoryDC();RECT rect{0,0,render_width,render_height};
    SetDCBrushColor(dc,color(background));FillRect(dc,&rect,reinterpret_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
    GdiFlush(); // Finish the background fill before DirectWrite touches the DIB.
    ComPtr<GlyphRenderer> renderer;renderer.Attach(new GlyphRenderer(target.Get(),params.Get(),color(foreground)));
    if(FAILED(layout->Draw(nullptr,renderer.Get(),0,0)))return nullptr;
    GdiFlush();DIBSECTION dib{};
    if(GetObjectW(GetCurrentObject(dc,OBJ_BITMAP),sizeof(dib),&dib)!=sizeof(dib) || !dib.dsBm.bmBits || dib.dsBm.bmBitsPixel!=32)return nullptr;
    const auto src=static_cast<const unsigned int*>(dib.dsBm.bmBits);const int stride=dib.dsBm.bmWidthBytes/4;
    if(stride<render_width || dib.dsBm.bmHeight<render_height)return nullptr;
    raster.pixels.resize(static_cast<size_t>(raster.width)*height);
    for(int y=0;y<height;++y)for(int x=0;x<raster.width;++x) {
      unsigned int red=0,green=0,blue=0;
      for(int sy=0;sy<sample_scale;++sy)for(int sx=0;sx<sample_scale;++sx) {
        const int row=y*sample_scale+sy;
        // DirectWrite guarantees a top-down DIB. GetObject normalizes the
        // reported height to positive, so its sign cannot determine row order.
        const auto pixel=src[row*stride+x*sample_scale+sx];
        red+=(pixel>>16)&255;green+=(pixel>>8)&255;blue+=pixel&255;
      }
      constexpr unsigned int count=sample_scale*sample_scale,half=count/2;
      raster.pixels[static_cast<size_t>(y)*raster.width+x]=0xff000000u|((red+half)/count<<16)|((green+half)/count<<8)|((blue+half)/count);
    }
    if(entries.size()>=128 || bytes+bytes_needed>limit){entries.clear();bytes=0;}
    bytes+=bytes_needed;++renders;
    return &entries.emplace(key,std::move(raster)).first->second;
  }
};
Cache cache;
}

extern "C" bool AMDrawWaveLabel(void* bitmap,const char* text,int x,int y,int width,int height,
  unsigned int foreground,unsigned int background,int dpi,void*(*lookup)(const char*)) {
  if(!bitmap || !text || !lookup || x<0 || y<0)return false;
  try {
    auto bits=reinterpret_cast<unsigned int*(*)(void*)>(lookup("LICE__GetBits"));
    auto stride=reinterpret_cast<int(*)(void*)>(lookup("LICE__GetRowSpan"));
    auto bitmapWidth=reinterpret_cast<int(*)(void*)>(lookup("LICE__GetWidth"));
    auto bitmapHeight=reinterpret_cast<int(*)(void*)>(lookup("LICE__GetHeight"));
    auto flipped=reinterpret_cast<bool(*)(void*)>(lookup("LICE__IsFlipped"));
    if(!bits || !stride || !bitmapWidth || !bitmapHeight || !flipped)return false;
    const auto raster=amwavelabel::cache.get(text,width,height,dpi,foreground,background);if(!raster)return false;
    auto dest=bits(bitmap);const int pitch=stride(bitmap),bw=bitmapWidth(bitmap),bh=bitmapHeight(bitmap);const bool flip=flipped(bitmap);
    if(!dest || pitch<bw || x>bw-raster->width || y>bh-raster->height)return false;
    for(int row=0;row<raster->height;++row)
      std::copy_n(raster->pixels.data()+static_cast<size_t>(row)*raster->width,raster->width,
        dest+static_cast<size_t>(flip?bh-1-y-row:y+row)*pitch+x);
    return true;
  }catch(...){return false;}
}
