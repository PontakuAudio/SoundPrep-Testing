// Deterministic PCM regression and callback microbenchmark. REAPER's decoder
// and pitch shifter are fixtures: this cannot certify real FX or device audio.
// Compile this same file with -I <revision>/native to compare two revisions.
#include "preview.cpp"
#include <cassert>
#include <chrono>
#include <ctime>
#include <fstream>
#include <iostream>
#include <numeric>

class Signal final : public PCM_source {
public:
  PCM_source* Duplicate() override {return new Signal;}
  bool IsAvailable() override {return true;}
  const char* GetType() override {return "TEST";}
  bool SetFileName(const char*) override {return false;}
  int GetNumChannels() override {return 2;}
  double GetSampleRate() override {return 48000;}
  double GetLength() override {return 120;}
  int PropertiesWindow(HWND) override {return 0;}
  void GetSamples(PCM_source_transfer_t* b) override {
    b->samples_out=b->length;
    // Integer-valued periodic source, exactly representable in binary. Includes
    // positive/negative samples and silence without libm differences.
    const auto start=static_cast<long long>(std::llround(b->time_s*b->samplerate));
    for(int i=0;i<b->length;++i)for(int c=0;c<b->nch;++c)
      b->samples[i*b->nch+c]=((start+i+c*17)%127-63)/128.0;
  }
  void GetPeakInfo(PCM_source_peaktransfer_t*) override {}
  void SaveState(ProjectStateContext*) override {}
  int LoadState(const char*,ProjectStateContext*) override {return 0;}
  void Peaks_Clear(bool) override {}
  int PeaksBuild_Begin() override {return 0;}
  int PeaksBuild_Run() override {return 0;}
  void PeaksBuild_Finish() override {}
};
class CopyPitch final : public IReaperPitchShift {
  std::array<double,8192*2> data{};
  int count=0,offset=0,nch=2;
public:
  void set_srate(double) override {}
  void set_nch(int n) override {assert(n<=2);nch=n;}
  void set_shift(double) override {}
  void set_formant_shift(double) override {}
  void set_tempo(double) override {}
  void Reset() override {count=offset=0;}
  double* GetBuffer(int n) override {assert(n<=8192);return data.data();}
  void BufferDone(int n) override {count=n;offset=0;}
  void FlushSamples() override {}
  bool IsReset() override {return count==0;}
  int GetSamples(int n,double* dest) override {
    n=std::min(n,count);std::copy_n(data.data()+offset*nch,n*nch,dest);
    count-=n;offset+=n;return n;
  }
  void SetQualityParameter(int) override {}
};
int main(int argc,char** argv) {
  assert(argc==2);std::ofstream pcm(argv[1],std::ios::binary);assert(pcm);
  make_pitch=+[](int)->IReaperPitchShift*{return new CopyPitch;};
  destroy_source=+[](PCM_source* s){delete s;};
  clock_now=+[]{return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();};
  Signal file;std::vector<double> timings;size_t samples=0;int cases=0;
  const auto cpu_start=std::clock();
  for(double sr:{44100.,48000.,96000.,192000.})for(int size:{1,32,64,127,512,2048,8192})
    for(int nch:{1,2})for(int mode:{0,1,2}) {
      Source source(&file);source.rate=mode==1?.5:mode==2?2:1;
      source.semitones=mode==2?7:0;source.gain=.75;
      source.fade_in=.003;source.fade_out=.005;
      std::vector<double> output(size*nch+2,12345.0);
      PCM_source_transfer_t block{};block.samples=output.data()+1;
      block.samplerate=sr;block.nch=nch;block.length=size;
      for(int i=0;i<48;++i) {
        if(i==24){block.samplerate=sr==192000?44100:192000;block.time_s=.125;}
        const auto start=std::chrono::steady_clock::now();
        source.GetSamples(&block);
        const double us=std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-start).count();
        assert(block.samples_out==size && output.front()==12345 && output.back()==12345);
        for(int j=0;j<size*nch;++j)assert(std::isfinite(block.samples[j]));
        if(i>=8)timings.push_back(us);
        pcm.write(reinterpret_cast<const char*>(block.samples),size*nch*sizeof(double));
        samples+=size*nch;block.time_s+=size/block.samplerate;
      }
      ++cases;
    }
  const double cpu_seconds=double(std::clock()-cpu_start)/CLOCKS_PER_SEC;
  assert(pcm.good());std::sort(timings.begin(),timings.end());
  std::cout<<"{\"cases\":"<<cases<<",\"samples\":"<<samples
    <<",\"callbacks\":"<<timings.size()<<",\"mean_us\":"
    <<std::accumulate(timings.begin(),timings.end(),0.0)/timings.size()
    <<",\"p95_us\":"<<timings[timings.size()*95/100]
    <<",\"p99_us\":"<<timings[timings.size()*99/100]
    <<",\"max_us\":"<<timings.back()<<",\"fixture_cpu_seconds\":"<<cpu_seconds<<"}\n";
}
