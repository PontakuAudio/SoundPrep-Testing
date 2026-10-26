-- Calls the real Cocoa/SWELL drop destination in the disposable, muted host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local U=require('am.util');local J=require('am.json');local Model=require('am.model')
local data=r.GetResourcePath()..'/list-drop-test';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/list-drop.txt','w'));f:setvbuf('no')
local app,frame,done=nil,0,false
local function finish(ok,e)
  if done then return end;done=true;if app then app:close()end
  f:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');f:close()
end
local ok,e=xpcall(function()
  assert(r.APIExists('AM_DropAttachSources') and r.APIExists('AM_TestWaveformDrop'))
  assert(r.CountMediaItems(0)==0,'Use an empty project')
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  if r.CountTracks(0)==0 then r.InsertTrackAtIndex(0,false)end
  App.initialize(r,root,data);local b=assert(Model.load(data..'/bank.json'));b.settings.autoplay=false
  for _,m in ipairs(b.macros)do m.normalization.enabled=false end
  b.raw=Model.raw_settings();Model.save(data..'/bank.json',b)
  app=App.new(r,root,data);r.OpenMediaExplorer('/tmp/audition-macro-dev/long.wav',false)
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick()
    if frame~=12 then return end
    app:activate('heavy');app.explorer:command(40016) -- list payload is authoritative, even without loaded waveform
    app.drop:tick()
    local list=app.explorer:control(1001);local arrange=r.JS_Window_FindChildByID(r.GetMainHwnd(),1000)
    local path='/tmp/audition-macro-dev/test.wav';local other='/tmp/audition-macro-dev/impulse.wav'
    local function drop(source,paths)
      assert(r.AM_TestWaveformDrop(source,arrange,paths),'Rejected: '..r.GetExtState('AuditionMacro.Drop.v1','message'))
    end
    local function undo(n,takes)
      assert(r.Undo_CanUndo2(0)=='Insert SoundPrep')
      assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
      assert(r.Undo_DoRedo2(0)==1 and r.CountMediaItems(0)==n)
      for i=0,n-1 do assert(r.CountTakes(r.GetMediaItem(0,i))==(takes or 2),'Redo changed take count')end
      assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
    end
    drop(list,path)
    assert(r.CountMediaItems(0)==1)
    local item=r.GetMediaItem(0,0);local take=r.GetActiveTake(item)
    assert(r.CountTakes(item)==2 and take==r.GetTake(item,1) and r.TakeFX_GetCount(take)==0)
    assert(r.TakeFX_GetCount(r.GetTake(item,0))==r.TrackFX_GetCount(app.bank.macros.heavy),'Source take lost Macro FX')
    assert(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(r.GetTake(item,0)),'')==path)
    local _,meta=r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro','',false);local plan=J.decode(meta)
    assert(plan.original==path and plan.target~=path and plan.offset==0 and math.abs(plan.duration-1/.72)<1e-8)
    assert(r.GetMediaItem_Track(item)==r.GetTrack(0,0),'Native drop track changed')
    assert(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')==plan.target)
    f:write('single list drop: full processed source, native track preserved\n');undo(1)
    drop(list,path..'\n'..other)
    assert(r.CountMediaItems(0)==2)
    for i=0,1 do
      assert(r.CountTakes(r.GetMediaItem(0,i))==2,'Batch item lacks original take')
      local take=r.GetActiveTake(r.GetMediaItem(0,i));local _,json=r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro','',false)
      local p=J.decode(json);assert(p.original==path or p.original==other)
      assert(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')==p.target and p.target~=p.original)
    end
    f:write('two-file list drop: all processed; one Undo/Redo restores batch\n');undo(2)
    drop(nil,path) -- external/Finder provenance must remain native
    local src=r.GetMediaItemTake_Source(r.GetActiveTake(r.GetMediaItem(0,0)))
    while r.GetMediaSourceParent(src)do src=r.GetMediaSourceParent(src)end
    assert(r.GetMediaSourceFileName(src,'')==path)
    assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
    f:write('external drop remained native\n')
    -- Native edits after the last defer must be captured by the drop transaction.
    app.explorer:set_number(1454,2);app.explorer:set_number(1021,6)
    drop(list,path)
    item=r.GetMediaItem(0,0);take=r.GetActiveTake(item)
    local _,json=r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro','',false);plan=J.decode(json)
    local snapshot=J.decode(assert(U.read(plan.target:gsub('%.wav$','.macro.json'))))
    assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-.5)<1e-8)
    assert(snapshot.macro.source_transform.pitch_semitones==6 and snapshot.macro.source_transform.rate==2)
    f:write('immediate native pitch/rate edit captured without intervening defer\n');undo(1)
    app:activate(nil)
    local L=require('am.loudness');local identity=assert(L.identity(r,path))
    local measurement={status='ready',max_momentary_lufs=-24,true_peak_dbtp=-18,duration=1,channels=1,
      identity=identity,profile=L.PROFILE,analyzer_key=app.loudness.analyzer_key}
    assert(U.write(data..'/cache/'..L.key(identity,app.loudness.analyzer_key)..'.json',J.encode(measurement)))
    app:set_normalization(true,-18);app.drop:tick();drop(list,path)
    item=r.GetMediaItem(0,0);take=r.GetActiveTake(item)
    assert(r.CountTakes(item)==1 and r.TakeFX_GetCount(take)==0 and r.GetMediaItemTakeInfo_Value(take,'D_VOL')==1)
    assert(math.abs(r.GetMediaItemInfo_Value(item,'D_VOL')-U.gain(6))<1e-8)
    assert(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')==path)
    f:write('Raw normalized list drop uses identity-validated cache and Item Volume without rendering\n');undo(1,1)
    local top=r.Undo_CanUndo2(0)
    assert(not r.AM_TestWaveformDrop(list,arrange,path..'\n'..other),'Unmeasured batch accepted')
    assert(r.CountMediaItems(0)==0 and r.Undo_CanUndo2(0)==top,'Rejected batch changed project')
    f:write('unmeasured normalized batch rejected atomically\n');finish(true)
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
