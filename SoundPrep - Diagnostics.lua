-- @description SoundPrep - Read-only installation diagnostics
-- @version 0.11.0
local r=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local P=require('am.platform');local U=require('am.util')
local lines={'SoundPrep diagnostics',require('am.native').describe(r), 'REAPER: '..r.GetAppVersion(), 'OS: '..r.GetOS(),
  'Resource: '..r.GetResourcePath(), 'Scripts: '..root}
local required={'CF_CreatePreview','CF_PCM_Source_SetSectionInfo','JS_Window_Find','JS_File_Stat',
  'MediaExplorerGetLastPlayedFileInfo','AM_TransportAttach','AM_Preview_Create','AM_WaveAttach','AM_WaveCursorState',
  'AM_BarAttach','AM_SearchRead','AM_SearchWrite','AM_DropAttachSources','AM_ExecutablePath','AM_Preview_SetLatencyTrack','AM_WaveDiagnostics',
  'AM_AnalysisStart','AM_AnalysisCancel','AM_AnalysisStatus'}
if P.windows(r)then required[#required+1]='AM_FileReplace';required[#required+1]='AM_PathEqual';required[#required+1]='AM_DropDiagnostics'end
for _,name in ipairs(required)do lines[#lines+1]=(r.APIExists(name) and 'OK      ' or 'MISSING ')..name end
for _,name in ipairs{P.helper_name(r)}do
  lines[#lines+1]=(r.file_exists(root..'/build/'..name) and 'OK      ' or 'MISSING ')..'package build/'..name
end
local helper=r.GetResourcePath()..'/UserPlugins/'..P.helper_name(r)
lines[#lines+1]=(r.file_exists(helper) and 'OK      ' or 'MISSING ')..'installed helper'
lines[#lines+1]='Analysis: native LUFS MaxM / Zwicker; Python and FFmpeg are not required.'
if r.APIExists('AM_BarGeometry')then lines[#lines+1]='Bar: '..r.AM_BarGeometry()end
if r.APIExists('AM_DropDiagnostics')then lines[#lines+1]='Windows drops: '..r.AM_DropDiagnostics()end
for _,name in ipairs{'IDENT_IN','IDENT_OUT','BSIZE','SRATE'}do
  local ok,value=r.GetAudioDeviceInfo(name)
  if ok then lines[#lines+1]='Audio '..name..': '..value end
end
lines[#lines+1]=('Reported device output latency: %.2f ms'):format(r.GetOutputLatency()*1000)
if r.APIExists('AM_Preview_Diagnostics')then lines[#lines+1]='Preview timing: '..r.AM_Preview_Diagnostics()end
if r.APIExists('AM_WaveDiagnostics')then lines[#lines+1]='Waveform seek: '..r.AM_WaveDiagnostics()end
if r.APIExists('AM_WaveCursorState')then lines[#lines+1]='Waveform cursor: '..r.AM_WaveCursorState()end
-- Inspect resource flags without serializing plug-in payloads or changing takes.
local selected=r.CountSelectedMediaItems(0)
lines[#lines+1]='Selected Timeline items: '..selected..' (inspect first 8)'
for i=0,math.min(selected,8)-1 do
  local item=r.GetSelectedMediaItem(0,i);local active=r.GetActiveTake(item)
  lines[#lines+1]=('  Item %d: takes=%d, play all takes=%s'):format(i+1,r.CountTakes(item),
    tostring(r.GetMediaItemInfo_Value(item,'B_ALLTAKESPLAY')~=0))
  for n=0,r.CountTakes(item)-1 do
    local take=r.GetTake(item,n);local count=r.TakeFX_GetCount(take);local offline=0
    for fx=0,count-1 do if r.TakeFX_GetOffline(take,fx)then offline=offline+1 end end
    local _,marker=r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacroSourceFX','',false)
    lines[#lines+1]=('    Take %d: active=%s, FX offline=%d/%d, source resource marker=%s, chain visible=%d')
      :format(n+1,tostring(take==active),offline,count,tostring(marker~=''),r.TakeFX_GetChainVisible(take))
  end
end
-- Only inspect the current session's owned tracks, never plugin state chunks.
local session=r.GetExtState('AuditionMacro.v1','session')
for i=0,r.CountTracks(0)-1 do
  local t=r.GetTrack(0,i);local _,owner=r.GetSetMediaTrackInfo_String(t,'P_EXT:AuditionMacroOwner','',false)
  if session~='' and owner==session then
    local _,name=r.GetTrackName(t);local _,mode=r.TrackFX_GetNamedConfigParm(t,0,'chain_pdc_mode')
    lines[#lines+1]=('Preview chain %s: live PDC mode=%s, output=%d'):format(name,mode,r.GetMediaTrackInfo_Value(t,'B_MAINSEND'))
    for fx=0,r.TrackFX_GetCount(t)-1 do
      local _,fxname=r.TrackFX_GetFXName(t,fx);local _,pdc=r.TrackFX_GetNamedConfigParm(t,fx,'pdc')
      lines[#lines+1]=('  %s: reported PDC %s samples'):format(fxname,pdc)
    end
  end
end
lines[#lines+1]='Timing uses REAPER/device/plugin reports; this is not a physical loopback measurement.'
r.ShowConsoleMsg(table.concat(lines,'\n')..'\n')
