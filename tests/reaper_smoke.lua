-- Run ONLY in a disposable REAPER resource directory containing this marker.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
assert(reaper.file_exists(reaper.GetResourcePath()..'/.audition-macro-test'),'Use the disposable test host')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local r=reaper;local U=require('am.util');local J=require('am.json');local Model=require('am.model')
local App=require('am.app');local Bar=require('am.bar');local Editor=require('am.editor_panel');local L=require('am.loudness')
local data=reaper.GetResourcePath()..'/audition-test'
r.RecursiveCreateDirectory(data,0)
local results=assert(io.open(data..'/smoke.txt','w'));results:setvbuf('no')
local function log(...)for _,v in ipairs({...})do results:write(tostring(v),'\t')end;results:write('\n')end
local app,frame= nil,0
local initial_count=r.CountTracks(0)
local finished=false
local function finish(ok,err)
  if finished then return end;finished=true
  if app then app:close()end
  log('remaining_tracks',r.CountTracks(0),'initial_tracks',initial_count)
  if r.CountTracks(0)~=initial_count then ok=false;err=tostring(err)..' | Track cleanup mismatch' end
  log(ok and 'PASS' or 'FAIL',err or '');results:close()
end
r.atexit(function()finish(false,'Smoke script terminated early')end)
local ok,err=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data)
  local b=assert(Model.load(data..'/bank.json'));b.settings.autoplay=false;Model.save(data..'/bank.json',b)
  app=App.new(r,root,data);app.bar=Bar.new(r,app);Editor.open(app);app.bar:tick()
  assert(app.explorer:text(997):find('inf') or tonumber(app.explorer:text(997))<=-140,'Native preview not muted')
  local guids={}
  for id,t in pairs(app.bank.macros)do guids[id]=r.TrackFX_GetFXGUID(t,0);log('fx',id,r.TrackFX_GetCount(t),guids[id])end
  local before=app.bank.loads;local start=r.time_precise()
  for i=1,1000 do app:activate(i%2==0 and 'heavy' or 'dark')end
  log('1000_switch_seconds',r.time_precise()-start,'loads',app.bank.loads)
  assert(app.bank.loads==before,'FX reloaded while switching')
  for id,t in pairs(app.bank.macros)do assert(r.TrackFX_GetFXGUID(t,0)==guids[id],'FX instance changed')end
  local chain=app.bank:chain('heavy');assert(#chain>80,'Empty FX save');log('saved_chain_bytes',#chain)
  local path='/tmp/audition-macro-dev/test.wav'
  assert(r.file_exists(path),'Generate test.wav before running')
  r.OpenMediaExplorer(path,false)
  app.path=path;app.identity=assert(L.identity(r,path))
  local source=assert(r.PCM_Source_CreateFromFile(path))
  log('native_mono_lufs_m',-23-U.db(r.CalculateNormalization(source,4,-23,0,0)))
  log('native_true_peak',-1-U.db(r.CalculateNormalization(source,3,-1,0,0)))
  r.PCM_Source_Destroy(source)
  app.loudness:request(app.identity,true)
  app:activate('reverse')
  app.preview:start(path,app:effective(),0,b.settings)
  assert(app.preview:playing(),'SWS preview failed');log('reverse_preview',app.preview:playing())
  app.preview:stop()
end,debug.traceback)
if not ok then finish(false,err);return end
local function loop()
  local ok,e=xpcall(function()
    frame=frame+1
    app.bar:tick();app.loudness:poll()
    if frame==10 then
      local path,reason=app.explorer:selection();log('selection',path or reason)
      assert(path=='/tmp/audition-macro-dev/test.wav','Media Explorer selection resolution failed')
      app:activate(nil);app:play();assert(app.preview:playing());app.preview:stop()
    end
    if frame>15 and not app.loudness.active then
      local measurement=app:measurement()
      assert(measurement and measurement.status=='ready',app.loudness.error or 'Worker/cache failed')
      log('worker_lufs_m',measurement.max_momentary_lufs,'worker_tp',measurement.true_peak_dbtp)
      local m=Model.find(app.definition,'heavy');m.normalization.enabled=true;m.normalization.target_lufs=-14
      app:activate('heavy');app:play();log('applied_gain',app.applied_gain);app.preview:stop()
      app.export_dir=data..'/exports'
      local target=app:export(false);log('rendered',target)
      assert(r.file_exists(target),'Missing rendered audio')
      finish(true)
    elseif frame>600 then error('Timed out waiting for worker')end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not finished then r.defer(loop)end
end
loop()
