#include "preview_lock.h"
#include "path_equal.h"
#include "channel_subset.h"
#include "preview_clock.h"
// Low-latency, instance-local preview using only the public REAPER audio ABI.
// FX remain hosted by REAPER tracks. No transformed-audio lookahead is queued.
#include "reaper_audio_abi.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <limits>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
void* (*lookup)(const char*);
int (*play_track)(void*,preview_register_t*,int,double);
int (*stop_track)(void*,preview_register_t*);
int (*start_fade)(void*,preview_register_t*,double,int);
double (*clock_now)();
double (*output_latency)();
bool (*fx_config)(void*,int,const char*,char*,int);
void* (*master_track)(void*);
int (*register_host)(const char*,void*);
bool (*valid)(void*,const char*);
bool (*valid_track)(void*,void*,const char*);
void (*destroy_source)(PCM_source*);
IReaperPitchShift* (*make_pitch)(int);
void* (*find_child)(void*,int);
int (*get_title)(void*,char*,int);
int (*toggle_state)(int,int);
double (*master_tempo)();
bool (*media_info)(char*,int,int*,double*,double*,double*,double*,double*,double*,char*,int);
int (*play_state)(void*);
double (*play_position)(void*);
double (*time_beats)(void*,double,int*,int*,double*,int*);
double (*measure_info)(void*,int,double*,double*,int*,int*,double*);

