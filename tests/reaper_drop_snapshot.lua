-- Exercise capture/prepare_captured with real REAPER takes in the owned host.
-- A controlled tempo-match factor checks the frozen effective playback rate.
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app');local M=require('am.model')
local app,done,frame=nil,false,0
local file='/tmp/audition-macro-dev/media-fixtures/test.wav'
local data=r.GetResourcePath()..'/snapshot-test-'..U.hash(r.genGuid());r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(r.GetResourcePath()..'/drop-snapshot.txt','w'));f:setvbuf('no')
local context,result=r.AM_DropContext,r.AM_DropResult
local Explorer=require('am.media_explorer');local tempo_factor=Explorer.tempo_factor
local function finish(ok,err)
 done=true;r.AM_DropContext=context;r.AM_DropResult=result
 Explorer.tempo_factor=tempo_factor
 if app then app:close()end
 f:write(ok and 'PASS\n' or 'FAIL '..tostring(err)..'\n');f:close()
end
local function invoke(phase,items)
 local acknowledged=false
 r.AM_DropContext=function()return J.encode{id=1,phase=phase,origin='waveform',path=file,paths={file},items=items or {},
   preview={path=file,mode=256,start=.2,['end']=.7}}end
 r.AM_DropResult=function(value)acknowledged=value end
 dofile(root..'/internal/Process waveform drop.lua')
 r.AM_DropContext=context;r.AM_DropResult=result
 assert(acknowledged,r.GetExtState('AuditionMacro.Drop.v1','message'))
end
local ok,err=xpcall(function()
 r.Main_OnCommand(41929,0);r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
 r.InsertTrackAtIndex(0,false);App.initialize(r,root,data)
 local bank=M.defaults();bank.settings.autoplay=false
 for _,macro in ipairs(bank.macros)do macro.normalization.enabled=false end
 assert(M.save(data..'/bank.json',bank));app=App.new(r,root,data);r.OpenMediaExplorer(file,false)
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
 local ok,err=xpcall(function()
  frame=frame+1;app:tick();if frame<10 then return end
  app:activate('heavy');app:tick();app.drop:tick()
  local project=r.EnumProjects(-1);local tabs=0;while r.EnumProjects(tabs)do tabs=tabs+1 end
  Explorer.tempo_factor=function()return 1.5 end
  invoke('capture');Explorer.tempo_factor=tempo_factor
  assert(r.EnumProjects(-1)==project and not r.EnumProjects(tabs) and r.CountMediaItems(0)==0,'Capture changed the project')
  -- Change the live Macro after capture. The inserted item must use the snapshot.
  app:activate('dark');app:tick();app.drop:tick()
  local item=r.AddMediaItemToTrack(r.GetTrack(0,0));local take=r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(take,r.PCM_Source_CreateFromFile(file));r.SetMediaItemInfo_Value(item,'D_LENGTH',1)
  local _,guid=r.GetSetMediaItemInfo_String(item,'GUID','',false)
  invoke('prepare_captured',{guid});invoke('finish',{guid})
  assert(r.CountTakes(item)==2)
  assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-.5/(.72*1.5))<1e-8,'Frozen range/tempo-match rate was lost')
  assert(math.abs(r.GetMediaItemTakeInfo_Value(r.GetActiveTake(item),'D_STARTOFFS')-.2/(.72*1.5))<1e-8)
  local _,json=r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(item),'P_EXT:AuditionMacro','',false)
  assert(J.decode(json).macro==M.find(app.definition,'heavy').name,'Live Macro replaced frozen Macro')
  invoke('discard');finish(true)
 end,debug.traceback)
 if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
