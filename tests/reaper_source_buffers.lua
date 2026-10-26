-- Real audio with simulated Media Explorer selections; disposable host only.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local U=require('am.util');local J=require('am.json')
local dir=host..'/source-buffers';r.RecursiveCreateDirectory(dir,0)
assert(U.write(host..'/Effects/am_buffer_probe',assert(U.read(root..'/tests/audio_buffer_probe.jsfx'))))
local function wav(name,sample)
  local pcm={}
  for i=0,143999 do pcm[#pcm+1]=string.pack('<i2',sample(i))end
  pcm=table.concat(pcm)
  assert(U.write(dir..'/'..name..'.wav','RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..
    string.pack('<I4I2I2I4I4I2I2',16,1,1,48000,96000,2,16)..'data'..string.pack('<I4',#pcm)..pcm))
end
wav('old',function()return 12000 end);wav('silence',function()return 0 end)
wav('pulse',function(i)return i<48 and 3000 or 0 end)
r.Audio_Init();local master=r.GetMasterTrack(0);r.SetMediaTrackInfo_Value(master,'D_VOL',0)
assert(r.TrackFX_AddByName(master,'JS: am_response_probe',false,1)>=0)
r.gmem_attach('AuditionMacro.ResponseTest');r.gmem_write(0,0);r.gmem_write(600000,0)
local cases={{kind='JS',baseline=true},{kind='JS',keep=false},{kind='JS',keep=true},
  {kind='VST',baseline=true},{kind='VST',keep=false},{kind='VST',keep=true}}
local log=assert(io.open(dir..'/test.log','w'));log:setvbuf('no')
local results=J.array{};local app,chosen,selected,index,stage,due,changed_at,clears,loads,guids=nil,nil,nil,0,0,0,nil,0,nil,nil
local done=false
local function finish(ok,err)
  if done then return end;done=true
  if app then app:close()end
  assert(U.write(dir..'/results.json',J.encode{status=ok and'PASS'or'FAIL',error=err,cases=results}))
  log:write(ok and'PASS\n'or'FAIL '..tostring(err)..'\n');log:close()
end
local function peaks(since)
  local maximum,groups,previous=0,{},-1
  for i=0,r.gmem_read(0)-1 do
    local at,peak=r.gmem_read(1+i*5),r.gmem_read(3+i*5)
    if at>=since then
      maximum=math.max(maximum,peak)
      if peak>.03 then
        if at-previous>.1 then groups[#groups+1]={at=at-since,peak=peak}
        else groups[#groups].peak=math.max(groups[#groups].peak,peak)end
        previous=at
      end
    end
  end
  return maximum,groups
end
local function tick()
  local ok,err=xpcall(function()
    local now=r.time_precise();if now<due then return end
    if stage==0 then
      index=index+1;if index>#cases then finish(true);return end
      chosen=cases[index];local data=dir..'/case'..index
      App.initialize(r,root,data);local b=Model.defaults();b.macros=J.array{Model.macro('delay','Delay'),Model.macro('other','Other')};b.slots={['1']='delay',['2']='other'}
      b.settings.autoplay=false;b.settings.keep_fx_running=chosen.keep or false;b.settings.monitor_gain_db=0;b.settings.preview_fade_ms=50
      for _,m in ipairs(b.macros)do
        assert(U.write(data..'/'..m.fx_chain,chosen.kind=='JS'and'SHOW -1\nBYPASS 0 0 0\n<JS am_buffer_probe ""\n500\n>\nWAK 0 0\n'or'SHOW -1\nLASTSEL 0\nDOCKED 0\n'))
      end
      assert(Model.save(data..'/bank.json',b));app=App.new(r,root,data)
      if chosen.kind=='VST'then for _,t in pairs(app.bank.macros)do
        local fx=r.TrackFX_AddByName(t,'VST: ReaDelay (Cockos)',false,1);assert(fx>=0)
        for p,value in pairs({[0]=1,[1]=0,[3]=.05,[4]=0})do r.TrackFX_SetParam(t,fx,p,value)end
      end end
      selected=dir..'/old.wav';app.explorer.selection=function()return selected end
      app.explorer.ensure_waveform=function()end;app.explorer.preview_range=function()return true,nil end
      clears=0;local clear=app.bank.clear_buffers
      app.bank.clear_buffers=function(bank)clears=clears+1;if not chosen.baseline then clear(bank)end end
      app:activate('other');app:play();loads=app.bank.loads
      guids={};for id,t in pairs(app.bank.macros)do guids[id]=r.TrackFX_GetFXGUID(t,0)end
      stage=1;due=r.time_precise()+.25
    elseif stage==1 then
      app:activate('delay');app:play();assert(clears==0,'Same-file replay flushed the bank')
      stage=2;due=r.time_precise()+.25
    elseif stage==2 then
      selected=dir..'/silence.wav';app.last_poll=0;changed_at=r.time_precise();app:tick()
      assert(clears==1 and not app.preview:playing(),'No-autoplay selection did not clear immediately')
      assert(app.path==selected);app:activate('other');app:play()
      stage=3;due=r.time_precise()+1
    elseif stage==3 then
      local peak=peaks(changed_at+.08);chosen.residual_peak=peak
      if chosen.baseline then assert(peak>.3,'Fixture did not reproduce stale FX audio')
      else
        assert(peak<1e-7,'Previous file escaped from an inactive FX branch: '..peak)
        for id,t in pairs(app.bank.macros)do
          assert(r.TrackFX_GetFXGUID(t,0)==guids[id],'Buffer reset changed the FX identity')
          assert(r.TrackFX_GetEnabled(t,0)and not r.TrackFX_GetOffline(t,0))
          local parameter=chosen.kind=='JS'and 0 or 3;local expected=chosen.kind=='JS'and 500 or .05
          assert(math.abs(r.TrackFX_GetParam(t,0,parameter)-expected)<1e-6,'Buffer reset lost an unsaved FX parameter')
        end
      end
      if chosen.baseline then
        results[#results+1]=chosen;log:write(J.encode(chosen)..'\n');app:close();app=nil;stage=0;due=now+.2
      else
        -- The residual check uses a 50 ms outgoing fade. Disable the configured
        -- incoming fade for this first-sample transient measurement.
        app.definition.settings.preview_fade_ms=0
        selected=dir..'/pulse.wav';changed_at=r.time_precise();app:play();assert(clears==2,'Direct Play skipped the file boundary')
        stage=4;due=r.time_precise()+1
      end
    else
      local peak,groups=peaks(changed_at+.08)
      assert(#groups==1 and peak>.05 and peak<.2,'New-file transient was lost or contaminated: '..J.encode(groups))
      assert(groups[1].at+.08<.5+.12,'Buffer clearing introduced extra pre-roll')
      assert(app.bank.loads==loads,'VST reset reloaded a state chunk')
      chosen.new_file_peaks=groups;results[#results+1]=chosen;log:write(J.encode(chosen)..'\n')
      app:close();app=nil;stage=0;due=now+.2
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
r.defer(tick)