class Source final : public PCM_source {
public:
  static constexpr int max_channels=128,chunk_frames=8192;
  std::mutex mutex;
  PCM_source* file;
  std::unique_ptr<IReaperPitchShift> pitch;
  const std::vector<int> selected_channels;
  const int source_channels,output_channels,downmix_mode;
  const bool downmix;
  const int selected_left,selected_right;
  const bool mapped;
  // Decoder and pitch widths are independent of the host's requested output
  // width. Allocate bounded scratch on creation, never in the audio callback.
  std::vector<double> decoded,processed;
  double rate=1,semitones=0,gain=1,fade_in=0,fade_out=0;
  bool preserve=true,reset=true;
  int mode=-1;
  double read_time=0,next_time=-1,sample_rate=0;
  int channels=0,ramp=0;
  double first_callback=0,first_position=0,last_callback=0,transfer_latency=0,absolute_time=0,max_callback_ms=0;
  unsigned long long blocks=0;
  double device_latency=0,fx_latency=0,fx_samples=0;
  int block_size=0;
  PreviewClock audible;
  std::array<double,128> last{};
  // API resolution can run again when the UI creates another preview. Keep
  // the callback's function pointer immutable instead of racing that lookup.
  double (*const callback_clock)();
  static bool valid_mix(int channels,int mix) {
    if(channels<1 || channels>max_channels || mix<0 || mix>2)return false;
    if(mix!=2)return true;
    // Full-sphere ACN orders contain (order+1)^2 channels. A filename may
    // identify AmbiX, but an incomplete/horizontal set is not this contract.
    for(int width=2;width*width<=max_channels;++width)if(channels==width*width)return true;
    return false;
  }
  Source(PCM_source* source,int mix=0,int left=0,int right=0,const std::vector<int>& subset={}) : file(source->Duplicate()),pitch(make_pitch(0x14)),
    selected_channels(subset),
    source_channels(file?file->GetNumChannels():0),
    output_channels(valid_mix(source_channels,mix) && ((left==0 && right==0) ||
      (mix==0 && left>=1 && right>=1 && left<=source_channels && right<=source_channels))?
      (left || mix?2:std::max(2,subset.empty()?source_channels:static_cast<int>(subset.size()))):0),
    downmix_mode(mix),downmix(mix!=0),selected_left(left),selected_right(right),mapped(source_channels>2 || left>0 || !subset.empty()),
    decoded(output_channels && mapped?static_cast<std::size_t>(chunk_frames)*source_channels:0),
    processed(mapped?static_cast<std::size_t>(chunk_frames)*output_channels:0),callback_clock(clock_now) {}
  ~Source() override { if(file)destroy_source(file); }
  bool ready() const { return file && pitch && output_channels>0 && (selected_channels.empty() || *std::max_element(selected_channels.begin(),selected_channels.end())<=source_channels) && std::isfinite(file->GetLength()) && file->GetLength()>0; }
  PCM_source* Duplicate() override { return nullptr; } // Host buffering is explicitly disabled.
  bool IsAvailable() override { return file->IsAvailable(); }
  const char* GetType() override { return "AM_PREVIEW"; }
  const char* GetFileName() override { return file->GetFileName(); }
  bool SetFileName(const char*) override { return false; }
  int GetNumChannels() override { return output_channels; }
  double GetSampleRate() override { return file->GetSampleRate(); }
  double GetLength() override { std::lock_guard<std::mutex> lock(mutex);return file->GetLength()/rate; }
  int PropertiesWindow(HWND) override { return 0; }
  void GetPeakInfo(PCM_source_peaktransfer_t*) override {}
  void SaveState(ProjectStateContext*) override {}
  int LoadState(const char*,ProjectStateContext*) override { return -1; }
  void Peaks_Clear(bool) override {}
  int PeaksBuild_Begin() override { return 0; }
  int PeaksBuild_Run() override { return 0; }
  void PeaksBuild_Finish() override {}
  int decode(PCM_source_transfer_t input,double* destination) {
    input.nch=source_channels;input.samples=decoded.data();input.samples_out=0;
    file->GetSamples(&input);
    const int frames=std::clamp(input.samples_out,0,input.length);
    for(int i=0;i<frames;++i) {
      const double* original=decoded.data()+static_cast<std::size_t>(i)*source_channels;
      double* frame=destination+static_cast<std::size_t>(i)*output_channels;
      if(!selected_channels.empty()) {
        for(std::size_t c=0;c<selected_channels.size();++c)frame[c]=original[selected_channels[c]-1];
        if(selected_channels.size()==1)frame[1]=frame[0];
      }
      else if(selected_left) {frame[0]=original[selected_left-1];frame[1]=original[selected_right-1];}
      else if(source_channels==1)frame[0]=frame[1]=original[0];
      else if(downmix_mode==2) {
        // AmbiX ACN/SN3D stores W and Y at indices 0 and 1. This deliberately
        // simple M/S preview ignores Z, X and higher orders; it is not a
        // loudspeaker-layout decoder. Half gain bounds full-scale W/Y input.
        frame[0]=.5*(original[0]+original[1]);
        frame[1]=.5*(original[0]-original[1]);
      } else if(downmix && source_channels>2) {
        // The PCM ABI does not identify speakers. Treat channels as discrete:
        // odd-numbered channels average to L, even-numbered channels to R.
        // Every channel contributes, and coherent full-scale input stays bounded.
        frame[0]=frame[1]=0;
        const int left=(source_channels+1)/2,right=source_channels/2;
        for(int c=0;c<source_channels;++c)frame[c%2]+=original[c];
        frame[0]/=left;frame[1]/=right;
      } else std::copy_n(original,output_channels,frame);
    }
    return frames;
  }
  void copy_output(double* destination,int host_channels,int frames) const {
    const int copy_channels=std::min(output_channels,host_channels);
    for(int i=0;i<frames;++i) {
      double* frame=destination+static_cast<std::size_t>(i)*host_channels;
      std::copy_n(processed.data()+static_cast<std::size_t>(i)*output_channels,copy_channels,frame);
      std::fill(frame+copy_channels,frame+host_channels,0.0);
    }
  }
  void GetSamples(PCM_source_transfer_t* out) override {render(out,0);}
  void render(PCM_source_transfer_t* out,double callback_offset) {
    if(!out)return;
    out->samples_out=0;
    // The ABI supplies frame counts and finite times. Reject malformed blocks
    // before pointer arithmetic or float-to-int conversion touches the buffer.
    if(!out->samples || out->nch<1 || out->nch>128 || out->length<1 ||
        !std::isfinite(out->time_s) || !std::isfinite(out->samplerate) || out->samplerate<=0 ||
        out->samplerate*.001>std::numeric_limits<int>::max())return;
    // A sample-accurate pre-roll for Start on bar. No timer/defer scheduling,
    // and no buffered source is needed just to wait for the next measure.
    if(out->time_s<0) {
      const int silence=static_cast<int>(std::min<double>(out->length,std::ceil(-out->time_s*out->samplerate)));
      std::fill_n(out->samples,static_cast<std::size_t>(silence)*out->nch,0.0);out->samples_out=silence;
      if(silence<out->length) {
        PCM_source_transfer_t tail=*out;tail.time_s+=silence/out->samplerate;
        tail.samples+=static_cast<std::size_t>(silence)*out->nch;tail.length-=silence;tail.samples_out=0;
        render(&tail,callback_offset+silence/out->samplerate);out->samples_out+=tail.samples_out;
      }
      return;
    }
    const double wall_start=callback_clock?callback_clock():0;
    std::lock_guard<std::mutex> lock(mutex);
    const double callback=callback_clock?callback_clock()+callback_offset:0;
    if(!blocks){first_callback=callback;first_position=out->time_s;}
    ++blocks;last_callback=callback;transfer_latency=out->approximate_playback_latency;absolute_time=out->absolute_time_s;block_size=out->length;
    fx_latency=fx_samples/out->samplerate;
    const double duration=file->GetLength()/rate;
    const int wanted=std::min(out->length,static_cast<int>(std::min<double>(out->length,
      std::max(0.0,std::ceil((duration-out->time_s)*out->samplerate)))));
    if(!wanted)return;
    const bool restart=reset || sample_rate!=out->samplerate || channels!=out->nch ||
      std::abs(next_time-out->time_s)>.5/out->samplerate;
    if(restart) {
      sample_rate=out->samplerate;channels=out->nch;
      pitch->set_srate(sample_rate);pitch->set_nch(mapped?output_channels:channels);
      pitch->SetQualityParameter(mode);pitch->set_tempo(rate);
      pitch->set_shift(std::pow(2.0,semitones/12.0)*(preserve?1:rate));
      pitch->Reset();read_time=out->time_s*rate;reset=false;
      // A transition ramp belongs to a running seek/parameter change, never
      // to the first transient or to a natural loop boundary.
      ramp=next_time>=0 && out->time_s>0 ? static_cast<int>(sample_rate*.001) : 0;
    }
    // Preserve the established mono/stereo decoder conversion exactly. Only
    // multichannel sources need explicit channel mapping before the pitch API.
    if(!mapped && rate==1 && semitones==0) {
      PCM_source_transfer_t input=*out;input.length=wanted;
      file->GetSamples(&input);out->samples_out=input.samples_out;
    } else if(!mapped) {
      bool eof=false;
      for(int attempt=0;out->samples_out<wanted && attempt<256;++attempt) {
        const int received=pitch->GetSamples(wanted-out->samples_out,out->samples+static_cast<std::size_t>(out->samples_out)*out->nch);
        out->samples_out+=received;
        if(out->samples_out>=wanted || eof)break;
        PCM_source_transfer_t input{};
        input.time_s=read_time;input.samplerate=sample_rate;input.nch=channels;
        input.length=static_cast<int>(std::clamp(std::ceil(wanted*rate),512.0,8192.0));
        input.samples=pitch->GetBuffer(input.length);
        file->GetSamples(&input);pitch->BufferDone(input.samples_out);
        read_time+=input.samples_out/sample_rate;
        eof=input.samples_out<input.length;if(eof)pitch->FlushSamples();
      }
    } else if(rate==1 && semitones==0) {
      while(out->samples_out<wanted) {
        PCM_source_transfer_t input=*out;
        input.time_s+=out->samples_out/sample_rate;
        input.absolute_time_s+=out->samples_out/sample_rate;
        input.length=std::min(chunk_frames,wanted-out->samples_out);
        const int received=decode(input,processed.data());
        copy_output(out->samples+static_cast<std::size_t>(out->samples_out)*out->nch,out->nch,received);
        out->samples_out+=received;
        if(received<input.length)break;
      }
    } else {
      // The decoder retains its own disk cache. Feed only enough samples for
      // this device block; do not pre-render 240 ms of obsolete pitch/rate.
      bool eof=false;
      for(int attempts=0;out->samples_out<wanted && attempts<256;) {
        const int request=std::min(chunk_frames,wanted-out->samples_out);
        const int received=std::clamp(pitch->GetSamples(request,processed.data()),0,request);
        copy_output(out->samples+static_cast<std::size_t>(out->samples_out)*out->nch,out->nch,received);
        out->samples_out+=received;
        if(out->samples_out>=wanted || (eof && received==0))break;
        if(received>0){attempts=0;continue;}
        ++attempts;
        PCM_source_transfer_t input{};
        input.time_s=read_time;input.samplerate=sample_rate;
        input.length=static_cast<int>(std::clamp(std::ceil(request*rate),512.0,static_cast<double>(chunk_frames)));
        double* buffer=pitch->GetBuffer(input.length);if(!buffer)break;
        const int supplied=decode(input,buffer);pitch->BufferDone(supplied);
        read_time+=supplied/sample_rate;
        eof=supplied<input.length;if(eof)pitch->FlushSamples();
      }
    }
    const int ramp_length=std::max(1,static_cast<int>(sample_rate*.001));
    for(int i=0;i<out->samples_out;++i) {
      const double time=out->time_s+i/sample_rate;
      const double fade=std::min(fade_in>0?std::min(1.0,time/fade_in):1.0,
        fade_out>0?std::clamp((duration-time)/fade_out,0.0,1.0):1.0);
      const double blend=ramp>0?1.0-static_cast<double>(ramp)/ramp_length:1.0;
      for(int c=0;c<out->nch;++c) {
        auto& value=out->samples[static_cast<std::size_t>(i)*out->nch+c];value=value*gain*fade*blend+last[c]*(1-blend);
        if(ramp<=1)last[c]=value;
      }
      if(ramp>0)--ramp;
    }
    next_time=out->time_s+out->samples_out/out->samplerate;
    if(callback_clock) {
      if(out->samples_out>0)audible.push(callback,device_latency,out->time_s,out->samples_out/out->samplerate,rate);
      // Include time blocked on the UI's Source lock in the diagnostic, while
      // preserving the existing callback timestamp used by the audible clock.
      max_callback_ms=std::max(max_callback_ms,(callback_clock()-wall_start)*1000);
    }
  }
};
struct Preview {
  std::unique_ptr<Source> source;
  preview_register_t reg{};
  void *project,*track,*fx_track=nullptr;
  double latency_checked=-1;
  bool playing=false;
  double measure_align=-1;
  std::string wave_path;
  double wave_length=0,wave_a=0,wave_b=0;
  bool wave_reverse=false;
  unsigned wave_seek=0;
  Preview(PCM_source* file,void* p,void* t,int downmix=0,int left=0,int right=0,const std::vector<int>& subset={}) : source(new Source(file,downmix,left,right,subset)),project(p),track(t) {
    am_preview_init(reg);reg.src=source.get();reg.m_out_chan=-1;reg.preview_track=t;reg.volume=1;
  }
  ~Preview() { if(playing && valid(project,"ReaProject*"))stop_track(project,&reg);am_preview_destroy(reg); }
};
struct Guard {
  preview_register_t* m;
  explicit Guard(preview_register_t& reg):m(&reg){am_preview_lock(*m);}
  ~Guard(){am_preview_unlock(*m);}
};
std::unordered_map<void*,std::unique_ptr<Preview>> previews;
std::vector<std::pair<double,std::unique_ptr<Preview>>> retiring;
bool timer_registered=false;
uintptr_t serial=0;
void* bound=nullptr;
Preview* get(void* handle) {
  const auto it=previews.find(handle);if(it==previews.end())return nullptr;
  if(!valid(it->second->project,"ReaProject*") || !valid_track(it->second->project,it->second->track,"MediaTrack*")) {
    if(bound==handle)bound=nullptr;previews.erase(it);return nullptr;
  }
  return it->second.get();
}
bool resolve() {
  if(!lookup)return false;
#define AM_RESOLVE(variable,name) variable=reinterpret_cast<decltype(variable)>(lookup(name))
  AM_RESOLVE(play_track,"PlayTrackPreview2Ex");AM_RESOLVE(stop_track,"StopTrackPreview2");
  AM_RESOLVE(start_fade,"StartPreviewFade");AM_RESOLVE(clock_now,"time_precise");
  AM_RESOLVE(output_latency,"GetOutputLatency");
  AM_RESOLVE(fx_config,"TrackFX_GetNamedConfigParm");AM_RESOLVE(master_track,"GetMasterTrack");
  AM_RESOLVE(valid,"ValidatePtr");AM_RESOLVE(valid_track,"ValidatePtr2");
  AM_RESOLVE(destroy_source,"PCM_Source_Destroy");AM_RESOLVE(make_pitch,"ReaperGetPitchShiftAPI");
  AM_RESOLVE(find_child,"JS_Window_FindChildByID");AM_RESOLVE(get_title,"JS_Window_GetTitle");
  AM_RESOLVE(toggle_state,"GetToggleCommandStateEx");
  AM_RESOLVE(master_tempo,"Master_GetTempo");AM_RESOLVE(media_info,"MediaExplorerGetLastPlayedFileInfo");
  AM_RESOLVE(play_state,"GetPlayStateEx");AM_RESOLVE(play_position,"GetPlayPosition2Ex");
  AM_RESOLVE(time_beats,"TimeMap2_timeToBeats");AM_RESOLVE(measure_info,"TimeMap_GetMeasureInfo");
#undef AM_RESOLVE
  return play_track && stop_track && valid && valid_track && destroy_source && make_pitch;
}
void* create_impl(PCM_source* source,void* project,void* track,int downmix,bool multichannel,int left=0,int right=0,const std::vector<int>& subset={}) {
  if(downmix<0 || downmix>2 || !resolve() || !source || !valid(project,"ReaProject*") || !valid_track(project,track,"MediaTrack*"))return nullptr;
  auto p=std::make_unique<Preview>(source,project,track,downmix,left,right,subset);
  if(!p->source->ready() || (!multichannel && p->source->source_channels>2))return nullptr;
  auto handle=reinterpret_cast<void*>(++serial);previews.emplace(handle,std::move(p));return handle;
}
void* create(PCM_source* source,void* project,void* track) {return create_impl(source,project,track,0,false);}
void* create_with_selection(PCM_source* source,void* project,void* track,int left,int right) {
  if(left<1 || left>128 || right<1 || right>128)return nullptr;
  return create_impl(source,project,track,0,true,left,right);
}
void* create_with_subset(PCM_source* source,void* project,void* track,const char* csv) {
  std::vector<int> subset;if(!amchannels::parse(csv,subset))return nullptr;
  return create_impl(source,project,track,0,true,0,0,subset);
}
void* create_with_channels(PCM_source* source,void* project,void* track,bool downmix) {return create_impl(source,project,track,downmix,true);}
void* create_with_downmix(PCM_source* source,void* project,void* track,int mode) {return create_impl(source,project,track,mode,true);}
void update_latency(Preview& p,bool force=false) {
  if(!clock_now)return;
  const double now=clock_now();if(!force && now-p.latency_checked<.05)return;
  double samples=0;
  if(fx_config)for(void* t: {p.fx_track,master_track?master_track(p.project):nullptr}) {
    if(!t || !valid_track(p.project,t,"MediaTrack*"))continue;
    char text[64]{};
    // Owned chains ignore host PDC; retain the plugin's real lookahead in the
    // audible clock. User master FX keep their host-managed compensation.
    if(fx_config(t,0,t==p.fx_track?"chain_pdc_reporting":"chain_pdc_actual",text,sizeof(text)))
      samples+=std::max(0.0,std::strtod(text,nullptr));
  }
  const double device=output_latency?std::max(0.0,output_latency()):0;
  auto& s=*p.source;std::unique_lock<std::mutex> lock(s.mutex,std::try_to_lock);
  if(!lock.owns_lock())return;
  p.latency_checked=now;s.fx_samples=samples;
  s.device_latency=device;s.fx_latency=s.sample_rate>0?samples/s.sample_rate:0;
}
double audible_position(Preview& p,double now) { // caller owns both locks
  double source=0;
  return clock_now && p.source->audible.position(now-p.source->fx_latency,&source)?source/p.source->rate:p.reg.curpos;
}
bool play(void* handle) {
  auto p=get(handle);if(!p)return false;if(p->playing)return true;
  update_latency(*p,true);
  if(p->measure_align>=0 && play_state && play_position && time_beats && measure_info && (play_state(p->project)&1)) {
    const double now=play_position(p->project);int measure=0,num=0,denom=0;double beats=0,q0=0,q1=0,tempo=0;
    time_beats(p->project,now,&measure,&num,&beats,&denom);
    const double start=measure_info(p->project,measure,&q0,&q1,&num,&denom,&tempo);
    const double end=measure_info(p->project,measure+1,&q0,&q1,&num,&denom,&tempo);
    if(p->measure_align>0 && end>now)p->reg.curpos=-std::max(0.0,end-now);
    else if(p->measure_align==0 && now>=start)p->reg.curpos=std::fmod(now-start,p->source->GetLength());
  }
  p->playing=play_track(p->project,&p->reg,0,-1)!=0;return p->playing;
}
void retire_tick() {
  const double now=clock_now();
  retiring.erase(std::remove_if(retiring.begin(),retiring.end(),[now](const auto& p){return p.first<=now;}),retiring.end());
  if(retiring.empty() && timer_registered) {register_host("-timer",reinterpret_cast<void*>(retire_tick));timer_registered=false;}
}
void stop(void* handle) {
  if(bound==handle)bound=nullptr;
  auto it=previews.find(handle);if(it==previews.end())return;
  auto& p=*it->second;
  if(p.playing && p.source->fade_out>0 && start_fade && clock_now && register_host &&
      valid(p.project,"ReaProject*") && valid_track(p.project,p.track,"MediaTrack*") &&
      start_fade(p.project,&p.reg,p.source->fade_out,2)>0) {
    retiring.emplace_back(clock_now()+p.source->fade_out,std::move(it->second));
    if(!timer_registered) {register_host("timer",reinterpret_cast<void*>(retire_tick));timer_registered=true;}
  }
  previews.erase(it);
}
bool value(void* handle,const char* key,double* out) {
  auto p=get(handle);if(!p || !key || !out)return false;
  update_latency(*p);
  bool ended=false;
  {
    Guard lock(p->reg);auto& s=*p->source;std::lock_guard<std::mutex> audio_lock(s.mutex);
    const double length=s.file->GetLength()/s.rate;
    const double now=clock_now?clock_now():0,at=audible_position(*p,now);
    ended=p->playing && !p->reg.loop && p->reg.curpos>=length && s.audible.drained(now-s.fx_latency);
    if(!std::strcmp(key,"D_POSITION"))*out=p->reg.loop && length>0 ? std::fmod(std::max(0.0,at),length) : std::clamp(at,0.0,length);
    else if(!std::strcmp(key,"D_RENDER_POSITION"))*out=p->reg.curpos;
    else if(!std::strcmp(key,"D_LENGTH"))*out=length;
    else if(!std::strcmp(key,"D_PLAYRATE"))*out=s.rate;
    else if(!std::strcmp(key,"D_PITCH"))*out=s.semitones;
    else if(!std::strcmp(key,"D_VOLUME"))*out=s.gain;
    else if(!std::strcmp(key,"B_PPITCH"))*out=s.preserve;
    else if(!std::strcmp(key,"B_LOOP"))*out=p->reg.loop;
    else if(!std::strcmp(key,"I_PITCHMODE"))*out=s.mode;
    else if(!std::strcmp(key,"I_CHANNELS"))*out=s.output_channels;
    else if(!std::strcmp(key,"I_SOURCECHANNELS"))*out=s.source_channels;
    else if(!std::strcmp(key,"B_DOWNMIX"))*out=s.downmix;
    else if(!std::strcmp(key,"I_DOWNMIX_MODE"))*out=s.downmix_mode;
    else if(!std::strcmp(key,"I_SELECTED_LEFT"))*out=s.selected_left;
    else if(!std::strcmp(key,"I_SELECTED_RIGHT"))*out=s.selected_right;
    else if(!std::strcmp(key,"I_WAVE_SEEK"))*out=p->wave_seek;
    else if(!std::strcmp(key,"D_MEASUREALIGN"))*out=p->measure_align;
    else return false;
  }
  if(ended){if(bound==handle)bound=nullptr;previews.erase(handle);return false;}return true;
}
bool set(void* handle,const char* key,double v) {
  auto p=get(handle);if(!p || !key || !std::isfinite(v))return false;
  Guard lock(p->reg);auto& s=*p->source;std::lock_guard<std::mutex> audio_lock(s.mutex);
  if(!std::strcmp(key,"D_POSITION")) {p->reg.curpos=std::max(0.0,v);s.reset=true;s.audible.clear();}
  else if(!std::strcmp(key,"B_LOOP"))p->reg.loop=v!=0;
  else if(!std::strcmp(key,"D_MEASUREALIGN"))p->measure_align=v;
  else if(!std::strcmp(key,"D_VOLUME") && v>=0)s.gain=v;
  else if(!std::strcmp(key,"D_FADEINLEN") && v>=0)s.fade_in=v;
  else if(!std::strcmp(key,"D_FADEOUTLEN") && v>=0)s.fade_out=v;
  else if(!std::strcmp(key,"D_PLAYRATE") && v>=.1 && v<=4) {
    if(s.rate!=v){if(p->reg.curpos>=0)p->reg.curpos*=s.rate/v;s.rate=v;s.reset=true;}
  } else if(!std::strcmp(key,"D_PITCH") && v>=-24 && v<=24) {
    if(s.semitones!=v){s.semitones=v;s.reset=true;}
  } else if(!std::strcmp(key,"B_PPITCH")) {
    if(s.preserve!=(v!=0)){s.preserve=v!=0;s.reset=true;}
  } else if(!std::strcmp(key,"I_PITCHMODE") && v>=std::numeric_limits<int>::min() && v<=std::numeric_limits<int>::max()) {
    if(s.mode!=v){s.mode=static_cast<int>(v);s.reset=true;}
  }
  else return false;
  return true;
}
void bind_preview(void* handle) { bound=get(handle)?handle:nullptr; }
bool latency_track(void* handle,void* track) {
  auto p=get(handle);if(!p || !valid_track(p->project,track,"MediaTrack*"))return false;
  p->fx_track=track;update_latency(*p,true);return true;
}
const char* diagnostics() {
  static char result[2048];auto p=get(bound);
  if(!p)return "{\"revision\":1,\"active\":false}";
  update_latency(*p);
  Guard lock(p->reg);auto& s=*p->source;std::lock_guard<std::mutex> audio_lock(s.mutex);
  std::snprintf(result,sizeof(result),"{\"revision\":1,\"active\":true,\"render_position\":%.9f,\"audible_position\":%.9f,\"first_position\":%.9f,\"first_callback\":%.9f,\"last_callback\":%.9f,\"transfer_latency\":%.9f,\"device_latency\":%.9f,\"fx_latency\":%.9f,\"absolute_time\":%.9f,\"max_callback_ms\":%.6f,\"blocks\":%llu,\"sample_rate\":%.0f,\"block_size\":%d,\"source_channels\":%d,\"output_channels\":%d,\"downmix\":%s,\"downmix_mode\":%d}",
    p->reg.curpos,audible_position(*p,clock_now?clock_now():0),s.first_position,s.first_callback,s.last_callback,s.transfer_latency,s.device_latency,s.fx_latency,s.absolute_time,s.max_callback_ms,s.blocks,s.sample_rate,s.block_size,s.source_channels,s.output_channels,s.downmix?"true":"false",s.downmix_mode);
  return result;
}
bool waveform(void* handle,const char* path,double length,double a,double b,bool reverse) {
  auto p=get(handle);
  if(!p || !path || !std::isfinite(length) || !std::isfinite(a) || !std::isfinite(b) ||
      length<=0 || a<0 || b<=a || b>length)return false;
  p->wave_path=path;p->wave_length=length;p->wave_a=a;p->wave_b=b;p->wave_reverse=reverse;
  return true;
}
void* create_var(void** p,int n){return n==3?create(static_cast<PCM_source*>(p[0]),p[1],p[2]):nullptr;}
void* create_channels_var(void** p,int n){return n==4?create_with_channels(static_cast<PCM_source*>(p[0]),p[1],p[2],p[3]!=nullptr):nullptr;}
void* create_selection_var(void** p,int n){
  if(n!=5)return nullptr;
  const auto left=reinterpret_cast<intptr_t>(p[3]),right=reinterpret_cast<intptr_t>(p[4]);
  if(left<1 || left>128 || right<1 || right>128)return nullptr;
  return create_with_selection(static_cast<PCM_source*>(p[0]),p[1],p[2],static_cast<int>(left),static_cast<int>(right));
}
void* create_subset_var(void** p,int n){return n==4?create_with_subset(static_cast<PCM_source*>(p[0]),p[1],p[2],static_cast<const char*>(p[3])):nullptr;}
void* create_downmix_var(void** p,int n){
  if(n!=4)return nullptr;
  const auto mode=reinterpret_cast<intptr_t>(p[3]);
  return mode>=0 && mode<=2?create_with_downmix(static_cast<PCM_source*>(p[0]),p[1],p[2],static_cast<int>(mode)):nullptr;
}
void* play_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==1 && play(p[0])));}
void* stop_var(void** p,int n){if(n==1)stop(p[0]);return nullptr;}
void* get_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==3 && value(p[0],static_cast<const char*>(p[1]),static_cast<double*>(p[2]))));}
void* set_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==3 && set(p[0],static_cast<const char*>(p[1]),*static_cast<double*>(p[2]))));}
void* bind_var(void** p,int n){if(n==1)bind_preview(p[0]);return nullptr;}
void* diagnostics_var(void**,int){return const_cast<char*>(diagnostics());}
void* latency_track_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==2 && latency_track(p[0],p[1])));}
void* waveform_var(void** p,int n){return reinterpret_cast<void*>(static_cast<intptr_t>(n==6 &&
  waveform(p[0],static_cast<const char*>(p[1]),*static_cast<double*>(p[2]),*static_cast<double*>(p[3]),
    *static_cast<double*>(p[4]),p[5]!=nullptr)));}
}

