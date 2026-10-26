#pragma once
#include <array>
#include <algorithm>
#include <cstddef>

// Audio writes and UI reads under the Source mutex. Store source coordinates
// with each block so queued audio keeps its position across rate/seek/loop changes.
// Fixed storage: no allocations, OS calls or UI work in the audio callback.
class PreviewClock {
  struct Block {double heard_at,begin,end,rate;};
  std::array<Block,4096> blocks{};
  std::size_t next=0,count=0;
public:
  void clear(){next=count=0;}
  void push(double callback,double latency,double position,double duration,double rate) {
    blocks[next]={callback+latency,position*rate,(position+duration)*rate,rate};
    next=(next+1)%blocks.size();count=std::min(count+1,blocks.size());
  }
  bool position(double now,double* source) const {
    if(!count)return false;
    for(std::size_t i=0;i<count;++i) {
      const auto& b=blocks[(next+blocks.size()-1-i)%blocks.size()];
      if(now>=b.heard_at) {
        *source=std::clamp(b.begin+(now-b.heard_at)*b.rate,b.begin,b.end);return true;
      }
    }
    *source=blocks[(next+blocks.size()-count)%blocks.size()].begin;return true;
  }
  bool drained(double now) const {
    if(!count)return true;
    const auto& b=blocks[(next+blocks.size()-1)%blocks.size()];
    return now>=b.heard_at+(b.end-b.begin)/b.rate;
  }
};
