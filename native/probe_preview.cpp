// Diagnostic fault injection, intentionally NOT a passing CI regression test.
// Build: clang++ -std=c++17 -O2 native/probe_preview.cpp -o /tmp/probe_preview
// Exit 1 means a known risk is still reproduced; stdout is diagnostic JSON.
// No REAPER process, real decoder, plugin, audio device or project is used.
#include "preview.cpp"
#include <atomic>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <thread>

static double probe_sample=.25;
class ProbeFile final:public PCM_source {
public:
  PCM_source* Duplicate() override{return new ProbeFile;}
  bool IsAvailable() override{return true;}
  const char* GetType() override{return "WAVE";}
  bool SetFileName(const char*) override{return false;}
  int GetNumChannels() override{return 1;}
  double GetSampleRate() override{return 48000;}
  double GetLength() override{return 1;}
  int PropertiesWindow(HWND) override{return 0;}
  void GetSamples(PCM_source_transfer_t* b) override {
    b->samples_out=b->length;
    std::fill_n(b->samples,static_cast<std::size_t>(b->length)*b->nch,probe_sample);
  }
  void GetPeakInfo(PCM_source_peaktransfer_t*) override{}
  void SaveState(ProjectStateContext*) override{}
  int LoadState(const char*,ProjectStateContext*) override{return -1;}
  void Peaks_Clear(bool) override{}
  int PeaksBuild_Begin() override{return 0;}
  int PeaksBuild_Run() override{return 0;}
  void PeaksBuild_Finish() override{}
};
// Unity rendering does not feed the pitch processor, but Source initializes it.
class ProbePitch final:public IReaperPitchShift {
public:
  void set_srate(double) override{}
  void set_nch(int) override{}
  void set_shift(double) override{}
  void set_formant_shift(double) override{}
  void set_tempo(double) override{}
  void Reset() override{}
  ReaSample* GetBuffer(int) override{std::abort();}
  void BufferDone(int) override{std::abort();}
  void FlushSamples() override{}
  bool IsReset() override{return true;}
  int GetSamples(int,ReaSample*) override{std::abort();}
  void SetQualityParameter(int) override{}
};
static void* probe_api(const char* name) {
  if(!std::strcmp(name,"time_precise"))return reinterpret_cast<void*>(+[](){
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
  });
  if(!std::strcmp(name,"PlayTrackPreview2Ex"))return reinterpret_cast<void*>(+[](void*,preview_register_t*,int,double){return 1;});
  if(!std::strcmp(name,"StopTrackPreview2"))return reinterpret_cast<void*>(+[](void*,preview_register_t*){return 1;});
  if(!std::strcmp(name,"ValidatePtr"))return reinterpret_cast<void*>(+[](void* p,const char*){return p!=nullptr;});
  if(!std::strcmp(name,"ValidatePtr2"))return reinterpret_cast<void*>(+[](void*,void* p,const char*){return p!=nullptr;});
  if(!std::strcmp(name,"PCM_Source_Destroy"))return reinterpret_cast<void*>(+[](PCM_source* p){delete p;});
  if(!std::strcmp(name,"ReaperGetPitchShiftAPI"))return reinterpret_cast<void*>(+[](int)->IReaperPitchShift*{return new ProbePitch;});
  return nullptr;
}
int main() {
  lookup=probe_api;ProbeFile file;int project=0,track=0;
  auto h=create(&file,&project,&track);if(!h)return 2;
  auto* source=get(h)->source.get();
  std::array<double,128> buffer{};PCM_source_transfer_t b{};
  b.samplerate=48000;b.samples=buffer.data();b.nch=2;b.length=64;
  probe_sample=std::numeric_limits<double>::quiet_NaN();source->GetSamples(&b);
  const int nan_first=static_cast<int>(std::count_if(buffer.begin(),buffer.end(),[](double x){return std::isnan(x);}));
  probe_sample=.25;b.time_s=64.0/48000;source->GetSamples(&b);
  const int nan_after=static_cast<int>(std::count_if(buffer.begin(),buffer.end(),[](double x){return std::isnan(x);}));
  stop(h);
  auto waiting=create(&file,&project,&track);if(!waiting)return 2;
  source=get(waiting)->source.get();b.time_s=0;
  std::atomic<bool> entering{false};double elapsed=0;
  source->mutex.lock();
  std::thread audio([&]{
    const auto start=std::chrono::steady_clock::now();entering=true;source->GetSamples(&b);
    elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  });
  while(!entering.load())std::this_thread::yield();
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  source->mutex.unlock();audio.join();
  const double reported=source->max_callback_ms;
  // Allow scheduling/clock overhead; omission of the injected 50 ms is decisive.
  const bool includes_wait=reported>=45;
  std::cout<<std::fixed<<std::setprecision(6)
    <<"{\"fixture_only\":true,\"nan_first_samples\":"<<nan_first
    <<",\"nan_after_finite_decoder_samples\":"<<nan_after
    <<",\"samples_per_block\":128,\"lock_probe_requested_hold_ms\":50,\"callback_wall_ms\":"<<elapsed
    <<",\"reported_max_callback_ms\":"<<reported
    <<",\"callback_duration_includes_wait\":"<<(includes_wait?"true":"false")<<"}\n";
  stop(waiting);
  return nan_after>0 || !includes_wait ? 1 : 0;
}
