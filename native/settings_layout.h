#pragma once
// Shared wording and layout keep both native renderers in step.
namespace amsettings {
enum Kind { toggle,number };
struct Control { const char* key;const char* label;const char* help;Kind kind;int page,y;double low,high; };
inline constexpr const char* pages[]={"Playback","Drops","Cache","Advanced"};
inline constexpr Control controls[]={
  {"autoplay","Follow file selection","Start preview when a new file is selected.",toggle,0,12,0,0},
  {"loop","Loop preview","Repeat the current preview or selected range.",toggle,0,78,0,0},
  {"monitor_gain_db","Monitor level (dB)","Listening level only; excluded from rendered media.",number,0,144,-60,0},
  {"preview_fade_ms","Preview edge fade (ms)","Fade the edges of preview playback.",number,0,230,0,50},
  {"auto_render_drops","Automatically render uncached drops","May stop playback and pause editing while rendering. Cached drops keep playing.",toggle,1,12,0,0},
  {"insert_handles","Retain processed audio outside the selected range","Off: render only the selected range. Source + FX keeps the entire original.",toggle,1,90,0,0},
  {"fade_ms","Rendered edge fade (ms)","Fade the edges of rendered drops.",number,1,168,0,50},
  {"keep_fx_running","Keep inactive FX processing","Uses more CPU. Keeps inactive preset FX running.",toggle,3,12,0,0}
};
inline constexpr int count=sizeof(controls)/sizeof(controls[0]);
}
