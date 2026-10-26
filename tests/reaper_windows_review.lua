-- Launched only by tools/run_windows_integration.py, in a disposable host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use the disposable test host')
assert(r.GetOS():match('^Win'),'Windows integration test')
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app')
local Bar=require('am.bar');local L=require('am.loudness');local E=require('am.export');local I=require('am.insert')
local result={status='RUNNING',version=r.GetAppVersion(),checks=J.array{}}
local app,done=false,false;local start=r.time_precise();local phase=0;local tracks=r.CountTracks(0)
local path=host.."/media 素材/test one's 音.wav";local data=host..'/review-data'
local identity,insertedTrack,inserted,peakDeadline,redone,inspectDeadline,rangeDeadline,selectionReady
local function select_range(a,b)
  rangeDeadline=r.time_precise()+3
  for _,entry in ipairs{{1455,a},{1456,b}}do
    local control=assert(app.explorer:control(entry[1]))
    r.JS_Window_SetFocus(control);r.JS_Window_SetTitle(control,entry[2])
    r.JS_WindowMessage_Send(control,'WM_KEYDOWN',13,0,0,0)
    r.JS_WindowMessage_Send(control,'WM_KEYUP',13,0,0,0)
  end
end
local function range_ready(a,b,reverse)
  if not (app.range and math.abs(app.range[1]-a)<.002 and math.abs(app.range[2]-b)<.002)then
    assert(r.time_precise()<rangeDeadline,'Native range controls did not commit: '..J.encode{
      native={r.MediaExplorerGetLastPlayedFileInfo()},range=app.range,path=app.path,
      start=app.explorer:text(1455),finish=app.explorer:text(1456)})
    return false
  end
  assert(app.preview:playing(),'Range selection did not start preview')
  assert(select(2,app.preview:get('D_MEASUREALIGN'))==-1,'Range audition waits for the next bar')
  local position=app.preview:source_position()
  assert(math.abs(position-(reverse and b or a))<.08,'Range did not play immediately from its head: '..tostring(position))
  return true
