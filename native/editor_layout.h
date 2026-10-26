#pragma once
#include <algorithm>
#include <cstring>
namespace ameditor {
// Direct preset buttons wrap by their native text width, above the editor actions.
struct PresetLayout {
 struct Rect {int x,y,w,h;};
 int x=0,y=0;
 Rect add(int textWidth){
   int width=std::clamp(textWidth+32,72,216);
   if(x && x+width>660){x=0;y+=36;}
   Rect r{x,y,width,30};x+=width+6;return r;
 }
 int height()const{return y+38;}
};
enum Kind { toggle,number,text,choice };
struct Control { const char* key;const char* label;Kind kind;int page,y;double low,high;bool macroOnly; };
inline constexpr const char* pages[]={"Sound","Normalize","Export options","Manage","Tools"};
inline constexpr const char* meters[]={"LUFS MaxM","Zwicker Max","Zwicker P95"};
inline constexpr const char* metrics[]={"lufs_m_max","zwicker_max","zwicker_p95"};
inline constexpr Control controls[]={
 {"name","Preset name",text,0,12,0,0,true},
 {"reverse","Reverse",toggle,0,58,0,0,false},
 {"pitch","Pitch (semitones)",number,0,96,-24,24,true},
 {"rate","Rate",number,0,142,.1,4,true},
 {"preserve","Preserve Pitch",toggle,0,192,0,0,false},
 {"gain","Output gain (dB)",number,0,234,-60,12,true},
 {"normalize","Normalize source",toggle,1,12,0,0,false},
 {"metric","Loudness meter",choice,1,50,0,0,false},
 {"lufs","Target (LUFS-M)",number,1,96,-60,0,false},
 {"sones","Target (sones)",number,1,142,.01,256,false},
 {"boost","Max boost (dB)",number,1,188,0,24,false},
 {"guard","Peak guard also when Normalize is off",toggle,1,234,0,0,false},
 {"ceiling","Source ceiling (dBTP)",number,1,272,-12,0,false},
 {"reference_dbfs","Calibration (dBFS)",number,1,318,-120,0,false},
 {"reference_spl","Calibration (dB SPL)",number,1,364,0,140,false},
 {"tail","Export tail (seconds)",number,2,12,0,30,true},
 {"final","Normalize final export to the LUFS target",toggle,2,62,0,0,true},
 {"limiter","Export true peak limiter",toggle,2,104,0,0,true},
 {"export_ceiling","Export ceiling (dBTP)",number,2,146,-12,0,true},
 {"slot","Action slot (0 = unassigned)",number,3,160,0,9,true},
 {"directory","Export directory",text,4,190,0,0,false}
};
inline constexpr int count=sizeof(controls)/sizeof(controls[0]);
struct Action {const char* op;const char* title;int page,x,y,w;bool macroOnly;};
inline constexpr Action actions[]={
 {"new","New preset",3,14,12,154,false},{"duplicate","Duplicate",3,184,12,154,true},
 {"up","Move up",3,14,58,154,true},{"down","Move down",3,184,58,154,true},
 {"import","Import FX chain…",3,14,104,154,true},{"delete","Delete preset…",3,184,104,154,true},
 {"confirm_delete","Confirm delete",3,14,258,154,true},{"cancel_delete","Keep preset",3,184,258,154,false},
 {"analyse","Analyse / refresh",4,14,126,168,false},{"render_drops","Render selected drops",4,198,126,190,false},
 {"directory_choose","Choose folder…",4,14,238,150,false},{"render","Render WAV",4,14,288,150,false},
 {"render_dialog","Native render settings…",4,180,288,204,false}
};
inline constexpr const char* help[]={
 "Changes audition live and stay when switching presets or closing this panel. Save preset stores the complete sound, including FX. Quit saves every preset.\n\nRaw saves normalization and peak guard. Its Reverse / Preserve Pitch switches are temporary.",
 "Source ceiling applies before pitch, rate and FX; use an FX limiter for output. Zwicker Max suits short effects; P95 includes silence. Calibration maps digital levels to SPL.",
 "These options are saved with the preset. Final export normalization uses the LUFS target; source Zwicker gain remains in preview, drops and exports. Monitor level is excluded.",
 "New, duplicate, order and action slots are saved immediately. Imported FX remain a draft until Save preset. Slots 1–9 switch presets; 0 is reserved for Raw.",
 "Stereo WAV, 48 kHz. Monitor level is excluded. A project and preset snapshot are saved beside the audio. Use Native render settings for other formats."
};
inline bool enabled(const Control& s,bool raw,bool zwicker){
 if(s.macroOnly && raw)return false;
 if(!strcmp(s.key,"lufs"))return !zwicker;
 if(!strcmp(s.key,"sones") || !strcmp(s.key,"reference_dbfs") || !strcmp(s.key,"reference_spl"))return zwicker;
 return true;
}
}
