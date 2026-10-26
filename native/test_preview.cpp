#include <thread>
#include <atomic>
#include "preview.cpp"
#include <cassert>
#include <iostream>
#include <vector>

static int destroyed=0,stopped=0,started=0;
static bool track_exists=true;
static bool project_playing=false;
static int repeat_state=0;
static preview_register_t* registered=nullptr;
static double test_clock=0;
static bool pitch_available=true;
static int live_pitch=0,retire_timers=0;
static void (*retire_callback)()=nullptr;
class TestFile final : public PCM_source {
public:
  double duration=1;
  int source_channels=1;
  int signal=0,max_decode_frames=0;
  std::array<double,128> components{};
  bool duplicate_available=true;
  ~TestFile() override {++destroyed;}
  PCM_source* Duplicate() override {return duplicate_available?new TestFile(*this):nullptr;}
  bool IsAvailable() override {return true;}
  const char* GetType() override {return "WAVE";}
  bool SetFileName(const char*) override {return false;}
  int GetNumChannels() override {return source_channels;}
  double GetSampleRate() override {return 48000;}
  double GetLength() override {return duration;}
  int PropertiesWindow(HWND) override {return 0;}
  void GetSamples(PCM_source_transfer_t* b) override {
    b->samples_out=std::clamp(static_cast<int>((duration-b->time_s)*b->samplerate),0,b->length);
    max_decode_frames=std::max(max_decode_frames,b->length);
    if(signal) {
      assert(b->nch==source_channels);
      const auto start=static_cast<long long>(std::llround(b->time_s*b->samplerate));
      for(int i=0;i<b->samples_out;++i)for(int c=0;c<b->nch;++c)
        b->samples[static_cast<std::size_t>(i)*b->nch+c]=signal==1?static_cast<double>(c+1)/source_channels:
          signal==2?(start+i==c+7?1:0):signal==3?1:signal==5?components[c]:-1;
    } else std::fill(b->samples,b->samples+b->samples_out*b->nch,.25);
  }
  void GetPeakInfo(PCM_source_peaktransfer_t*) override {}
  void SaveState(ProjectStateContext*) override {}
  int LoadState(const char*,ProjectStateContext*) override {return 0;}
  void Peaks_Clear(bool) override {}
  int PeaksBuild_Begin() override {return 0;}
  int PeaksBuild_Run() override {return 0;}
  void PeaksBuild_Finish() override {}
};
class TestPitch final : public IReaperPitchShift {
  std::vector<double> data=std::vector<double>(8192*128);
  int count=0,nch=2,offset=0;
public:
  TestPitch(){++live_pitch;}
  ~TestPitch() override {--live_pitch;}
  void set_srate(double) override {}
  void set_nch(int n) override {nch=n;}
  void set_shift(double) override {}
  void set_formant_shift(double) override {}
  void set_tempo(double) override {}
  void Reset() override {count=offset=0;}
  double* GetBuffer(int) override {return data.data();}
  void BufferDone(int n) override {count=n;offset=0;}
  void FlushSamples() override {}
  bool IsReset() override {return count==0;}
  int GetSamples(int wanted,double* dest) override {
    int n=std::min(wanted,count);std::copy_n(data.data()+offset*nch,n*nch,dest);count-=n;offset+=n;return n;
  }
  void SetQualityParameter(int) override {}
  int configured_channels() const {return nch;}
};
static void* api(const char* name) {
  if(!std::strcmp(name,"time_precise"))return reinterpret_cast<void*>(+[](){return test_clock;});
  if(!std::strcmp(name,"PlayTrackPreview2Ex"))return reinterpret_cast<void*>(+[](void*,preview_register_t* r,int flags,double align){assert(flags==0 && align<0);registered=r;++started;return 1;});
  if(!std::strcmp(name,"StopTrackPreview2"))return reinterpret_cast<void*>(+[](void*,preview_register_t*){registered=nullptr;++stopped;return 1;});
  if(!std::strcmp(name,"StartPreviewFade"))return reinterpret_cast<void*>(+[](void*,preview_register_t*,double seconds,int flags){assert(seconds==.01 && flags==2);return 1;});
  if(!std::strcmp(name,"ValidatePtr"))return reinterpret_cast<void*>(+[](void* p,const char*){return p!=nullptr;});
  if(!std::strcmp(name,"ValidatePtr2"))return reinterpret_cast<void*>(+[](void*,void*,const char*){return track_exists;});
  if(!std::strcmp(name,"PCM_Source_Destroy"))return reinterpret_cast<void*>(+[](PCM_source* p){delete p;});
  if(!std::strcmp(name,"ReaperGetPitchShiftAPI"))return reinterpret_cast<void*>(+[](int version)->IReaperPitchShift*{assert(version==0x14);return pitch_available?new TestPitch:nullptr;});
  if(!std::strcmp(name,"GetPlayStateEx"))return reinterpret_cast<void*>(+[](void*){return project_playing?1:0;});
  if(!std::strcmp(name,"GetPlayPosition2Ex"))return reinterpret_cast<void*>(+[](void*){return .25;});
  if(!std::strcmp(name,"TimeMap2_timeToBeats"))return reinterpret_cast<void*>(+[](void*,double,int* measure,int*,double*,int*){*measure=0;return .5;});
  if(!std::strcmp(name,"TimeMap_GetMeasureInfo"))return reinterpret_cast<void*>(+[](void*,int measure,double*,double*,int*,int*,double*){return measure*2.0;});
  return nullptr;
}
int main() {
  // Display the block that has reached the output, including queued rate,
  // seek and loop transitions. Never interpolate across a discontinuity.
  PreviewClock clock;double heard=0;
  assert(!clock.position(10,&heard));
  clock.push(10,.1,0,.02,1);
  assert(clock.position(10.05,&heard) && heard==0);
  assert(clock.position(10.11,&heard) && std::abs(heard-.01)<1e-9);
  clock.push(10.02,.1,4,.02,.5);
  assert(clock.position(10.119,&heard) && std::abs(heard-.019)<1e-9);
  assert(clock.position(10.13,&heard) && std::abs(heard-2.005)<1e-9);
  clock.push(10.04,.1,0,.02,.5);
  assert(clock.position(10.145,&heard) && std::abs(heard-.0025)<1e-9);
  assert(!clock.drained(10.15) && clock.drained(10.17));
  clock.clear();assert(!clock.position(10.15,&heard));
  for(int i=0;i<5000;++i)clock.push(20+i*.01,.2,i*.01,.01,1);
  assert(clock.position(70.195,&heard) && std::abs(heard-49.995)<1e-9);
  lookup=api;TestFile file;int project,track;
  {
    TestFile multi;multi.source_channels=128;multi.signal=1;
    for(const char* csv:{"1,3,5","32,64,96,128","128","127,128","5,2"}) {
      std::vector<int> selected;assert(amchannels::parse(csv,selected));
      auto h=create_with_subset(&multi,&project,&track,csv);assert(h);
      const int count=std::max(2,static_cast<int>(selected.size()));
      auto source=get(h)->source.get();assert(source->GetNumChannels()==count);
      std::vector<double> samples(16385*128,-1);
      PCM_source_transfer_t transfer{};transfer.samplerate=48000;transfer.length=16385;transfer.nch=128;transfer.samples=samples.data();
      source->GetSamples(&transfer);assert(transfer.samples_out==16385);
      for(int i=0;i<transfer.samples_out;++i)for(int c=0;c<128;++c) {
        const double expected=c<count?static_cast<double>(selected[std::min(c,static_cast<int>(selected.size())-1)])/128:0;
        assert(std::abs(samples[i*128+c]-expected)<1e-12);
      }
      stop(h);
    }
    for(const char* csv:{"","0","129","1,1","1,","3,2,1"})assert(!create_with_subset(&multi,&project,&track,csv));
    multi.source_channels=6;assert(!create_with_subset(&multi,&project,&track,"1,7"));
  }
  destroyed=0;

  void* h=create(&file,&project,&track);assert(h && destroyed==0);
  assert(set(h,"D_FADEINLEN",.001));assert(play(h) && registered && started==1);
  assert(set(h,"D_POSITION",.4));assert(set(h,"D_PLAYRATE",.5));
  double v=0;assert(value(h,"D_POSITION",&v) && v==.8);assert(value(h,"D_LENGTH",&v) && v==2);
  assert(waveform(h,"/fixture.wav",1,.2,.8,false));bind_preview(h);
  assert(AMPreviewWaveSeek("/fixture.wav",.4,.2,.8,7));
  assert(value(h,"D_POSITION",&v) && std::abs(v-.4)<1e-9 && value(h,"I_WAVE_SEEK",&v) && v==7);
  assert(!AMPreviewWaveSeek("/other.wav",.4,.2,.8,8));
  assert(!AMPreviewWaveSeek("/fixture.wav",.4,0,1,8));
  assert(waveform(h,"/fixture.wav",1,.2,.8,true));
  assert(AMPreviewWaveSeek("/fixture.wav",.7,.2,.8,9));assert(value(h,"D_POSITION",&v) && std::abs(v-.2)<1e-9);
  // Invalid host coordinates must not poison the saved seek or consume a new
  // sequence. A NaN fails ordered comparisons, so range checks alone do not suffice.
  for(double invalid:{NAN,INFINITY,-INFINITY}) {
    assert(!AMPreviewWaveSeek("/fixture.wav",invalid,.2,.8,10));
    assert(!AMPreviewWaveSeek("/fixture.wav",.7,invalid,.8,10));
    assert(!AMPreviewWaveSeek("/fixture.wav",.7,.2,invalid,10));
    assert(value(h,"D_POSITION",&v) && std::abs(v-.2)<1e-9);
    assert(value(h,"I_WAVE_SEEK",&v) && v==9);
  }
  char path[64]{};double fraction=0,position=0,length=0;
  assert(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==1);
  assert(std::string(path)=="/fixture.wav" && std::abs(fraction-.7)<1e-9 && std::abs(position-.2)<1e-9 && std::abs(length-1.2)<1e-9);
  std::atomic<bool> locked{false},release{false};
  std::thread audio([&]{am_preview_lock(*registered);locked=true;while(!release.load())std::this_thread::yield();am_preview_unlock(*registered);});
  while(!locked.load())std::this_thread::yield();
  assert(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==-1);
  release=true;audio.join();
  locked=false;release=false;
  std::thread source_lock([&]{std::lock_guard<std::mutex> lock(get(h)->source->mutex);locked=true;while(!release.load())std::this_thread::yield();});
  while(!locked.load())std::this_thread::yield();
  assert(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==-1);
  release=true;source_lock.join();
  assert(AMPreviewWavePosition(nullptr,sizeof(path),&fraction,&position,&length)==0);
  assert(AMPreviewWavePosition(path,0,&fraction,&position,&length)==0);
  assert(AMPreviewWavePosition(path,sizeof(path),nullptr,&position,&length)==0);
  assert(set(h,"D_MEASUREALIGN",1));assert(value(h,"D_MEASUREALIGN",&v) && v==1);
  assert(set(h,"D_POSITION",.8));
  assert(!set(h,"D_PLAYRATE",0) && !set(h,"D_PITCH",INFINITY));
  // SetQualityParameter's public ABI takes an int. Preserve that complete
  // representable range and reject values which cannot be converted safely.
  for(double mode:{static_cast<double>(std::numeric_limits<int>::min()),static_cast<double>(std::numeric_limits<int>::max()),-1.0}) {
    assert(set(h,"I_PITCHMODE",mode));assert(value(h,"I_PITCHMODE",&v) && v==mode);
  }
  for(double invalid:{static_cast<double>(std::numeric_limits<int>::max())+1,
      static_cast<double>(std::numeric_limits<int>::min())-1,1e100,-1e100}) {
    assert(!set(h,"I_PITCHMODE",invalid));assert(value(h,"I_PITCHMODE",&v) && v==-1);
  }
  assert(set(h,"D_PITCH",-4) && set(h,"D_VOLUME",2));
  std::array<double,1024> samples{};
  PCM_source_transfer_t block{};block.time_s=.8;block.samplerate=48000;block.nch=2;block.length=512;block.samples=samples.data();
  registered->src->GetSamples(&block);assert(block.samples_out==512);
  for(double sample:samples)assert(std::isfinite(sample) && sample>=0 && sample<=.5);
  assert(samples.back()==.5);
  assert(set(h,"B_LOOP",1));assert(set(h,"D_POSITION",2));assert(value(h,"D_POSITION",&v));
  assert(set(h,"B_LOOP",0));assert(!value(h,"D_POSITION",&v));assert(stopped==1 && destroyed==1);
  stop(h);assert(stopped==1);assert(!play(h));
  assert(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==0);
  void* next=create(&file,&project,&track);assert(next!=h && play(next));track_exists=false;
  assert(!value(next,"D_POSITION",&v));assert(stopped==2 && destroyed==2);
  track_exists=true;project_playing=true;
  void* aligned=create(&file,&project,&track);assert(set(aligned,"D_MEASUREALIGN",1) && play(aligned));
  assert(std::abs(registered->curpos+1.75)<1e-9);
  assert(value(aligned,"D_POSITION",&v) && v==0);
  assert(set(aligned,"D_PLAYRATE",.5));assert(std::abs(registered->curpos+1.75)<1e-9);
  block.time_s=-32.0/48000;block.length=128;
  registered->src->GetSamples(&block);assert(block.samples_out==128);
  for(int i=0;i<64;++i)assert(samples[i]==0);
  assert(samples[255]>.2);stop(aligned);
  project_playing=false;
  void* onset=create(&file,&project,&track);assert(play(onset));
  block.time_s=0;block.length=128;registered->src->GetSamples(&block);
  assert(samples[0]==.25); // No implicit zero/fade on the first transient.
  block.time_s=0;registered->src->GetSamples(&block);
  assert(samples[0]==.25); // A natural loop must not lose its attack either.
  // Repeat must reach the active audio registration before Lua polls EOF.
  bind_preview(onset);
  find_child=+[](void*,int)->void*{return nullptr;};
  get_title=+[](void*,char*,int){return 0;};
  toggle_state=+[](int,int command){return command==1068?repeat_state:-1;};
  repeat_state=1;AMPreviewControl(&project);assert(registered->loop);
  repeat_state=-1;AMPreviewControl(&project);assert(registered->loop);
  repeat_state=0;AMPreviewControl(&project);assert(!registered->loop);
  stop(onset);
  // PCM_source_transfer_t uses frames, with nch interleaved samples per frame.
  // Unit gain and no fades must preserve a constant .25 decoder output exactly
  // across host sample-rate, output-channel-count and device block-size changes.
  // These callback output widths do not imply multichannel source support.
  void* changing=create(&file,&project,&track);auto* source=get(changing)->source.get();
  for(double sample_rate:{8000.0,44100.0,48000.0,96000.0,192000.0})for(int channels:{1,2,128})for(int frames:{1,63,128,1024}) {
    std::vector<double> guarded(static_cast<std::size_t>(frames)*channels+2,-123.0);
    block={};block.samples=guarded.data()+1;block.length=frames;block.nch=channels;block.samplerate=sample_rate;
    source->GetSamples(&block);assert(block.samples_out==frames);
    assert(guarded.front()==-123 && guarded.back()==-123);
    for(std::size_t i=1;i+1<guarded.size();++i)assert(guarded[i]==.25);
    assert(source->sample_rate==sample_rate && source->channels==channels);
  }
  block={};block.samples=samples.data();block.length=128;block.nch=2;block.samplerate=48000;
  samples.fill(-123);
  for(double invalid:{NAN,INFINITY,-INFINITY}) {
    block.time_s=invalid;block.samples_out=42;source->GetSamples(&block);assert(block.samples_out==0);
    block.time_s=0;block.samplerate=invalid;block.samples_out=42;source->GetSamples(&block);assert(block.samples_out==0);
    block.samplerate=48000;
  }
  block.samplerate=1e100;source->GetSamples(&block);assert(block.samples_out==0);
  block.samplerate=48000;block.samples=nullptr;source->GetSamples(&block);assert(block.samples_out==0);
  source->GetSamples(nullptr);
  for(double sample:samples)assert(sample==-123);
  // Creating/destroying independent previews while a callback runs must not
  // race the callback's API lookup or disturb this instance's source/settings.
  std::atomic<bool> done{false},rendered{false};
  std::thread rendering([&]{
    std::array<double,512> buffer{};PCM_source_transfer_t transfer{};
    transfer.samples=buffer.data();transfer.samplerate=48000;transfer.nch=2;transfer.length=256;
    while(!done.load()) {
      source->GetSamples(&transfer);assert(transfer.samples_out==256);
      for(double sample:buffer)assert(sample==.25);
      rendered=true;
    }
  });
  while(!rendered.load())std::this_thread::yield();
  for(int i=0;i<32;++i) {
    void* independent=create(&file,&project,&track);assert(independent && independent!=changing);
    assert(set(independent,"D_PITCH",12) && set(independent,"D_VOLUME",.5));stop(independent);
  }
  done=true;rendering.join();stop(changing);
  // The duration diagnostic covers callback entry to completion, including
  // simulated lock delay, without moving the audible clock's render timestamp.
  const auto saved_clock=clock_now;
  clock_now=+[]{static int read=0;const double times[]={0,.05,.051};return times[std::min(read++,2)];};
  {
    Source timed(&file);block={};block.samples=samples.data();block.length=128;block.nch=2;block.samplerate=48000;
    timed.GetSamples(&block);
    assert(timed.first_callback==.05 && std::abs(timed.max_callback_ms-51)<1e-9);
  }
  clock_now=saved_clock;
  // Source channel counts are a separate contract from callback output nch:
  // only mono/stereo sources are accepted, even when the host requests more
  // output channels. Rejected sources must not replace an existing preview.
  for(int supported:{1,2}) {
    file.source_channels=supported;
    void* active=create(&file,&project,&track);assert(active && play(active));
    assert(get(active)->source->file->GetNumChannels()==supported);
    assert(get(active)->source->GetNumChannels()==2);
    assert(waveform(active,"/supported.wav",1,0,1,false));bind_preview(active);
    assert(set(active,"D_POSITION",.25));
    auto* active_registration=registered;
    const auto active_count=previews.size();const auto last_serial=serial;
    const int active_pitch=live_pitch,active_starts=started,active_stops=stopped;
    for(int unsupported:{3,4,6,8,64,128}) {
      file.source_channels=unsupported;
      const int before_rejection=destroyed;
      assert(!create(&file,&project,&track));
      assert(destroyed==before_rejection+1 && live_pitch==active_pitch);
      assert(file.GetNumChannels()==unsupported && file.IsAvailable());
      assert(previews.size()==active_count && serial==last_serial);
      assert(started==active_starts && stopped==active_stops && registered==active_registration);
      assert(bound==active && get(active)->playing);
      assert(value(active,"D_POSITION",&v) && v==.25);
      assert(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==1);
      assert(std::string(path)=="/supported.wav" && fraction==.25);
    }
    stop(active);assert(previews.empty() && live_pitch==0 && !bound && !registered);
    // Retry on the same caller-owned source after rejection must still work.
    file.source_channels=supported;
    void* recovered=create(&file,&project,&track);assert(recovered && play(recovered));
    block={};block.samples=samples.data();block.length=128;block.nch=2;block.samplerate=48000;
    registered->src->GetSamples(&block);assert(block.samples_out==128);
    for(int i=0;i<256;++i)assert(samples[i]==.25);
    stop(recovered);assert(previews.empty() && live_pitch==0);
  }
  file.source_channels=1;
  // The opt-in API retains every original multichannel stream when off and
  // explicitly averages odd/even channels before the pitch stage when on.
  // Neither mapping may depend on the host's requested interleaved width.
  for(int original:{3,4,6,8,128})for(bool downmix:{false,true}) {
    file.source_channels=original;file.duration=10;file.signal=1;
    void* multichannel=create_with_channels(&file,&project,&track,downmix);assert(multichannel);
    auto* multichannel_source=get(multichannel)->source.get();
    const int width=downmix?2:original;
    assert(multichannel_source->GetNumChannels()==width);
    assert(value(multichannel,"I_SOURCECHANNELS",&v) && v==original);
    assert(value(multichannel,"I_CHANNELS",&v) && v==width);
    assert(value(multichannel,"B_DOWNMIX",&v) && (v!=0)==downmix);
    assert(value(multichannel,"I_DOWNMIX_MODE",&v) && v==(downmix?1:0));
    assert(!set(multichannel,"B_DOWNMIX",!downmix));
    assert(!set(multichannel,"I_DOWNMIX_MODE",2));
    const auto* decoded_buffer=multichannel_source->decoded.data();
    const auto* processed_buffer=multichannel_source->processed.data();
    struct Callback {double sample_rate;int channels,frames;double time,pitch,rate,gain;};
    for(const Callback callback: {
      Callback{48000,width,257,0,0,1,1},
      Callback{44100,128,8207,0,0,1,.5},
      Callback{96000,1,67,0,7,.5,1},
      Callback{48000,128,17011,0,7,2,.25},
      Callback{48000,width,513,.137,7,1,.5}}) {
      assert(set(multichannel,"D_PITCH",callback.pitch) && set(multichannel,"D_PLAYRATE",callback.rate));
      assert(set(multichannel,"D_VOLUME",callback.gain) && set(multichannel,"D_POSITION",callback.time));
      std::vector<double> guarded(static_cast<std::size_t>(callback.frames)*callback.channels+2,-123.0);
      block={};block.samples=guarded.data()+1;block.length=callback.frames;block.nch=callback.channels;
      block.samplerate=callback.sample_rate;block.time_s=callback.time;
      multichannel_source->GetSamples(&block);assert(block.samples_out==callback.frames);
      assert(guarded.front()==-123 && guarded.back()==-123);
      const int transition=callback.time>0?static_cast<int>(callback.sample_rate*.001):0;
      for(int i=0;i<callback.frames;++i)for(int c=0;c<callback.channels;++c) {
        const double actual=block.samples[static_cast<std::size_t>(i)*callback.channels+c];
        assert(std::isfinite(actual) && actual>=0 && actual<=1);
        double expected=0;
        if(c<width) {
          if(downmix) {
            for(int original_channel=c;original_channel<original;original_channel+=2)
              expected+=static_cast<double>(original_channel+1)/original/((original+(c==0?1:0))/2);
          } else expected=static_cast<double>(c+1)/original;
          expected*=callback.gain;
        }
        if(i>=transition)assert(std::abs(actual-expected)<1e-12);
      }
      assert(static_cast<TestPitch*>(multichannel_source->pitch.get())->configured_channels()==width);
      assert(multichannel_source->decoded.data()==decoded_buffer && multichannel_source->processed.data()==processed_buffer);
      assert(static_cast<TestFile*>(multichannel_source->file)->max_decode_frames<=Source::chunk_frames);
    }
    stop(multichannel);
    // Distinct, single-channel impulses prove that no channel is omitted and
    // that parity averaging happens before the mock pitch engine receives it.
    file.signal=2;
    for(double pitch_shift:{0.0,7.0})for(double playback_rate:{1.0,.5}) {
      multichannel=create_with_channels(&file,&project,&track,downmix);assert(multichannel);
      assert(set(multichannel,"D_PITCH",pitch_shift) && set(multichannel,"D_PLAYRATE",playback_rate));
      assert(set(multichannel,"D_VOLUME",.75));
      std::vector<double> guarded(static_cast<std::size_t>(256)*width+2,-123);
      block={};block.samples=guarded.data()+1;block.length=256;block.nch=width;block.samplerate=48000;
      get(multichannel)->source->GetSamples(&block);assert(block.samples_out==256);
      assert(guarded.front()==-123 && guarded.back()==-123);
      for(int i=0;i<256;++i)for(int c=0;c<width;++c) {
        double expected=0;const int original_channel=i-7;
        if(original_channel>=0 && original_channel<original) {
          if(downmix && c==original_channel%2)expected=.75/((original+(c==0?1:0))/2);
          else if(!downmix && c==original_channel)expected=.75;
        }
        assert(std::abs(block.samples[static_cast<std::size_t>(i)*width+c]-expected)<1e-12);
      }
      stop(multichannel);
    }
  }
  // Coherent positive and negative full-scale input stays exactly full scale,
  // even with unequal odd/even group sizes. No channel-count gain boost.
  for(int original:{3,4,6,8,127,128})for(int signal:{3,4}) {
    file.source_channels=original;file.signal=signal;
    void* full_scale=create_with_channels(&file,&project,&track,true);assert(full_scale);
    block={};block.samples=samples.data();block.length=128;block.nch=2;block.samplerate=48000;
    get(full_scale)->source->GetSamples(&block);assert(block.samples_out==128);
    for(int i=0;i<256;++i)assert(samples[i]==(signal==3?1:-1));
    stop(full_scale);
  }
  // AmbiX W/Y is a separate immutable mapping, never the odd/even average.
  // Pure W is centered, matching W/+Y is left, matching W/-Y is right, and
  // the other spherical-harmonic components cannot leak into this preview.
  for(int original:{4,9,16,25,36,49,64,81,100,121}) {
    file.source_channels=original;file.duration=10;file.signal=5;
    for(const auto wy:{std::pair<double,double>{1,0},{1,1},{1,-1},{0,1},{0,-1},{-1,1},{-1,-1},{0,0}})
      for(double pitch_shift:{0.0,7.0})for(double playback_rate:{1.0,.5,2.0}) {
        file.components.fill(1);file.components[0]=wy.first;file.components[1]=wy.second;
        void* ambix=create_with_downmix(&file,&project,&track,2);assert(ambix);
        assert(value(ambix,"I_SOURCECHANNELS",&v) && v==original);
        assert(value(ambix,"I_CHANNELS",&v) && v==2);
        assert(value(ambix,"I_DOWNMIX_MODE",&v) && v==2);
        assert(value(ambix,"B_DOWNMIX",&v) && v==1);
        assert(!set(ambix,"I_DOWNMIX_MODE",1) && !set(ambix,"B_DOWNMIX",0));
        assert(set(ambix,"D_PITCH",pitch_shift) && set(ambix,"D_PLAYRATE",playback_rate));
        auto* ambix_source=get(ambix)->source.get();
        const auto* decoded_buffer=ambix_source->decoded.data();
        const auto* processed_buffer=ambix_source->processed.data();
        for(int host_channels:{1,2,8}) {
          std::vector<double> guarded(8207*host_channels+2,-123);
          block={};block.samples=guarded.data()+1;block.length=8207;block.nch=host_channels;block.samplerate=48000;
          ambix_source->GetSamples(&block);assert(block.samples_out==8207);
          assert(guarded.front()==-123 && guarded.back()==-123);
          for(int i=0;i<block.samples_out;++i)for(int c=0;c<host_channels;++c) {
            const double expected=c==0?.5*(wy.first+wy.second):c==1?.5*(wy.first-wy.second):0;
            const double actual=block.samples[static_cast<std::size_t>(i)*host_channels+c];
            assert(std::isfinite(actual) && std::abs(actual)<=1 && actual==expected);
          }
          assert(static_cast<TestPitch*>(ambix_source->pitch.get())->configured_channels()==2);
          assert(ambix_source->decoded.data()==decoded_buffer && ambix_source->processed.data()==processed_buffer);
          assert(static_cast<TestFile*>(ambix_source->file)->max_decode_frames<=Source::chunk_frames);
        }
        stop(ambix);
      }
    // Distinct component impulses reveal every ignored component individually,
    // including all higher orders, before the mock pitch stage consumes them.
    file.signal=2;
    for(double pitch_shift:{0.0,7.0}) {
      void* ambix=create_with_downmix(&file,&project,&track,2);assert(ambix);
      assert(set(ambix,"D_PITCH",pitch_shift) && set(ambix,"D_VOLUME",.75));
      block={};block.samples=samples.data();block.length=256;block.nch=2;block.samplerate=48000;
      get(ambix)->source->GetSamples(&block);assert(block.samples_out==256);
      for(int i=0;i<256;++i)for(int c=0;c<2;++c) {
        const double expected=i==7?.375:i==8?(c==0?.375:-.375):0;
        assert(block.samples[2*i+c]==expected);
      }
      stop(ambix);
    }
  }
  // Rejected AmbiX layouts/modes never replace or disturb a live handle, its
  // waveform binding, or the caller-owned source. No half-created API handle
  // escapes, and retries using the same source remain valid.
  file.source_channels=4;file.signal=5;file.components.fill(0);file.components[0]=1;
  void* active_ambix=create_with_downmix(&file,&project,&track,2);assert(active_ambix && play(active_ambix));
  assert(waveform(active_ambix,"/ambix.wav",1,0,1,false));bind_preview(active_ambix);
  assert(set(active_ambix,"D_POSITION",.25));
  auto* ambix_registration=registered;
  const auto ambix_count=previews.size(),ambix_serial=serial;
  const int ambix_pitch=live_pitch,ambix_starts=started,ambix_stops=stopped;
  auto active_unchanged=[&] {
    assert(previews.size()==ambix_count && serial==ambix_serial && live_pitch==ambix_pitch);
    assert(started==ambix_starts && stopped==ambix_stops && registered==ambix_registration);
    assert(bound==active_ambix && get(active_ambix)->playing);
    assert(value(active_ambix,"D_POSITION",&v) && v==.25);
    assert(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==1);
    assert(std::string(path)=="/ambix.wav" && fraction==.25);
  };
  for(int invalid:{-1,0,1,2,3,5,6,7,8,10,15,17,63,120,122,127,128,129,144,std::numeric_limits<int>::max()}) {
    file.source_channels=invalid;const int before_rejection=destroyed;
    assert(!create_with_downmix(&file,&project,&track,2));
    assert(destroyed==before_rejection+1 && file.GetNumChannels()==invalid && file.IsAvailable());
    active_unchanged();
  }
  file.source_channels=4;
  for(int invalid:{std::numeric_limits<int>::min(),-1,3,std::numeric_limits<int>::max()}) {
    const int before_rejection=destroyed;assert(!create_with_downmix(&file,&project,&track,invalid));
    assert(destroyed==before_rejection);active_unchanged();
  }
  stop(active_ambix);assert(previews.empty() && live_pitch==0 && !bound && !registered);
  // New modes 0/1 retain the original and odd/even contracts, including the
  // established mono/stereo decoder path; mode2 never infers a format there.
  file.signal=0;
  for(int original:{1,2,3,4,128})for(int mix:{0,1}) {
    file.source_channels=original;
    void* compatible=create_with_downmix(&file,&project,&track,mix);assert(compatible);
    assert(value(compatible,"I_CHANNELS",&v) && v==(mix?2:std::max(2,original)));
    assert(value(compatible,"I_DOWNMIX_MODE",&v) && v==mix);
    block={};block.samples=samples.data();block.length=128;block.nch=2;block.samplerate=48000;
    get(compatible)->source->GetSamples(&block);assert(block.samples_out==128);
    for(int i=0;i<256;++i)assert(samples[i]==.25);
    stop(compatible);
  }
  // Finite source tails preserve frame counts and never touch the unrendered
  // portion of a host buffer, including when pitch buffering is flushed.
  file.source_channels=3;file.signal=1;file.duration=128.0/48000;
  for(bool downmix:{false,true})for(double pitch_shift:{0.0,7.0}) {
    void* tail=create_with_channels(&file,&project,&track,downmix);assert(tail);
    assert(set(tail,"D_PITCH",pitch_shift));
    std::vector<double> guarded(256*8+2,-123);
    block={};block.samples=guarded.data()+1;block.length=256;block.nch=8;block.samplerate=48000;
    get(tail)->source->GetSamples(&block);assert(block.samples_out==128);
    assert(guarded.front()==-123);
    for(std::size_t i=128*8+1;i<guarded.size();++i)assert(guarded[i]==-123);
    stop(tail);
  }
  for(int invalid:{-1,0,129,std::numeric_limits<int>::max()}) {
    file.source_channels=invalid;
    const int before_rejection=destroyed;
    assert(!create_with_channels(&file,&project,&track,true));
    assert(destroyed==before_rejection+1 && live_pitch==0 && previews.empty());
  }
  file.source_channels=1;file.duration=1;file.signal=0;
  for(int original:{1,2})for(bool downmix:{false,true}) {
    file.source_channels=original;
    void* compatible=create_with_channels(&file,&project,&track,downmix);assert(compatible);
    assert(get(compatible)->source->GetNumChannels()==2);stop(compatible);
  }
  file.source_channels=1;
  for(int original:{1,2,3,6,128})for(int left:{1,original})for(int right:{1,original}) {
    file.source_channels=original;file.signal=1;file.duration=2;
    void* selected=create_with_selection(&file,&project,&track,left,right);assert(selected);
    assert(value(selected,"I_SELECTED_LEFT",&v) && v==left);
    assert(value(selected,"I_SELECTED_RIGHT",&v) && v==right);
    assert(value(selected,"I_CHANNELS",&v) && v==2);
    assert(value(selected,"B_DOWNMIX",&v) && v==0);
    for(int host:{1,2,8,128})for(double pitch:{0.,7.}) {
      assert(set(selected,"D_PITCH",pitch));assert(set(selected,"D_POSITION",0));
      assert(set(selected,"D_PLAYRATE",pitch? .5:1));
      std::vector<double> audio(8209*host+2,-123.);
      block={};block.samples=audio.data()+1;block.length=8209;block.nch=host;block.samplerate=48000;
      get(selected)->source->GetSamples(&block);assert(block.samples_out==8209);
      for(int f=0;f<block.samples_out;++f)for(int ch=0;ch<host;++ch) {
        const double expected=ch==0?double(left)/original:ch==1?double(right)/original:0;
        assert(std::abs(block.samples[f*host+ch]-expected)<1e-12);
      }
      assert(audio.front()==-123. && audio.back()==-123.);
    }
    stop(selected);
    assert(!create_with_selection(&file,&project,&track,0,1));
    assert(!create_with_selection(&file,&project,&track,original+1,1));
  }
  file.source_channels=1;file.signal=0;file.duration=1;
  // Source duplication and pitch allocation failures release every resource
  // already acquired; the caller's source remains available for retry.
  const int before_failure=destroyed;
  file.duplicate_available=false;assert(!create(&file,&project,&track));
  assert(destroyed==before_failure && live_pitch==0);file.duplicate_available=true;
  pitch_available=false;assert(!create(&file,&project,&track));
  assert(destroyed==before_failure+1 && live_pitch==0);pitch_available=true;
  file.duration=INFINITY;assert(!create(&file,&project,&track));
  assert(destroyed==before_failure+2 && live_pitch==0);file.duration=1;
  // Stop invalidates the public handle immediately, while a successful host
  // fade owns its source until the documented fade interval has elapsed.
  register_host=+[](const char* name,void* callback){
    if(*name=='-'){--retire_timers;retire_callback=nullptr;}
    else {++retire_timers;retire_callback=reinterpret_cast<void(*)()>(callback);}
    return 1;
  };
  void* fading=create(&file,&project,&track);assert(set(fading,"D_FADEOUTLEN",.01) && play(fading));
  const int before_fade=destroyed,stops_before_fade=stopped;
  stop(fading);assert(!play(fading) && !value(fading,"D_POSITION",&v));
  assert(destroyed==before_fade && stopped==stops_before_fade && retiring.size()==1 && retire_timers==1);
  test_clock=.009;retire_callback();assert(destroyed==before_fade && retiring.size()==1);
  test_clock=.01;retire_callback();
  assert(destroyed==before_fade+1 && stopped==stops_before_fade+1 && retiring.empty() && retire_timers==0);
  // Both native and ReaScript vararg registration expose the opt-in channel
  // contract. The older 3-argument API keeps rejecting multichannel input.
  static std::unordered_map<std::string,void*> apis;
  AMPreviewRegister(+[](const char* name,void* function){apis[name]=function;return 1;},api);
  assert(apis.count("API_AM_Preview_Create") && apis.count("APIdef_AM_Preview_CreateWithChannels"));
  assert(apis.count("APIdef_AM_Preview_CreateWithDownmix"));
  auto registered_create=reinterpret_cast<void*(*)(PCM_source*,void*,void*,bool)>(apis.at("API_AM_Preview_CreateWithChannels"));
  auto registered_vararg=reinterpret_cast<void*(*)(void**,int)>(apis.at("APIvararg_AM_Preview_CreateWithChannels"));
  file.source_channels=6;
  void* via_api=registered_create(&file,&project,&track,false);assert(via_api);
  assert(value(via_api,"I_CHANNELS",&v) && v==6);stop(via_api);
  void* arguments[]={&file,&project,&track,reinterpret_cast<void*>(1)};
  assert(!registered_vararg(arguments,3));
  via_api=registered_vararg(arguments,4);assert(via_api);
  assert(value(via_api,"I_CHANNELS",&v) && v==2 && value(via_api,"B_DOWNMIX",&v) && v==1);
  assert(value(via_api,"I_DOWNMIX_MODE",&v) && v==1);
  bind_preview(via_api);
  assert(std::strstr(diagnostics(),"\"source_channels\":6") && std::strstr(diagnostics(),"\"downmix\":true"));
  stop(via_api);
  auto registered_downmix=reinterpret_cast<void*(*)(PCM_source*,void*,void*,int)>(apis.at("API_AM_Preview_CreateWithDownmix"));
  auto registered_downmix_vararg=reinterpret_cast<void*(*)(void**,int)>(apis.at("APIvararg_AM_Preview_CreateWithDownmix"));
  file.source_channels=4;
  via_api=registered_downmix(&file,&project,&track,2);assert(via_api);
  assert(value(via_api,"I_DOWNMIX_MODE",&v) && v==2);stop(via_api);
  arguments[3]=reinterpret_cast<void*>(2);
  assert(!registered_downmix_vararg(arguments,3));
  via_api=registered_downmix_vararg(arguments,4);assert(via_api);
  assert(value(via_api,"I_CHANNELS",&v) && v==2 && value(via_api,"B_DOWNMIX",&v) && v==1);
  assert(value(via_api,"I_DOWNMIX_MODE",&v) && v==2);
  bind_preview(via_api);
  assert(std::strstr(diagnostics(),"\"source_channels\":4") && std::strstr(diagnostics(),"\"downmix_mode\":2"));
  stop(via_api);
  for(intptr_t invalid:{static_cast<intptr_t>(-1),static_cast<intptr_t>(3),std::numeric_limits<intptr_t>::max()}) {
    arguments[3]=reinterpret_cast<void*>(invalid);assert(!registered_downmix_vararg(arguments,4));
  }
  arguments[3]=reinterpret_cast<void*>(2);file.source_channels=6;
  assert(!registered_downmix_vararg(arguments,4));file.source_channels=1;
  auto selected_vararg=reinterpret_cast<void*(*)(void**,int)>(apis.at("APIvararg_AM_Preview_CreateWithChannelSelection"));
  file.source_channels=6;
  void* selected_args[]={&file,&project,&track,reinterpret_cast<void*>(5),reinterpret_cast<void*>(2)};
  assert(!selected_vararg(selected_args,4));
  via_api=selected_vararg(selected_args,5);assert(via_api);
  assert(value(via_api,"I_SELECTED_LEFT",&v) && v==5);stop(via_api);
  selected_args[3]=reinterpret_cast<void*>(std::numeric_limits<intptr_t>::max());assert(!selected_vararg(selected_args,5));
  AMPreviewClose();assert(previews.empty() && live_pitch==0);
  std::cout<<"PASS: unbuffered preview, ownership, source bookmarks, numeric bounds, audio output, sample-rate/block/output-channel changes, legacy multichannel rejection, 3/4/6/8/128-channel preservation and downmix, AmbiX W/Y M/S for 4-121 square channels, distinct impulses, pitch input mapping, bounded scratch, concurrent instances, EOF, stale handles, deleted tracks\n";
}
