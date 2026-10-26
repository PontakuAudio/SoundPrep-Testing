-- Real Cocoa/SWELL drops in the marked, muted host. Wait for native async peaks
-- before inspecting or undoing an item; do not block REAPER's event loop.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_TestDropAt') and r.APIExists('AM_TestWaveformDrop'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local M=require('am.model');local U=require('am.util')
local data=r.GetResourcePath()..'/drop-peaks-'..U.hash(r.genGuid());r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(r.GetResourcePath()..'/drop-peaks.txt','w'));f:setvbuf('no')
local app,done,frame,case,pending=nil,false,0,1,nil
local path='/tmp/audition-macro-dev/media-fixtures/test.wav'
local cases={}
for _,origin in ipairs{'list','waveform'}do
 for _,area in ipairs{'arrange','tcp row','tcp empty'}do cases[#cases+1]={origin=origin,area=area}end
end
local function finish(ok,err)
 if done then return end;done=true
 if app then app:close()end
 f:write(ok and 'PASS\n' or 'FAIL '..tostring(err)..'\n');f:close()
end
local ok,err=xpcall(function()
 r.Main_OnCommand(41929,0);r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
 r.InsertTrackAtIndex(0,false);r.SetMediaTrackInfo_Value(r.GetTrack(0,0),'I_HEIGHTOVERRIDE',100)
 r.TrackList_AdjustWindows(false)
 App.initialize(r,root,data);local bank=M.defaults();bank.settings.autoplay=false
 for _,m in ipairs(bank.macros)do m.normalization.enabled=false end
 bank.raw=M.raw_settings();assert(M.save(data..'/bank.json',bank))
 app=App.new(r,root,data);r.OpenMediaExplorer(path,false)
end,debug.traceback)
if not ok then finish(false,err);return end
local deadline=r.time_precise()+10
local function tick()
 local ok,err=xpcall(function()
  frame=frame+1
  if pending then
   app.drop.peaks:tick()
   local item=r.GetMediaItem(0,0);assert(item and r.CountTakes(item)==2)
   local take=r.GetActiveTake(item);assert(take==r.GetTake(item,1))
   local peaks=r.new_array(128);peaks.clear()
   local n=r.GetMediaItemTake_Peaks(take,100,r.GetMediaItemInfo_Value(item,'D_POSITION'),2,32,0,peaks)&0xfffff
   local max=0;for i=1,n*2 do max=math.max(max,math.abs(peaks[i]))end
   if n==0 or max<=.001 then assert(r.time_precise()<deadline,'Rendered waveform never became available');return end
   assert(r.Undo_CanUndo2(0)=='Insert SoundPrep')
   assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0 and r.CountTracks(0)==pending.tracks,'Undo split drop')
   if not pending.redone then
    assert(r.Undo_DoRedo2(0)==1 and r.CountMediaItems(0)==1);pending.redone=true;deadline=r.time_precise()+10;return
   end
   f:write(cases[case].origin,' / ',cases[case].area,': nonzero rendered peaks, 2 takes, Undo/Redo\n')
   pending=nil;case=case+1
   if case>#cases then finish(true)end
   return
  end
  app:tick()
  if frame==8 then
   for _,v in ipairs{{1455,'0:00.200'},{1456,'0:00.700'}}do
    local c=app.explorer:control(v[1]);r.JS_Window_SetFocus(c);r.JS_Window_SetTitle(c,v[2])
    r.BR_Win32_SendMessage(c,0x100,13,0);r.BR_Win32_SendMessage(c,0x101,13,0)
   end
  end
  if frame<9 then return end
  local ready,file,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
  if not(ready and file==path and mode&256~=0 and math.abs(a-.2)<.001 and math.abs(b-.7)<.001)then
   assert(r.time_precise()<deadline,'Native range not ready');return
  end
  local c=cases[case];app:activate('heavy');app:tick()
  app.definition.settings.insert_handles=c.area~='tcp empty';app.reverse_override=c.area=='tcp empty'
  app.effective_macro=nil;app.drop:tick()
  local source=app.explorer:control(c.origin=='list' and 1001 or 1046)
  local main=r.GetMainHwnd();local count=r.CountTracks(0);local accepted
  if c.area=='arrange' then
   accepted=r.AM_TestWaveformDrop(source,r.JS_Window_FindChildByID(main,1000),path)
  else
   local tcp=assert(r.JS_Window_FindEx(main,main,'REAPERTCPDisplay',''))
   local _,width,height=r.JS_Window_GetClientSize(tcp)
   accepted=r.AM_TestDropAt(source,main,tcp,math.floor(width/2),c.area=='tcp row' and 30 or math.floor(height-20),path)
  end
  assert(accepted,'Drop rejected: '..r.GetExtState('AuditionMacro.Drop.v1','message'))
  assert(r.CountMediaItems(0)==1)
  pending={tracks=count};deadline=r.time_precise()+10
 end,debug.traceback)
 if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
