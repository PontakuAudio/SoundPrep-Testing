// Offline development probe using the production loudness kernels.
// Input: interleaved little-endian float64 PCM at 48 kHz, 1 or 2 channels.
// Audio stays local. Build without fast-math and with -ffp-contract=off.
#include "../native/zwicker.h"
#include "../native/lufs_meter.h"
#include "../native/vendor/json.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>

int main(int argc,char** argv) try {
  if(argc<3)throw std::runtime_error("Usage: probe pcm.f64 channels [target_sones ...]");
  const int channels=std::stoi(argv[2]);
  if(channels<1 || channels>2)throw std::runtime_error("Probe expects mono/stereo PCM");
  std::ifstream in(argv[1],std::ios::binary|std::ios::ate);
  if(!in)throw std::runtime_error("Cannot open PCM");
  const auto bytes=in.tellg();
  if(bytes<=0 || bytes%static_cast<int>(sizeof(double)*channels))throw std::runtime_error("Invalid PCM size");
  std::vector<double> samples(static_cast<std::size_t>(bytes)/sizeof(double));
  in.seekg(0);in.read(reinterpret_cast<char*>(samples.data()),bytes);
  if(!in)throw std::runtime_error("Incomplete PCM");
  const auto frames=samples.size()/channels;
  if(frames>48000*120)throw std::runtime_error("Use source files up to 120 seconds for this probe");
  amlufs::Meter meter(channels,channels==1);amlufs::TruePeak peak(channels,48000);
  meter.add(samples.data(),frames);peak.add(samples.data(),frames);peak.finish();
  samples.resize(samples.size()+19200*channels,0);meter.add(samples.data()+frames*channels,19200);
  const double lufs=meter.max_momentary_lufs(),tp=peak.dbtp();
  if(!std::isfinite(lufs) || !std::isfinite(tp))throw std::runtime_error("Silent source");
  const double reference_gain=std::min({-18-lufs,18.0,-1-tp});
  const double scale=20e-6*std::pow(10.0,(79-(-20))/20.0);
  std::vector<std::unique_ptr<amzwicker::Prepared>> prepared;
  for(int c=0;c<channels;++c) {
    std::vector<double> mono(samples.size()/channels);
    for(std::size_t f=0;f<mono.size();++f)mono[f]=samples[f*channels+c]*scale;
    prepared.push_back(std::make_unique<amzwicker::Prepared>(mono));
  }
  using Pair=std::pair<double,double>;
  std::map<double,Pair> cache;
  const auto evaluate=[&](double gain) {
    auto found=cache.find(gain);if(found!=cache.end())return found->second;
    auto values=prepared[0]->evaluate(gain);
    if(channels==2) {
      auto other=prepared[1]->evaluate(gain);
      for(std::size_t i=0;i<values.size();++i)values[i]=std::hypot(values[i],other[i]);
    }
    const Pair value{amzwicker::summarize(values,false),amzwicker::summarize(values,true)};
    cache.emplace(gain,value);return value;
  };
  const auto baseline=evaluate(reference_gain);
  using Json=nlohmann::json;
  Json result={{"duration",frames/48000.0},{"channels",channels},{"source_lufs_m_max",lufs},
    {"source_true_peak_dbtp",tp},{"reference_gain_db",reference_gain},{"reference_lufs_m_max",lufs+reference_gain},
    {"reference_peak_capped",reference_gain<-18-lufs-1e-7},
    {"reference_max_sones",baseline.first},{"reference_p95_sones",baseline.second},
    {"targets",Json::array()}};
  for(int arg=3;arg<argc;++arg) {
    const double target=std::stod(argv[arg]);
    if(!std::isfinite(target) || target<=0)throw std::runtime_error("Invalid sones target");
    Json entry={{"target_sones",target}};
    for(bool p95:{false,true}) {
      const auto value=[&](double db){const auto v=evaluate(db);return p95?v.second:v.first;};
      // Solve only inside the applied source gain range. The cap is identical
      // to Loudness.gain; a capped result explicitly need not reach the target.
      double low=-120,high=std::min(18.0,-1-tp);
      double gain=high;const bool capped=value(high)<target;
      if(!capped) {
        for(int i=0;i<20;++i) {
          gain=(low+high)/2;const double actual=value(gain);
          if(std::abs(actual-target)<=target*.0005)break;
          if(actual<target)low=gain;else high=gain;
        }
      }
      entry[p95?"p95":"max"]={{"gain_db",gain},{"lufs_m_max",lufs+gain},{"peak_dbtp",tp+gain},
        {"delta_reference_db",gain-reference_gain},{"achieved_sones",value(gain)},{"capped",capped}};
    }
    result["targets"].push_back(entry);
  }
  std::cout<<result.dump()<<'\n';return 0;
} catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
