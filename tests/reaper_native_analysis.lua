-- Disposable real-REAPER native analysis, Preview gain, and modal D&D capture.
-- Selection UI and drag payloads are injected; decoder, analysis jobs, result
-- files, cache, preview handles and source-volume changes are actual host APIs.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local Model=require('am.model')
local App=require('am.app');local Bank=require('am.bank');local Preview=require('am.preview')
local L=require('am.loudness');local A=require('am.analysis_policy');local Explorer=require('am.media_explorer')
local EXT=require('am.drop').EXT
local saved={context=r.AM_DropContext,result=r.AM_DropResult,explorer=Explorer.new,exec=r.ExecProcess}
local report={status='RUNNING',checks=J.array{},cases=J.array{},host_version=r.GetAppVersion(),
  scope='Actual native analysis and Preview gain; injected selection and capture-only D&D. No analysis subprocess or physical speaker assessment.'}
local app,cases,index,stage,deadline,started,record,handle,starts,target,last_gain,job,probe,due
local data=host..'/native-analysis-data';local directory=host..'/native-analysis-fixtures'
local function check(message)
  report.checks[#report.checks+1]=message
  assert(U.write(host..'/native-analysis-progress.json',J.encode(report)))
end
local function finish(ok,error)
  r.AM_DropContext,r.AM_DropResult,Explorer.new,r.ExecProcess=saved.context,saved.result,saved.explorer,saved.exec
  if app then
    if app.preview then pcall(app.preview.stop,app.preview,true)end
    if app.loudness then pcall(app.loudness.close,app.loudness)end
    if app.bank then pcall(app.bank.close,app.bank)end
  end
  if probe then r.TrackFX_Delete(r.GetMasterTrack(0),probe);probe=nil end
  for _,key in ipairs{'state','prepared','captured','busy','preview_stop','message'}do r.DeleteExtState(EXT,key,false)end
  report.status=ok and 'PASS'or 'FAIL';report.error=error
  assert(U.write(host..'/native-analysis.json',J.encode(report)))
end
local function fixture(name,amplitudes,impulse,rate,frequency)
  rate=rate or 48000
  local n=#amplitudes;local frames={};local frame_count=math.floor(.5*rate);local fade_frames=.025*rate
  for frame=0,frame_count-1 do
    local phase=math.sin(2*math.pi*(frequency or 1000)*frame/rate)
    local envelope=frame<fade_frames and frame/fade_frames or frame>frame_count-fade_frames and (frame_count-frame)/fade_frames or 1
    if impulse then phase=frame==frame_count-1 and 1 or 0;envelope=1 end
    local values={};for ch,value in ipairs(amplitudes)do values[ch]=string.pack('<f',value*phase*envelope)end
    frames[#frames+1]=table.concat(values)
  end
  local pcm=table.concat(frames);local path=directory..'/'..name..'.wav'
  assert(U.write(path,'RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..
    string.pack('<I4I2I2I4I4I2I2',16,3,n,rate,rate*n*4,n*4,32)..'data'..string.pack('<I4',#pcm)..pcm))
  return {path=path,channels=n,sample_rate=rate,duration=frame_count/rate}
end
local function capture(measurement,peak_only)
  local state={project=tostring(app.project),session=app.session,path=app.path,identity=U.copy(app.identity),
    macro=U.copy(app:effective()),settings=U.copy(app.definition.settings),data=data,input=r.GetTrackGUID(app.bank.input),
    analyzer_key=app.loudness.analyzer_key,analysis_job=U.copy(job),defer_items=true}
  -- Deliberately omit the measurement and companion cache: completion must be
  -- read directly from the atomic native result while polling is suspended.
  r.SetExtState(EXT,'state',J.encode(state),false)
  local context={phase='capture',id=index,origin='list',path=app.path,paths=J.array{app.path},items=J.array{}}
  local acknowledged;r.AM_DropContext=function()return J.encode(context)end
  r.AM_DropResult=function(value)acknowledged=value end
  local count=r.CountMediaItems(app.project);dofile(root..'/internal/Process waveform drop.lua')
  assert(acknowledged,r.GetExtState(EXT,'message'))
  local snapshot=J.decode(r.GetExtState(EXT,'captured')).entries[1].snapshot
  assert(A.same(snapshot.analysis,measurement.analysis)and math.abs(snapshot.source_gain_db-L.gain(app:effective(),measurement))<1e-8)
  assert(r.CountMediaItems(app.project)==count and app.preview.handle==handle and app.preview.starts==starts)
  assert(app.loudness.active==job and U.read(job.result),'Modal capture claimed or deleted the active result')
  if app.source_channels>2 then
    assert(snapshot.channel_mix.mode==app.preview.downmix_mode)
    assert(snapshot.source_processing.fx_bypassed==(not app.definition.settings.preview_downmix))
  end
  if peak_only then record.peak_only_drop_gain_db=snapshot.source_gain_db
  else
    record.drop_gain_db=snapshot.source_gain_db;record.drop_analysis=U.copy(snapshot.analysis)
    record.result_before_companion_poll=true
  end
  r.DeleteExtState(EXT,'captured',false);r.DeleteExtState(EXT,'state',false)
end
local function next_case()
  index=index+1
  if index>#cases then
    check('Native LUFS/Max/P95, calibration, original/downmix channel bases, modal result pickup, smooth Preview and cached replay passed')
    finish(true);return false
  end
  local case=cases[index];app.preview:stop(true)
  local n=app.definition.raw.normalization;n.metric=case.metric;n.target_sones=case.target or Model.DEFAULT_TARGET_SONES
  n.enabled=not case.peak_only;app.definition.raw.source_peak_guard.enabled=case.peak_only or false
  n.reference_dbfs=case.reference_dbfs or -20;n.reference_spl_db=case.reference_spl_db or 79
  app.definition.settings.preview_downmix=case.downmix or false
  app.definition.settings.preview_downmix_mode='auto';app.effective_macro=nil
  app.path=case.fixture.path;app.identity=assert(L.identity(r,app.path));app.source_channels=case.fixture.channels
  app:configure_channels();assert(not app:measurement(),'A changed target/calibration/meter reused an old cache')
  record={name=case.name,metric=case.metric,source_channels=app.source_channels,sample_rate=case.fixture.sample_rate,
    analysis=U.copy(app:analysis_spec()),max_gain_step_db=0}
  report.cases[#report.cases+1]=record
  assert(app:play(0,true));handle=app.preview.handle;starts=app.preview.starts;job=app.loudness.active
  assert(job and job.native_job_id>0 and app.loudness.counter==index)
  if case.peak_only then assert(not(job.analysis and job.analysis.meter),'Peak protection launched Zwicker')end
  assert(math.abs(select(2,app.preview:get('D_VOLUME'))-1)<1e-10)
  started=r.time_precise();deadline=started+120;stage='result';last_gain=0
  record.native_job_id=job.native_job_id;check(case.name..': native analysis started')
  return true
end
local ok,error=xpcall(function()
  require('am.native').require(r)
  assert(r.APIExists('AM_AnalysisStart')and r.APIExists('AM_AnalysisCancel'))
  r.ExecProcess=function()error('Native analysis attempted to launch an external process')end
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  r.RecursiveCreateDirectory(directory,0);r.RecursiveCreateDirectory(data..'/chains',0)
  local mono=fixture('mono',{.08});local stereo=fixture('stereo',{.06,.08})
  local multi=fixture('generic6',{.02,.03,.04,.05,.06,.07});local ambix=fixture('field_ambix_4',{.05,.02,.04,.08})
  local quiet=fixture('calibrated_quiet',{1e-6})
  local click=fixture('eof_impulse',{.2},true)
  local transient=fixture('near_full_scale_impulse',{.95},true)
  local bass=fixture('near_full_scale_bass',{.95},false,48000,25)
  local guard=fixture('peak_only_six',{.02,.03,.04,.05,.06,.95})
  local mono44=fixture('mono_44100',{.08},false,44100);local mono96=fixture('mono_96000',{.08},false,96000)
  cases={{name='mono LUFS MaxM',fixture=mono,metric='lufs_m_max'},
    {name='mono Zwicker Max',fixture=mono,metric='zwicker_max'},
    {name='stereo Zwicker P95',fixture=stereo,metric='zwicker_p95'},
    {name='generic OFF Zwicker Max',fixture=multi,metric='zwicker_max'},
    {name='generic ON Zwicker Max',fixture=multi,metric='zwicker_max',downmix=true},
    {name='AmbiX OFF W Zwicker Max',fixture=ambix,metric='zwicker_max'},
    {name='AmbiX ON W/Y Zwicker P95',fixture=ambix,metric='zwicker_p95',downmix=true},
    {name='changed target and calibration',fixture=mono,metric='zwicker_max',target=16,reference_spl_db=83},
    {name='quiet digital signal at calibrated SPL',fixture=quiet,metric='zwicker_max',reference_dbfs=-120},
    {name='EOF impulse response tail',fixture=click,metric='zwicker_max'},
    {name='mono LUFS MaxM 44.1 kHz',fixture=mono44,metric='lufs_m_max'},
    {name='mono LUFS MaxM 96 kHz',fixture=mono96,metric='lufs_m_max'},
    {name='mono Zwicker Max 44.1 kHz',fixture=mono44,metric='zwicker_max'},
    {name='mono Zwicker Max 96 kHz',fixture=mono96,metric='zwicker_max'},
    {name='default guard OFF transient LUFS',fixture=transient,metric='lufs_m_max',peak_test=true},
    {name='default guard OFF bass Zwicker Max',fixture=bass,metric='zwicker_max',peak_test=true},
    {name='default guard OFF bass Zwicker P95',fixture=bass,metric='zwicker_p95',peak_test=true},
    {name='Normalize OFF peak guard with Zwicker selected',fixture=guard,metric='zwicker_max',peak_only=true}}
  local corpus=U.read(host..'/loudness-corpus.json')
  if corpus then
    for _,entry in ipairs(J.decode(corpus))do
      for _,metric in ipairs{'zwicker_max','zwicker_p95'}do
        cases[#cases+1]={name='corpus '..entry.id..' '..metric,metric=metric,fixture=entry.fixture,
          expected=entry[metric],target=entry.target_sones}
      end
    end
  end
  report.case_count=#cases
  local definition=Model.defaults();definition.macros=J.array{};definition.slots={}
  definition.raw.normalization.enabled=true;definition.raw.normalization.target_lufs=-18
  assert(not definition.raw.source_peak_guard.enabled and definition.raw.source_peak_guard.ceiling_dbtp==-1)
  definition.settings.loop=true;definition.settings.monitor_gain_db=0;definition.settings.preview_fade_ms=0
  definition.settings.analysis_timeout_seconds=90
  local project=r.EnumProjects(-1)
  app=setmetatable({r=r,root=root,data=data,project=project,definition=definition,session='native-analysis',message='',
    sync_transform=function()end,sync_range=function()return false end},App)
  app.explorer={selection=function()return app.path end,ensure_waveform=function()end}
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  app.bank=Bank.new(r,project,data,definition,app.session);app.preview=Preview.new(r,project,app.bank.input)
  app.loudness=L.new(r,root,data,definition.settings,app.session)
  -- Observe the actual stereo output and silence it before physical playback.
  probe=r.TrackFX_AddByName(r.GetMasterTrack(0),'JS: am_response_probe',false,-1)
  assert(probe>=0,'Missing silent response probe');r.gmem_attach('AuditionMacro.ResponseTest');r.gmem_write(0,0)
  assert(app.loudness.analyzer_key==L.ANALYZER_KEY and not app.loudness.python and not app.loudness.ffmpeg)
  report.analyzer_key=app.loudness.analyzer_key;report.external_analysis_process=false
  r.Audio_Init();index=0;next_case()
end,debug.traceback)
if not ok then finish(false,error);return end
local function tick()
  local again=true
  local success,why=xpcall(function()
    local now=r.time_precise();assert(now<deadline,'Timed out: '..cases[index].name..' / '..stage)
    assert(app.preview.handle==handle and app.preview.starts==starts and app.preview:playing(),'Analysis restarted Preview')
    if stage=='result'then
      if r.APIExists('AM_AnalysisStatus')then record.native_progress=J.decode(r.AM_AnalysisStatus(job.native_job_id))end
      local result,status,detail=L.completed_result(job,app.identity,app.loudness.analyzer_key,app:analysis_spec())
      assert(status~='error'and status~='cancelled',detail or status)
      if result then
        assert(result.status=='ready','A non-silent calibrated fixture was classified as silence')
        assert(math.abs(result.duration-cases[index].fixture.duration)<1e-6,'Sample-rate conversion changed the source duration')
        if cases[index].metric~='lufs_m_max'and not cases[index].peak_only then
          assert(result.zwicker_sones>0 and result.zwicker_tail_seconds==.4,'Zwicker response tail was omitted')
        end
        record.measurement=U.copy(result);record.analysis_seconds=now-started
        target=L.gain(app:effective(),result);record.target_gain_db=target
        local expected=cases[index].expected
        if expected then
          assert(math.abs(result.max_momentary_lufs-expected.source_lufs_m_max)<.01,'Corpus LUFS differs from the offline kernels')
          assert(math.abs(result.true_peak_dbtp-expected.source_true_peak_dbtp)<.01,'Corpus peak differs from the offline kernels')
          assert(math.abs(target-expected.gain_db)<.03,'Corpus default gain differs from calibration')
          record.normalized_lufs_m_max=result.max_momentary_lufs+target
          record.calibration_gain_error_db=target-expected.gain_db
        end
        record.normalized_source_peak_dbtp=result.true_peak_dbtp+target
        assert(record.normalized_source_peak_dbtp<=-1+1e-8,'Normalize exceeded the default source ceiling')
        if cases[index].peak_test then
          local n=app:effective().normalization
          local requested=cases[index].metric=='lufs_m_max' and n.target_lufs-result.max_momentary_lufs or result.normalization_gain_db
          record.legacy_source_peak_dbtp=result.true_peak_dbtp+math.min(requested,n.max_boost_db)
          assert(record.legacy_source_peak_dbtp>0,'Transient fixture did not reproduce unsafe normalization')
          assert(select(2,L.gain(app:effective(),result))=='source peak capped')
        end
        capture(result)
        if result.analysis and result.analysis.meter then
          local n=app.definition.raw.normalization;local guard=app.definition.raw.source_peak_guard
          local enabled=guard.enabled;n.enabled=false;guard.enabled=true;app.effective_macro=nil
          capture(L.without_meter(result),true)
          n.enabled=true;guard.enabled=enabled;app.effective_macro=nil
        end
        app.loudness:poll();assert(not app.loudness.error and app:measurement())
        if result.analysis and result.analysis.meter then
          local n=app.definition.raw.normalization;local before=app.loudness.counter
          n.enabled=false;app.effective_macro=nil
          assert(app:request_analysis()and app.loudness.counter==before and not app.loudness.active)
          record.reused_peak_measurement=true;n.enabled=true;app.effective_macro=nil
        end
        app:update_normalization(now);stage='ramp';deadline=now+30
        check(cases[index].name..': native atomic result captured by D&D before polling')
      end
    elseif stage=='ramp'then
      app:update_normalization(now)
      local actual=20*math.log(select(2,app.preview:get('D_VOLUME')),10)
      record.max_gain_step_db=math.max(record.max_gain_step_db,math.abs(actual-last_gain))
      assert(math.abs(actual-last_gain)<=.150001,'Gain changed by more than the smooth per-tick bound')
      last_gain=actual
      if math.abs(actual-target)<1e-7 then
        local before=app.loudness.counter;app.preview:stop(true);assert(app:play(0,true))
        assert(not app.loudness.active and app.loudness.counter==before)
        assert(math.abs(20*math.log(select(2,app.preview:get('D_VOLUME')),10)-target)<1e-8)
        record.final_preview_gain_db=actual;record.cached_start_gain_db=target
        if cases[index].peak_test then
          handle=app.preview.handle;starts=app.preview.starts
          r.gmem_write(0,0);due=now+1.25;stage='audio';deadline=now+5
        else again=next_case()end
      end
    elseif stage=='audio'and now>=due then
      local peak=0;local blocks=math.floor(r.gmem_read(0))
      -- Skip the observer's first previous block after resetting the counter.
      for i=1,blocks-1 do peak=math.max(peak,r.gmem_read(3+i*5))end
      record.output_sample_peak=peak;record.observed_blocks=blocks
      assert(peak>.5 and peak<=U.gain(-1)*1.02,'Normalized Raw output was silent or exceeded its ceiling: '..peak)
      assert(r.GetMediaTrackInfo_Value(app.bank.input,'B_MUTE')==0 and r.GetMediaTrackInfo_Value(app.bank.raw,'B_MUTE')==0)
      check(cases[index].name..': actual audio remains audible below the source ceiling')
      again=next_case()
    end
  end,debug.traceback)
  if not success then finish(false,why);return end
  if again then r.defer(tick)end
end
r.defer(tick)
