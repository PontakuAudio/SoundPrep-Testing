-- Real Cocoa/SWELL drop routing in the marked, muted host only.
-- SWELL delivers TCP file drops to the main content view. The TCP child itself
-- does not accept native file drops in REAPER 7.80.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_TestDropAt'),'Rebuild the isolated-host drop fixture')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local J=require('am.json')
local data=r.GetResourcePath()..'/tcp-drop-test';r.RecursiveCreateDirectory(data,0)
local log=assert(io.open(data..'/tcp-drop.txt','w'));log:setvbuf('no')
local app,done,frame=nil,false,0
local path='/tmp/audition-macro-dev/media-fixtures/test.wav'
local function finish(ok,err)
 if done then return end;done=true
 if app then app:close()end
 log:write(ok and 'PASS\n' or 'FAIL '..tostring(err)..'\n');log:close()
end
local ok,err=xpcall(function()
 assert(r.CountMediaItems(0)==0 and r.CountTracks(0)==0,'Use an empty disposable project')
 r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
 r.InsertTrackAtIndex(0,false);r.SetMediaTrackInfo_Value(r.GetTrack(0,0),'I_HEIGHTOVERRIDE',100)
 r.TrackList_AdjustWindows(false)
 App.initialize(r,root,data);local b=Model.defaults();b.settings.autoplay=false
 for _,m in ipairs(b.macros)do m.normalization.enabled=false end
 b.raw=Model.raw_settings();assert(Model.save(data..'/bank.json',b))
 app=App.new(r,root,data);r.OpenMediaExplorer(path,false)
end,debug.traceback)
if not ok then finish(false,err);return end
local deadline=r.time_precise()+10
local function tick()
 local ok,err=xpcall(function()
  frame=frame+1;app:tick()
  if frame==8 then
   for _,v in ipairs{{1455,'0:00.200'},{1456,'0:00.700'}}do
    local c=app.explorer:control(v[1]);r.JS_Window_SetFocus(c);r.JS_Window_SetTitle(c,v[2])
    r.BR_Win32_SendMessage(c,0x100,13,0);r.BR_Win32_SendMessage(c,0x101,13,0)
   end
  end
  if frame<9 then return end
  local ready,loaded,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
  if not(ready and loaded==path and mode&256~=0 and math.abs(a-.2)<.001 and math.abs(b-.7)<.001)then
   assert(r.time_precise()<deadline,'Native range not ready');return
  end
  app:activate('heavy');app:tick()
  local main=r.GetMainHwnd();local tcp=assert(r.JS_Window_FindEx(main,main,'REAPERTCPDisplay',''))
  local _,width,height=r.JS_Window_GetClientSize(tcp)
  local x=math.floor(width/2)
  local function invoke(source,destination,y)
   return r.AM_TestDropAt(source,destination,tcp,x,y,path)
  end
  local function undo(expected,processed)
   if processed then assert(r.Undo_CanUndo2(0)=='Insert SoundPrep')end
   assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0 and r.CountTracks(0)==expected,'Undo did not restore tracks/items')
  end
  for _,origin in ipairs{'list','waveform'}do
   local source=app.explorer:control(origin=='list' and 1001 or 1046)
   local destination=main
   for _,area in ipairs{'row','empty'}do
    local y=area=='row' and 30 or math.floor(height-20)
    local count=r.CountTracks(0)
    -- Native placement is our oracle, including REAPER's TCP track creation.
    app.drop:detach();assert(invoke(source,destination,y),'Native reference drop failed')
    assert(r.CountMediaItems(0)==1,'Native reference did not create one item')
    local item=r.GetMediaItem(0,0)
    local added=r.CountTracks(0)-count
    local position=r.GetMediaItemInfo_Value(item,'D_POSITION')
    local track=r.GetMediaTrackInfo_Value(r.GetMediaItem_Track(item),'IP_TRACKNUMBER')
    undo(count,false);app.drop:tick()
    app.definition.settings.insert_handles=area=='row'
    app.reverse_override=area=='empty';app.effective_macro=nil;app.drop:tick()
    assert(invoke(source,destination,y),'Processed drop rejected: '..r.GetExtState('AuditionMacro.Drop.v1','message'))
    assert(r.CountMediaItems(0)==1 and r.CountTracks(0)==count+added,'Native track creation changed')
    item=r.GetMediaItem(0,0)
    assert(r.GetMediaItemInfo_Value(item,'D_POSITION')==position,'Native position changed')
    assert(r.GetMediaTrackInfo_Value(r.GetMediaItem_Track(item),'IP_TRACKNUMBER')==track,'Native track placement changed')
    local sourceTake=r.GetTake(item,0);local rendered=r.GetTake(item,1)
    assert(r.CountTakes(item)==2 and r.GetActiveTake(item)==rendered,'Missing processed alternate take')
    local original=r.GetMediaItemTake_Source(sourceTake)
    while r.GetMediaSourceParent(original)do original=r.GetMediaSourceParent(original)end
    assert(r.GetMediaSourceFileName(original,'')==path,'Original source lost')
    assert(r.TakeFX_GetCount(sourceTake)==r.TrackFX_GetCount(app.bank.macros.heavy),'Source FX lost')
    assert(r.TakeFX_GetCount(rendered)==0,'Rendered take has duplicate FX')
    local target=r.GetMediaSourceFileName(r.GetMediaItemTake_Source(rendered),'')
    assert(target~=path and r.file_exists(target),'Rendered media missing')
    local duration=(origin=='list' and 1 or b-a)/.72
    assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-duration)<1e-8,'Wrong list/range duration')
    local _,json=r.GetSetMediaItemTakeInfo_String(rendered,'P_EXT:AuditionMacro','',false)
    local plan=J.decode(json);assert(plan.handles==(area=='row'))
    undo(count,true)
    assert(r.Undo_DoRedo2(0)==1 and r.CountTracks(0)==count+added and r.CountTakes(r.GetMediaItem(0,0))==2,'Redo lost tracks/takes')
    undo(count,true)
    log:write(origin,' / main content view / ',area,': native placement, ',added,' new tracks, 2 takes, Undo/Redo\n')
   end
  end
  -- External drags keep native behavior even inside the newly hooked TCP.
  local count=r.CountTracks(0);assert(invoke(nil,main,30))
  local item=r.GetMediaItem(0,0);assert(r.CountTakes(item)==1)
  local original=r.GetMediaItemTake_Source(r.GetActiveTake(item))
  while r.GetMediaSourceParent(original)do original=r.GetMediaSourceParent(original)end
  assert(r.GetMediaSourceFileName(original,'')==path);undo(count,false)
  log:write('external TCP drop stayed native\n')
  app:activate('heavy');Model.find(app.definition,'heavy').normalization.enabled=true
  app.effective_macro=nil;app.drop:tick();local previous=r.Undo_CanUndo2(0)
  assert(not invoke(app.explorer:control(1001),main,math.floor(height-20)),'Unmeasured drop accepted')
  assert(r.CountTracks(0)==count and r.CountMediaItems(0)==0 and r.Undo_CanUndo2(0)==previous,'Rejected drop changed project')
  log:write('unmeasured TCP drop rejected before creating a track\n');finish(true)
 end,debug.traceback)
 if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