end
local function drop_transport_test()
  local EXT=require('am.drop').EXT;local project=r.EnumProjects(-1)
  r.InsertTrackAtIndex(r.CountTracks(0),false);local target=r.GetTrack(0,r.CountTracks(0)-1)
  local savedContext,savedResult=r.AM_DropContext,r.AM_DropResult
  local ctx={id=501,origin='list',path=path,paths=J.array{path}}
  local function process(phase)
    ctx.phase=phase;local accepted
    r.AM_DropContext=function()return J.encode(ctx)end;r.AM_DropResult=function(value)accepted=value end
    local ok,why=pcall(dofile,root..'/internal/Process waveform drop.lua')
    r.AM_DropContext=savedContext;r.AM_DropResult=savedResult
    assert(ok,why);assert(accepted,r.GetExtState(EXT,'message'))
  end
  app.definition.settings.loop=true;app:play(0);app.drop:tick()
  local handle=app.preview.handle
  process('capture');process('cancel');app:tick()
  assert(app.preview:playing() and app.preview.handle==handle,'Cancelled drag stopped preview')
  for index,origin in ipairs{'list','waveform','list'}do
    local playing_drop=index==3
    ctx.id=ctx.id+1;ctx.origin=origin
    local _,file,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
    ctx.preview={path=file,mode=mode,start=a,['end']=b}
    if playing_drop then
      app:activate('dark') -- Force an uncached automatic playback drop.
      r.SetEditCurPos(.15,false,false);r.OnPlayButton()
    end
    app:play(0);app.drop:tick();process('prepare')
    r.Undo_BeginBlock2(project)
    local item=r.AddMediaItemToTrack(target);local take=r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take,r.PCM_Source_CreateFromFile(path));r.SetMediaItemInfo_Value(item,'D_LENGTH',2)
    ctx.items=J.array{select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))}
    process('finish');r.Undo_EndBlock2(project,'Test preview stop on '..origin..' drop',-1)
    assert(r.CountTakes(item)==2 and r.GetActiveTake(item)==r.GetTake(item,1))
    app:tick();assert(not app.preview:playing(),origin..' drop did not stop MEP preview')
    app:tick();assert(not app.preview:playing(),'Range polling resumed after drop')
    if playing_drop then
      assert(r.GetPlayStateEx(project)==0,'Uncached drop did not stop project playback')
      assert(r.GetExtState(EXT,'queue')=='' and #app.drop.pending.jobs==0,'Playback drop left a pending render')
    end
  end
  r.DeleteTrack(target)
  app.definition.settings.loop=false;app:activate(nil)
end
local function peaks(item)
  local buffer=r.new_array(256)
  local n=r.GetMediaItemTake_Peaks(r.GetActiveTake(item),100,0,2,32,0,buffer)&0xfffff
  local maximum=0;for i=1,n*2 do maximum=math.max(maximum,math.abs(buffer[i]))end
  return n>0 and maximum>.001
end
local function check(name)result.checks[#result.checks+1]=name;assert(U.write(host..'/windows-review-progress.json',J.encode(result)))end
local function finish(ok,err)
  if done then return end;done=true
  if app then app:close()end
  result.status=ok and 'PASS' or 'FAIL';result.error=err;result.elapsed=r.time_precise()-start
  assert(U.write(host..'/windows-review.json',J.encode(result)))
end
r.atexit(function()finish(false,'Integration script terminated early')end)
local initialized,why=xpcall(function()
  -- The runner starts hidden. Docked Media Explorer needs visible ancestors.
  r.JS_Window_Show(r.GetMainHwnd(),'SHOW')
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  local explorer=r.OpenMediaExplorer(path,false)
  if explorer then r.JS_Window_Show(explorer,'SHOW')end
  -- A fresh REAPER defaults to a docked browser; show its docker as well.
  local ancestor=explorer
  for _=1,8 do
    ancestor=ancestor and r.JS_Window_GetParent(ancestor)
    if not ancestor then break end
    r.JS_Window_Show(ancestor,'SHOW')
  end
  app=App.new(r,root,data);app.definition.settings.autoplay=false
  app.bar=Bar.new(r,app);app.bar:tick()
  assert(J.decode(r.AM_BarGeometry()).attached)
  check('App, FX bank and embedded Windows bar attach')
  local file=data..'/保存 test.json';assert(U.write(file,'first'));assert(U.write(file,'second'));assert(U.read(file)=='second')
  check('Atomic overwrite with Japanese and spaces in path')
  local began=r.time_precise();local loads=app.bank.loads
  for i=1,1000 do app:activate(i%2==0 and 'heavy' or 'dark')end
  result.switch_1000_seconds=r.time_precise()-began;assert(app.bank.loads==loads)
  app:activate(nil);check('1000 Macro switches retain FX instances')
end,debug.traceback)
if not initialized then finish(false,why);return end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()-start<150,'Windows integration timed out')
    app:tick();app.bar:tick()
    if phase==0 then
      local selected=app.explorer:selection();if not U.path_equal(selected,path)then return end
      app.path=path;identity=assert(L.identity(r,path));app.identity=identity;app:play();assert(app.preview:playing())
      app:activate('heavy')
      local native=app.explorer:transform()
      assert(native.pitch_semitones==-4 and native.rate==.72,'Macro controls did not reach native Pitch / Rate')
      local handle=app.preview.handle
      app.explorer:set_number(1021,7);app.explorer:set_number(1454,.5);app.explorer:toggle(40068,false)
      assert(select(2,app.preview:get('D_PITCH'))==7 and select(2,app.preview:get('D_PLAYRATE'))==.5,
        'Native Pitch / Rate waited for Lua defer')
      app:tick();assert(app.preview.handle==handle,'Native edits restarted the preview')
      app:activate(nil);native=app.explorer:transform()
      assert(native.pitch_semitones==0 and native.rate==1 and not native.preserve_pitch,'Raw did not restore native transform')
      assert(select(2,app.preview:get('B_PPITCH'))==0,'Raw preview kept Preserve Pitch on')
      check('Macro and native Pitch / Rate synchronize without restarting preview')
      app.preview:stop();check('Unicode Media Explorer selection and preview start/stop')
      selectionReady=r.time_precise()+.5;phase=7
    elseif phase==7 then
      -- OpenMediaExplorer posts its initial list selection/load after startup.
      if r.time_precise()<selectionReady then return end
      assert(U.path_equal(app.path,path));app:play();app.preview:stop()
      select_range('0:00.200','0:01.600');phase=4
    elseif phase==4 then
      if not range_ready(.2,1.6)then return end
      check('Stopped range selection starts immediately at its head with Follow selection off')
      app.preview:seek_source(1.2)
      select_range('0:00.400','0:01.500');phase=5
    elseif phase==5 then
      if not range_ready(.4,1.5)then return end
      check('Changing a playing range restarts at the new head, not the old cursor')
      app:native_transport(1010);assert(not app.preview:playing());app:reverse()
      app.explorer:toggle(1012,true);app.explorer:toggle(42171,true)
      r.SetEditCurPos(.15,false,false);r.OnPlayButton()
      select_range('0:00.500','0:01.400');phase=6
    elseif phase==6 then
      if not range_ready(.5,1.4,true)then return end
      assert(r.GetPlayStateEx(0)&1==1);r.OnStopButton()
      app.explorer:toggle(1012,false)
      check('Paused reverse preview starts at its head immediately even with Start on bar and project playback')
      app:activate(nil);drop_transport_test()
      check('List/waveform drops stop MEP; uncached playback drops stop and finish rendering; cancelled capture preserves preview')
      local original=app.explorer:search_text();app.explorer:search('test',original)
      assert(app.explorer:search_text()=='test');app.explorer:search(original,'test')
      assert(app.explorer:search_text()==original);check('Native search Unicode read, apply and restore')
      app.loudness:request(identity,true);phase=1
    elseif phase==1 then
      if app.loudness.active then return end
      local measured=assert(app.loudness:get(identity),app.loudness.error or 'No analysis result')
      assert(measured.status=='ready' and measured.channels==1)
      result.lufs=measured.max_momentary_lufs;check('Python / FFmpeg analysis on Japanese path')
      local macro=U.copy(app:effective());macro.source_transform.reverse=true;macro.source_transform.rate=.75
      local snapshot=E.snapshot(r,path,macro,'',0,identity,{.2,1.1},app.definition.settings)
      local heavy=require('am.model').effective(app.definition,'heavy');heavy.normalization.enabled=true
      local fxSnapshot=E.snapshot(r,path,heavy,app.bank:chain('heavy'),L.gain(heavy,measured),identity,nil,app.definition.settings)
      local entries={{snapshot=snapshot,length=2},{snapshot=fxSnapshot,length=2}}
      local state={data=data,settings=app.definition.settings,prepared=J.array{}}
      local project=r.EnumProjects(-1);local tab=r.EnumProjects(1)
      local began=r.time_precise()
      local direct=require('am.render_item');direct.stamp(r,snapshot);direct.stamp(r,fxSnapshot)
      local plans={I.prepare(r,snapshot,2,true,data..'/rendered',nil,direct.render),I.prepare(r,fxSnapshot,2,true,data..'/rendered',nil,direct.render)}
      result.cold_render_seconds=r.time_precise()-began
      assert(r.EnumProjects(-1)==project and r.EnumProjects(1)==tab,'Cold drop changed parent project tabs')
      local exec=r.ExecProcess;r.ExecProcess=function()error('Warm cache launched a worker')end
      local cached,cacheErr=pcall(I.prepare,r,snapshot,2,true,data..'/rendered',nil,function()error('Warm cache rendered again')end);r.ExecProcess=exec;assert(cached,cacheErr)
      check('Direct reverse/rate/range and normalized FX renders; warm reuse without renderer')
      state.settings=U.copy(state.settings);state.settings.insert_handles=false
      plans[3]=I.prepare(r,snapshot,2,false,data..'/rendered',nil,direct.render)
      assert(plans[3].offset==0)
      local cropped=r.PCM_Source_CreateFromFile(plans[3].target)
      assert(math.abs(r.GetMediaSourceLength(cropped)-1.2)<1/48000);r.PCM_Source_Destroy(cropped)
      check('Crop-only reverse/rate output contains exactly the selection')
      r.InsertTrackAtIndex(r.CountTracks(0),false);insertedTrack=r.GetTrack(0,r.CountTracks(0)-1)
      r.Undo_OnStateChangeEx2(project,'Set up Windows test track',-1,-1)
      r.Undo_BeginBlock2(project);inserted={}
      for _,plan in ipairs(plans)do
        local item=r.AddMediaItemToTrack(insertedTrack);local take=r.AddTakeToMediaItem(item)
        assert(r.SetMediaItemTake_Source(take,r.PCM_Source_CreateFromFile(path)))
        I.replace(r,project,item,plan);inserted[#inserted+1]=item
        assert(r.CountTakes(item)==2 and r.GetActiveTake(item)==r.GetTake(item,1))
      end
      I.build_missing_peaks(r,project,inserted)
      r.Undo_EndBlock2(project,'Windows processed insertion review',-1)
      assert(math.abs(r.GetMediaItemInfo_Value(inserted[1],'D_LENGTH')-1.2)<1e-8)
      assert(math.abs(r.GetMediaItemTakeInfo_Value(r.GetActiveTake(inserted[1]),'D_STARTOFFS')-1.2)<1e-8)
      assert(r.TakeFX_GetCount(r.GetTake(inserted[2],0))>0)
      check('Source + FX / Rendered takes preserve transforms and editable FX')
      peakDeadline=r.time_precise()+10;phase=2
    elseif phase==2 then
      for _,item in ipairs(inserted)do if not peaks(item)then assert(r.time_precise()<peakDeadline,'Rendered peaks not generated');return end end
      if not redone then
        assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0,'Insertion did not undo as one operation')
        assert(r.Undo_DoRedo2(0)==1 and r.CountMediaItems(0)==3,'Redo lost items')
        inserted={};for i=0,2 do inserted[#inserted+1]=r.GetMediaItem(0,i);assert(r.CountTakes(inserted[#inserted])==2)end
        redone=true;peakDeadline=r.time_precise()+10;return
      end
      check('Rendered waveforms and alternate takes survive one Undo/Redo')
      -- Undo can replace track handles; reacquire the owned last track.
      insertedTrack=r.GetTrack(0,r.CountTracks(0)-1);r.DeleteTrack(insertedTrack)
      local seconds=tonumber(U.read(host..'/.audition-macro-test-inspect'))or 0
      if seconds>0 then
        app.search_session:command{op='generate',input='重い金属の衝突、声と音楽は除外',mode='natural',broad=false}
        app.bar:tick();inspectDeadline=r.time_precise()+seconds
      end
      phase=3
    elseif phase==3 then
      if inspectDeadline and r.time_precise()<inspectDeadline then return end
      app:close();assert(r.CountTracks(0)==tracks,'Preview tracks were not cleaned up')
      assert(r.AM_BarGeometry()=='{}');check('Shutdown restores bar and removes preview tracks')
      finish(true)
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