extern "C" bool AMPreviewWaveSeek(const char* path,double fraction,double a,double b,unsigned sequence) {
  if(!std::isfinite(fraction) || !std::isfinite(a) || !std::isfinite(b))return false;
  auto p=get(bound);if(!p || !path || !am_path_equal(p->wave_path.c_str(),path) || p->wave_length<=0)return false;
  // A changed selection requires Lua to rebuild the SECTION. Never seek using
  // old range bounds, or apply a click belonging to the previously loaded file.
  if(std::abs(a*p->wave_length-p->wave_a)>1e-6 || std::abs(b*p->wave_length-p->wave_b)>1e-6)return false;
  Guard lock(p->reg);auto& s=*p->source;std::lock_guard<std::mutex> audio_lock(s.mutex);
  const double source=std::clamp(fraction*p->wave_length,p->wave_a,p->wave_b);
  const double at=(p->wave_reverse ? p->wave_b-source : source-p->wave_a)/s.rate;
  p->reg.curpos=std::clamp(at,0.0,std::max(0.0,(p->wave_b-p->wave_a)/s.rate-1/48000.0));
  // Explicit seeks keep the native immediate click/pause bookmark. Resume
  // audible tracking from the new block when it reaches the output.
  s.reset=true;s.audible.clear();p->wave_seek=sequence;return true;
}
extern "C" int AMPreviewWavePosition(char* path,int size,double* fraction,double* position,double* length) {
  if(!path || size<1 || !fraction || !position || !length)return 0;
  auto p=get(bound);if(!p || !p->playing || p->wave_length<=0)return 0;
  update_latency(*p);
  // Never wait for the audio thread, or hold its mutex while painting.
  if(!am_preview_trylock(p->reg))return -1;
  auto& s=*p->source;
  if(!s.mutex.try_lock()){am_preview_unlock(p->reg);return -1;}
  const double duration=(p->wave_b-p->wave_a)/s.rate;
  const double heard=audible_position(*p,clock_now?clock_now():0);
  const double at=p->reg.loop && duration>0 ? std::fmod(std::max(0.0,heard),duration) : std::clamp(heard,0.0,duration);
  *fraction=(p->wave_reverse ? p->wave_b-at*s.rate : p->wave_a+at*s.rate)/p->wave_length;
  *position=at;*length=duration;
  s.mutex.unlock();am_preview_unlock(p->reg);
  std::snprintf(path,size,"%s",p->wave_path.c_str());return 1;
}
extern "C" void AMPreviewControl(void* window) {
  if(!bound || !find_child || !get_title || !toggle_state)return;
  // Called after native notifications, including Cocoa knob tracking while
  // Lua defer is suspended. No focus changes, text writes or event swallowing.
  double factor=1;
  if(media_info && master_tempo && toggle_state(32063,40019)!=1) {
    char path[4096]{},extra[128]{};int mode=0;double a=0,b=0,pitch=0,gain=0,rate=1,bpm=0;
    if(media_info(path,sizeof(path),&mode,&a,&b,&pitch,&gain,&rate,&bpm,extra,sizeof(extra)) && bpm>0) {
      const double multiplier=(mode&16)?.5:((mode&32)?2:((mode&8)?1:0));
      if(multiplier>0)factor=master_tempo()/bpm*multiplier;
    }
  }
  for(auto control: {std::pair<int,const char*>{1021,"D_PITCH"},{1454,"D_PLAYRATE"}}) {
    char text[64]{};auto child=find_child(window,control.first);if(!child)continue;
    get_title(child,text,sizeof(text));char* end=nullptr;const double v=std::strtod(text,&end);
    if(end!=text && *end==0)set(bound,control.second,v*(control.first==1454?factor:1));
  }
  const int state=toggle_state(32063,40068);if(state>=0)set(bound,"B_PPITCH",state);
  // A short section can finish before Lua's next defer tick. Commit Repeat
  // with the native button/action, just like Pitch/Rate, before reaching EOF.
  const int repeat=toggle_state(32063,1068);if(repeat>=0)set(bound,"B_LOOP",repeat);
}
extern "C" void AMPreviewUnbind(){bound=nullptr;}
extern "C" void AMPreviewClose(){
  if(timer_registered){register_host("-timer",reinterpret_cast<void*>(retire_tick));timer_registered=false;}
  bound=nullptr;previews.clear();retiring.clear();
}
extern "C" void AMPreviewRegister(int(*reg)(const char*,void*),void*(*get_func)(const char*)) {
  lookup=get_func;
  register_host=reg;
  struct Api {const char* name;void* function;void* vararg;const char* definition;};
  const Api apis[]={
    {"AM_Preview_Diagnostics",reinterpret_cast<void*>(diagnostics),reinterpret_cast<void*>(diagnostics_var),"const char*\0\0\0Read timing diagnostics for the active preview as JSON."},
    {"AM_Preview_SetLatencyTrack",reinterpret_cast<void*>(latency_track),reinterpret_cast<void*>(latency_track_var),"bool\0void*,MediaTrack*\0preview,track\0Bind the owned live FX chain for audible-position compensation."},
    {"AM_Preview_SetWaveform",reinterpret_cast<void*>(waveform),reinterpret_cast<void*>(waveform_var),"bool\0void*,const char*,double,double,double,bool\0preview,path,length,start,end,reverse\0Bind original-file coordinates for immediate native waveform seeking."},
    {"AM_Preview_Create",reinterpret_cast<void*>(create),reinterpret_cast<void*>(create_var),"void*\0PCM_source*,ReaProject*,MediaTrack*\0source,project,track\0Create an unbuffered transform preview; duplicates source. Stop releases it."},
    {"AM_Preview_CreateWithChannels",reinterpret_cast<void*>(create_with_channels),reinterpret_cast<void*>(create_channels_var),"void*\0PCM_source*,ReaProject*,MediaTrack*,bool\0source,project,track,downmix\0Create a preview for 1-128 source channels. Downmix averages odd channels to L and even channels to R; otherwise retains source channels. Mono remains dual mono. Stop releases the duplicated source."},
    {"AM_Preview_CreateWithChannelSubset",reinterpret_cast<void*>(create_with_subset),reinterpret_cast<void*>(create_subset_var),"void*\0PCM_source*,ReaProject*,MediaTrack*,const char*\0source,project,track,channels\0Pack comma-separated 1-based source channels before pitch/rate. One channel plays centered; multiple channels remain independent."},
    {"AM_Preview_CreateWithChannelSelection",reinterpret_cast<void*>(create_with_selection),reinterpret_cast<void*>(create_selection_var),"void*\0PCM_source*,ReaProject*,MediaTrack*,int,int\0source,project,track,left,right\0Select 1-based source channels for stereo L/R before pitch and rate. Equal indices play one microphone centered. Stop releases the duplicated source."},
    {"AM_Preview_CreateWithDownmix",reinterpret_cast<void*>(create_with_downmix),reinterpret_cast<void*>(create_downmix_var),"void*\0PCM_source*,ReaProject*,MediaTrack*,int\0source,project,track,mode\0Create a preview with immutable downmix mode: 0 retains channels, 1 averages odd/even channels, 2 previews AmbiX ACN/SN3D as L=(W+Y)/2 and R=(W-Y)/2. Mode 2 requires full-sphere square channel counts 4-121 and ignores other components. Stop releases the duplicated source."},
    {"AM_Preview_Play",reinterpret_cast<void*>(play),reinterpret_cast<void*>(play_var),"bool\0void*\0preview\0Start the owned preview."},
    {"AM_Preview_Stop",reinterpret_cast<void*>(stop),reinterpret_cast<void*>(stop_var),"void\0void*\0preview\0Release the handle; finish any short fade before destroying the audio source."},
    {"AM_Preview_GetValue",reinterpret_cast<void*>(value),reinterpret_cast<void*>(get_var),"bool\0void*,const char*,double*\0preview,name,valueOut\0Read preview state; false after end-of-file, releasing the handle."},
    {"AM_Preview_SetValue",reinterpret_cast<void*>(set),reinterpret_cast<void*>(set_var),"bool\0void*,const char*,double\0preview,name,value\0Update at the next device block; rate changes retain source position."},
    {"AM_Preview_BindControls",reinterpret_cast<void*>(bind_preview),reinterpret_cast<void*>(bind_var),"void\0void*\0previewOptional\0Follow the attached native Pitch/Rate controls synchronously."},
  };
  for(const auto& api:apis)for(int i=0;i<3;++i) {
    const std::string key=std::string(i==0?"API_":i==1?"APIvararg_":"APIdef_")+api.name;
    reg(key.c_str(),i==0?api.function:i==1?api.vararg:const_cast<char*>(api.definition));
  }
}
