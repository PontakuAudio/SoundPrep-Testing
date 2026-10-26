#include "wave_label.cpp"
#include <cassert>
#include <fstream>
#include <iostream>
#include <set>

struct Bitmap {
  int width=1200,height=560;bool flipped=false;
  std::vector<unsigned int> pixels=std::vector<unsigned int>(static_cast<size_t>(width)*height,0xffeeeeeeu);
};
static void* lookup(const char* name) {
  if(!strcmp(name,"LICE__GetBits"))return reinterpret_cast<void*>(+[](void* p){return static_cast<Bitmap*>(p)->pixels.data();});
  if(!strcmp(name,"LICE__GetWidth") || !strcmp(name,"LICE__GetRowSpan"))return reinterpret_cast<void*>(+[](void* p){return static_cast<Bitmap*>(p)->width;});
  if(!strcmp(name,"LICE__GetHeight"))return reinterpret_cast<void*>(+[](void* p){return static_cast<Bitmap*>(p)->height;});
  if(!strcmp(name,"LICE__IsFlipped"))return reinterpret_cast<void*>(+[](void* p){return static_cast<Bitmap*>(p)->flipped;});
  return nullptr;
}
int main() {
  Bitmap bitmap;int row=0;bool clipping=false;
  for(int dpi:{96,120,144,192,288}) {
    const int height=MulDiv(22,dpi,96),y=20+row++*108;
    const std::string text=std::to_string(MulDiv(dpi,100,96))+"%  AV office 風鈴 é 🎤";
    for(int dark:{0,1}) {
      const unsigned int fg=dark?0xffeeeeeeu:0xff202020u,bg=dark?0xff202020u:0xffeeeeeeu;
      const auto raster=amwavelabel::cache.get(text,560,height,dpi,fg,bg);assert(raster);
      std::set<unsigned int> shades;int ink=0;
      for(auto pixel:raster->pixels) {
        assert((pixel>>24)==255);
        assert(((pixel>>16)&255)==((pixel>>8)&255) && ((pixel>>8)&255)==(pixel&255));
        shades.insert(pixel&255);if(pixel!=bg)++ink;
      }
      std::cerr<<dpi<<" DPI "<<(dark?"dark":"light")<<": "<<ink<<" ink pixels, "<<shades.size()<<" grayscale levels\n";
      assert(ink>30 && shades.size()>32); // Old GDI cached glyphs had only 16 edge levels.
      const size_t renders=amwavelabel::cache.renders;
      assert(amwavelabel::cache.get(text,560,height,dpi,fg,bg)==raster && amwavelabel::cache.renders==renders);
      // More vertical space must reveal no glyph pixels below the normal box.
      const auto taller=amwavelabel::cache.get(text,560,height+8,dpi,fg,bg);assert(taller);
      int bottom=0;
      for(int py=0;py<taller->height;++py)for(int x=0;x<taller->width;++x)
        if(taller->pixels[static_cast<size_t>(py)*taller->width+x]!=bg)bottom=py+1;
      clipping=clipping || bottom>height;
      std::cerr<<"Glyph bottom: "<<bottom<<" px; label height: "<<height<<" px\n";
      assert(AMDrawWaveLabel(&bitmap,text.c_str(),dark?620:20,y,560,height,fg,bg,dpi,lookup));
      std::cout<<dpi<<" DPI "<<(dark?"dark":"light")<<": "<<shades.size()<<" grayscale levels, "<<(bottom>height?"clipped":"no vertical clipping")<<"\n";
    }
  }
  Bitmap flipped=bitmap;flipped.flipped=true;std::fill(flipped.pixels.begin(),flipped.pixels.end(),0xffeeeeeeu);
  assert(AMDrawWaveLabel(&flipped,"Flipped 風鈴",10,10,300,22,0xff202020,0xffeeeeee,96,lookup));
  const auto raster=amwavelabel::cache.get("Flipped 風鈴",300,22,96,0xff202020,0xffeeeeee);assert(raster);
  for(int y=0;y<22;++y)for(int x=0;x<raster->width;++x)
    assert(flipped.pixels[static_cast<size_t>(flipped.height-11-y)*flipped.width+10+x]==raster->pixels[static_cast<size_t>(y)*raster->width+x]);
  auto unchanged=bitmap.pixels;
  assert(!AMDrawWaveLabel(&bitmap,"Bounds",1199,559,200,22,0xff202020,0xffeeeeee,96,lookup));
  assert(!AMDrawWaveLabel(&bitmap,"Bad UTF-8 \xff",0,0,200,22,0xff202020,0xffeeeeee,96,lookup));
  assert(bitmap.pixels==unchanged);
  assert(amwavelabel::cache.get("Long name should be ellipsized 風鈴",40,22,96,0xff202020,0xffeeeeee));
  for(int i=0;i<150;++i)assert(amwavelabel::cache.get("Cache "+std::to_string(i),300,22,96,0xff202020,0xffeeeeee));
  assert(amwavelabel::cache.entries.size()<=128 && amwavelabel::cache.bytes<=amwavelabel::Cache::limit);
  BITMAPFILEHEADER header{};header.bfType=0x4d42;header.bfOffBits=sizeof(header)+sizeof(BITMAPINFOHEADER);
  header.bfSize=header.bfOffBits+static_cast<DWORD>(bitmap.pixels.size()*4);
  BITMAPINFOHEADER info{};info.biSize=sizeof(info);info.biWidth=bitmap.width;info.biHeight=-bitmap.height;
  info.biPlanes=1;info.biBitCount=32;info.biCompression=BI_RGB;
  std::ofstream out("wave-label-directwrite.bmp",std::ios::binary);assert(out);
  out.write(reinterpret_cast<const char*>(&header),sizeof(header));out.write(reinterpret_cast<const char*>(&info),sizeof(info));
  out.write(reinterpret_cast<const char*>(bitmap.pixels.data()),bitmap.pixels.size()*4);assert(out);
  out.close();assert(!clipping);
  std::cout<<"PASS: DirectWrite Unicode shaping, grayscale edges, clipping, flipped bitmaps, bounds and bounded cache\n";
}
