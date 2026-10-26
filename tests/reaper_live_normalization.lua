-- Actual asynchronous worker -> App normalization tick -> native preview audio.
-- Run only in the disposable host. No native transport or analysis is mocked.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app')
local Bank=require('am.bank');local Preview=require('am.preview');local Model=require('am.model')
local L=require('am.loudness');local A=require('am.analysis_policy')
local Explorer=require('am.media_explorer');local EXT=require('am.drop').EXT
local report={status='RUNNING',checks=J.array{},cases=J.array{},host_version=r.GetAppVersion(),
  scope='Actual worker requests, native audio block peaks, and App:update_normalization; selection UI and drag payload only are injected.'}
local saved={context=r.AM_DropContext,result=r.AM_DropResult,explorer=Explorer.new}
local app,observer,send,macro_track
local data=host..'/live-normalization-data';local fixture_dir=host..'/live-normalization-fixtures'
local cases,index,stage,deadline,due,record,started,handle,starts,last_position,last_gain,last_tick,read_index,epoch
local measurement,target,previous_audio,recorded_frames,stopped_starts
local function check(text)
  report.checks[#report.checks+1]=text
  assert(U.write(host..'/live-normalization-progress.json',J.encode(report)))
end
local function finish(ok,err)
  r.AM_DropContext,r.AM_DropResult,Explorer.new=saved.context,saved.result,saved.explorer
  if app then
    if app.preview then pcall(app.preview.stop,app.preview,true)end
    if app.loudness then pcall(app.loudness.close,app.loudness)end
    if app.bank then pcall(app.bank.close,app.bank)end
  end
  if observer and r.ValidatePtr2(0,observer,'MediaTrack*')then r.DeleteTrack(observer)end
  for _,key in ipairs{'state','prepared','captured','busy','preview_stop','message'}do r.DeleteExtState(EXT,key,false)end
  report.status=ok and 'PASS'or 'FAIL';report.error=err
  assert(U.write(host..'/live-normalization.json',J.encode(report)))
end
local function fixture(name,scale)
  -- A 1 kHz integer-period tone has an exact full-amplitude sample every
  -- 48 frames, so block peaks expose gain changes without sine-phase jitter.
  local period={};local amplitudes={}
  for ch=1,6 do amplitudes[ch]=ch*scale end
  for frame=0,47 do
    local values={};local phase=math.sin(2*math.pi*frame/48)
    for ch,value in ipairs(amplitudes)do values[ch]=string.pack('<i2',math.floor(value*phase+.5))end
    period[#period+1]=table.concat(values)
  end
  local pcm=string.rep(table.concat(period),12000) -- 12 seconds; loops are tracked explicitly.
  local path=fixture_dir..'/'..name..'.wav'
  assert(U.write(path,'RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..
    string.pack('<I4I2I2I4I4I2I2',16,1,6,48000,48000*12,12,16)..'data'..string.pack('<I4',#pcm)..pcm))
  return {path=path,amplitudes=amplitudes}
end
local function clear_probe()
  epoch=(epoch or 0)+1;r.gmem_write(0,epoch);read_index=0;recorded_frames=0;previous_audio=nil
end
local function audio(now,keep)
  if r.gmem_read(2)~=epoch then return end
  local current=math.floor(r.gmem_read(1))
  assert(current-read_index<8192,'Audio observer ring overflowed')
  while read_index<current do
    local slot=32+(read_index%8192)*8
    local frames=r.gmem_read(slot);local peaks=J.array{}
    for ch=1,6 do peaks[ch]=r.gmem_read(slot+ch)end
    read_index=read_index+1;recorded_frames=recorded_frames+frames
    if keep and now-started>=.3 and peaks[6]>0 then
      local db=20*math.log(peaks[6]/(cases[index].fixture.amplitudes[6]/32768),10)
      local observed={seconds=recorded_frames/48000,gain_db=db,peaks=peaks}
      for ch=1,6 do
        local error=math.abs(peaks[ch]/peaks[6]-ch/6)
        record.max_channel_ratio_error=math.max(record.max_channel_ratio_error,error)
        assert(error<.004,'Live normalization changed multichannel ratios')
      end
      if previous_audio then
        local change=db-previous_audio.gain_db
        record.max_audio_step_db=math.max(record.max_audio_step_db,math.abs(change))
        -- A large device block can contain more than one GUI update.
        assert(math.abs(change)<=math.max(.20,6*frames/48000+.16),'Abrupt gain change reached native audio')
        if target then assert(change*cases[index].direction>=-.025,'Native audio ramp reversed direction')end
      end
      previous_audio=observed
      record.audio_trace[#record.audio_trace+1]=observed
    end
  end
end
local function continuity(now)
  assert(app.preview.handle==handle and app.preview.starts==starts,'Normalization restarted the preview')
  local playing,position,length=app.preview:playing();assert(playing,'Preview stopped during normalization')
  if last_position then
    local delta=position-last_position
    if delta<0 and last_position>length-.3 and position<.3 then delta=delta+length;record.loops=record.loops+1 end
    assert(delta>=-.002,'Normalization reset the source position')
    assert(delta<=now-last_tick+.3,'Normalization skipped the source position')
  end
  last_position=position
end
local function capture_drop()
  local state={project=tostring(app.project),session=app.session,path=app.path,identity=U.copy(app.identity),
    macro=U.copy(app:effective()),settings=U.copy(app.definition.settings),data=data,
    input=r.GetTrackGUID(app.bank.input),track=r.GetTrackGUID(macro_track),
    pdc_options=app.bank.pdc_options[macro_track],analyzer_key=app.loudness.analyzer_key,
    measurement=U.copy(measurement),defer_items=true}
  r.SetExtState(EXT,'state',J.encode(state),false)
  local context={phase='capture',id=index,origin='list',path=app.path,paths=J.array{app.path},items=J.array{}}
  local acknowledged
  r.AM_DropContext=function()return J.encode(context)end;r.AM_DropResult=function(value)acknowledged=value end
  local before=r.CountMediaItems(app.project)
  dofile(root..'/internal/Process waveform drop.lua')
  assert(acknowledged,r.GetExtState(EXT,'message'))
  local snapshot=J.decode(r.GetExtState(EXT,'captured')).entries[1].snapshot
  assert(math.abs(snapshot.source_gain_db-target)<1e-8 and A.same(snapshot.analysis,measurement.analysis),
    'D&D captured the temporary ramp level instead of the final normalization gain')
  assert(math.abs(snapshot.source_gain_db-last_gain)>1,'D&D fixture was not captured during a ramp')
  assert(snapshot.channel_mix.mode==0 and snapshot.source_processing.fx_bypassed and snapshot.chain=='')
  assert(r.CountMediaItems(app.project)==before and app.preview.handle==handle and app.preview.starts==starts,
    'Capture-only D&D changed playback or project contents')
  record.drop_source_gain_db=snapshot.source_gain_db;record.drop_actual_gain_db=last_gain
  r.DeleteExtState(EXT,'captured',false);r.DeleteExtState(EXT,'state',false)
end
local function select_case()
  index=index+1
  if index>#cases then
    check('Completed boost/cut audio ramps, stop cancellation, cached starts and frozen D&D target gain')
    finish(true);return false
  end
  local case=cases[index];app.preview:stop(true)
  app.path=case.fixture.path;app.identity=assert(L.identity(r,app.path));app.source_channels=6
  app:configure_channels();assert(not app:measurement(),'A fresh fixture unexpectedly reused analysis')
  record={name=case.name,path=app.path,direction=case.direction,stop_during_ramp=case.stop or false,
    api_trace=J.array{},audio_trace=J.array{},max_api_step_db=0,max_audio_step_db=0,max_channel_ratio_error=0,loops=0}
  report.cases[#report.cases+1]=record
  measurement=nil;target=nil;last_position=nil;last_gain=0
  clear_probe();assert(app:play(0,true));handle=app.preview.handle;starts=app.preview.starts
  assert(app.loudness.active and app.loudness.counter==index,'Playback did not launch the actual uncached worker')
  assert(math.abs(select(2,app.preview:get('D_VOLUME'))-1)<1e-10,'Unmeasured preview did not start at unity')
  assert(app.bank.fx_bypassed and app.bank.channels==6,'Fixture is not using original multichannel playback')
  started=r.time_precise();last_tick=started;due=started+.4;deadline=started+65;stage='baseline'
  record.worker_job_id=app.loudness.active.job_id
  check(case.name..': playing at unity while the real analysis request is pending')
  return true
end
local ok,err=xpcall(function()
  require('am.native').require(r)
  assert(type(App.update_normalization)=='function' and type(Preview.tick_gain)=='function','Live normalization APIs are missing')
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  r.RecursiveCreateDirectory(fixture_dir,0);r.RecursiveCreateDirectory(data..'/chains',0)
  assert(U.write(data..'/chains/live.RfxChain','SHOW -1\nLASTSEL 0\nDOCKED 0\n'))
  local probe={'desc:Audition Macro live normalization observer','options:gmem=AM_LIVE_NORMALIZATION'}
  for ch=1,6 do probe[#probe+1]='in_pin:Channel '..ch end
  for ch=1,6 do probe[#probe+1]='out_pin:Channel '..ch end
  probe[#probe+1]=[[
@init
epoch=-1;ext_nodenorm=1;count=0;
@block
epoch!=gmem[0] ? (
  epoch=gmem[0];gmem[1]=0;count=0;frames=0;gmem[2]=epoch;
) : (
  frames>0 ? (
    slot=32+(count%8192)*8;gmem[slot]=frames;
    i=0;loop(6,gmem[slot+1+i]=peaks[i];i+=1;);
    count+=1;gmem[1]=count;
  );
);
frames=0;i=0;loop(6,peaks[i]=0;i+=1;);
@sample
frames+=1;i=0;loop(6,peaks[i]=max(peaks[i],abs(spl(i)));i+=1;);
]]
  assert(U.write(host..'/Effects/am_live_normalization_probe',table.concat(probe,'\n')))
  cases={{name='boost',fixture=fixture('quiet6',100),direction=1},
    {name='cut',fixture=fixture('loud6',3000),direction=-1},
    {name='stop during boost',fixture=fixture('quiet_stop6',100),direction=1,stop=true}}
  local definition=Model.defaults();local macro=Model.macro('live','Live normalization')
  macro.normalization.enabled=true;macro.normalization.target_lufs=-24;macro.normalization.max_boost_db=18
  macro.source_peak_guard.enabled=true;macro.source_peak_guard.ceiling_dbtp=-3
  macro.output_gain_db=0;definition.macros=J.array{macro};definition.slots={}
  definition.settings.monitor_gain_db=0;definition.settings.loop=true;definition.settings.preview_downmix=false
  definition.settings.preview_fade_ms=0;definition.settings.fade_ms=0;definition.settings.analysis_timeout_seconds=45
  local project=r.EnumProjects(-1)
  app=setmetatable({r=r,root=root,data=data,project=project,definition=definition,selected_id='live',
    session='live-normalization',message='',sync_transform=function()end,sync_range=function()return false end},App)
  app.explorer={selection=function()return app.path end,ensure_waveform=function()end}
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  app.bank=Bank.new(r,project,data,definition,app.session);app.preview=Preview.new(r,project,app.bank.input)
  app.loudness=L.new(r,root,data,definition.settings,app.session)
  assert(r.APIExists('AM_AnalysisStart')and r.APIExists('AM_AnalysisCancel'),'Native analysis APIs are required')
  assert(app.loudness.analyzer_key==L.ANALYZER_KEY and not app.loudness.python and not app.loudness.ffmpeg)
  report.analyzer_key=app.loudness.analyzer_key;report.external_analysis_process=false
  macro_track=app.bank.macros.live
  r.InsertTrackAtIndex(r.CountTracks(project),false);observer=r.GetTrack(project,r.CountTracks(project)-1)
  r.SetMediaTrackInfo_Value(observer,'I_NCHAN',6);r.SetMediaTrackInfo_Value(observer,'I_PERFFLAGS',3)
  r.SetMediaTrackInfo_Value(observer,'B_MAINSEND',1)
  assert(r.TrackFX_AddByName(observer,'JS: am_live_normalization_probe',false,1)>=0,'Cannot load audio observer')
  send=r.CreateTrackSend(macro_track,observer);assert(send>=0)
  r.SetTrackSendInfo_Value(macro_track,0,send,'I_SENDMODE',0);r.SetTrackSendInfo_Value(macro_track,0,send,'D_VOL',1)
  r.SetTrackSendInfo_Value(macro_track,0,send,'I_SRCCHAN',3<<10)
  r.SetTrackSendInfo_Value(macro_track,0,send,'I_DSTCHAN',0)
  r.gmem_attach('AM_LIVE_NORMALIZATION');r.Audio_Init();index=0;select_case()
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local continue=true
  local success,why=xpcall(function()
    local now=r.time_precise();assert(now<deadline,'Timed out: '..cases[index].name..' / '..stage)
    if stage=='baseline'then
      continuity(now);audio(now,true)
      assert(math.abs(select(2,app.preview:get('D_VOLUME'))-1)<1e-10,'Pending analysis changed initial gain')
      if now>=due then
        assert(#record.audio_trace>=2 and math.abs(record.audio_trace[#record.audio_trace].gain_db)<.02,
          'Native audio did not establish unity gain before analysis completion')
        stage='analysis'
      end
    elseif stage=='analysis'or stage=='ramp'or stage=='settle'then
      app.loudness:poll();assert(not app.loudness.error,app.loudness.error)
      local found=app:measurement()
      if found and not measurement then
        measurement=found;target=app:gain()
        assert(found.status=='ready' and A.same(found.analysis,app:analysis_spec()) and found.channels==6)
        assert(target*cases[index].direction>6,'Fixture failed to exercise a substantial gain change')
        record.measurement=U.copy(found);record.target_gain_db=target;record.analysis_seconds=now-started
        record.ramp_started=now-started;stage='ramp'
        check(cases[index].name..': worker completed; applying '..string.format('%.3f dB',target)..' without replay')
      end
      app:update_normalization(now)
      local actual=20*math.log(select(2,app.preview:get('D_VOLUME')),10)
      local change=actual-last_gain
      assert(math.abs(change)<=.150001,'Normalization exceeded the per-update 0.15 dB limit')
      assert(math.abs(change)<=6*(now-last_tick)+.001,'Normalization exceeded 6 dB per second')
      if target then assert(change*cases[index].direction>=-1e-8,'API gain ramp reversed direction')end
      record.max_api_step_db=math.max(record.max_api_step_db,math.abs(change))
      record.api_trace[#record.api_trace+1]={seconds=now-started,gain_db=actual,position=select(2,app.preview:get('D_POSITION'))}
      last_gain=actual;continuity(now);audio(now,true)
      if target and not record.drop_source_gain_db and math.abs(actual)>.3 and math.abs(target-actual)>2 then capture_drop()end
      if stage=='ramp'and cases[index].stop and math.abs(actual)>1 then
        assert(math.abs(target-actual)>2,'Stop test missed the active ramp')
        record.stopped_gain_db=actual;app.preview:stop(true);stopped_starts=app.preview.starts
        due=now+.4;stage='stopped'
      elseif stage=='ramp'and math.abs(actual-target)<1e-7 then
        record.ramp_seconds=now-started-record.ramp_started;due=now+.3;stage='settle'
      elseif stage=='settle'and now>=due then
        assert(previous_audio and math.abs(previous_audio.gain_db-target)<.03,'Audio did not reach the normalization target')
        assert(record.drop_source_gain_db and #record.audio_trace>20,'Ramp/capture coverage was incomplete')
        record.final_audio_gain_db=previous_audio.gain_db
        app.preview:stop(true);stopped_starts=app.preview.starts;due=now+.1;stage='stopped'
      end
    elseif stage=='stopped'then
      app:update_normalization(now);audio(now,false)
      assert(not app.preview:playing()and not app.preview.handle and app.preview.starts==stopped_starts,
        'A pending normalization ramp restarted stopped playback')
      if now>=due then
        assert(app:play(0,true))
        assert(app.preview.starts==stopped_starts+1 and not app.loudness.active and app.loudness.counter==index,
          'Cached replay relaunched analysis or started more than once')
        assert(math.abs(20*math.log(select(2,app.preview:get('D_VOLUME')),10)-target)<1e-8,
          'Cached next play did not begin at final gain')
        record.cached_start_gain_db=target;due=now+.25;stage='cached'
      end
    elseif stage=='cached'then
      app:update_normalization(now)
      assert(math.abs(20*math.log(select(2,app.preview:get('D_VOLUME')),10)-target)<1e-8,
        'An old ramp changed the cached next play')
      audio(now,false)
      if now>=due then
        record.worker_counter=app.loudness.counter
        check(cases[index].name..': bounded audio/API steps, channel ratios, stable playback and cached next play passed')
        continue=select_case()
      end
    end
    last_tick=now
  end,debug.traceback)
  if not success then finish(false,why);return end
  if continue then r.defer(tick)end
end
r.defer(tick)
