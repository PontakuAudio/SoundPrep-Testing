local U=require('am.util');local J=require('am.json');local L=require('am.loudness');local Model=require('am.model')
local Analysis=require('am.analysis_policy')
local Drop=require('am.drop');local E=require('am.export');local Render=require('am.render_item');local Explorer=require('am.media_explorer')
local read,snapshot,stamp,render,explorer,reaper_before=U.read,E.snapshot,Render.stamp,Render.render,Explorer.new,reaper
local files,ext,context,ack,console={},{},nil,nil,''
local project={};local mutations,renders,snapshots,sources,destroyed=0,0,0,0,0
local a={path='/test/MixPre-002.WAV',size=100,mtime=10};local b={path='/test/other.wav',size=200,mtime=20}
local identities={[a.path]=a,[b.path]=b};local channels=2
local r={
  APIExists=function(name)return name=='AM_DropContext'end,
  AM_DropContext=function()return J.encode(context)end,
  AM_DropResult=function(ok)ack=ok end,
  EnumProjects=function()return project,''end,time_precise=function()return 10 end,
  SetExtState=function(section,key,value)ext[section..':'..key]=value end,
  GetExtState=function(section,key)return ext[section..':'..key]or ''end,
  DeleteExtState=function(section,key)ext[section..':'..key]=nil end,
  ShowConsoleMsg=function(text)console=console..text end,
  JS_File_Stat=function(path)local identity=identities[path];return identity and 0 or -1,identity and identity.size,0,identity and identity.mtime end,
  PCM_Source_CreateFromFile=function(path)sources=sources+1;return {path=path}end,
  PCM_Source_Destroy=function()destroyed=destroyed+1 end,
  GetMediaSourceLength=function()return 636,false end,GetMediaSourceNumChannels=function()return channels end,
  GetMediaSourceType=function()return 'WAVE'end,
  InsertTrackAtIndex=function()mutations=mutations+1 end,AddMediaItemToTrack=function()mutations=mutations+1 end,
  SetMediaTrackInfo_Value=function()mutations=mutations+1 end,
}
local function measurement(identity,analysis)
  return {status='ready',identity=U.copy(identity or a),profile=L.profile(analysis),analyzer_key='analyzer',analysis=U.copy(analysis),
    channels=analysis and analysis.source_channels or 2,duration=636,max_momentary_lufs=-24,true_peak_dbtp=-18,job_id='session:1'}
end
local function job(identity,analysis)
  return {identity=U.copy(identity or a),analysis=U.copy(analysis),job_id='session:1',result='/jobs/1.result.json',cancel='/jobs/1.cancel',started=0}
end
local function state()
  local bank=Model.defaults();bank.raw.normalization.enabled=true;bank.raw.normalization.target_lufs=-18
  return {project=tostring(project),session='session',path=a.path,identity=U.copy(a),macro=Model.effective(bank,nil),
    settings=bank.settings,data='/normalized-drop',analyzer_key='analyzer',input='input',defer_items=true}
end
local function invoke(s,phase,paths)
  context={id=1,phase=phase or 'prepare',origin=paths and 'list' or 'waveform',path=a.path,paths=paths or {a.path},
    preview={path=a.path,mode=256,start=.1,['end']=.5}}
  ext={};r.SetExtState(Drop.EXT,'state',J.encode(s));ack=nil;console='';snapshots=0
  dofile('./internal/Process waveform drop.lua')
  assert(ack~=nil,'Drop did not return a result')
  assert(mutations==0 and renders==0,'Preflight changed the project or rendered audio')
  assert(sources==destroyed,'Preflight leaked a PCM source')
  return ack,r.GetExtState(Drop.EXT,'message')
end
local function refused(s,prefix,paths)
  local ok,message=invoke(s,nil,paths)
  assert(not ok and message:find('Drop cancelled: '..prefix,1,true),message)
  assert(not console:find('stack traceback:',1,true),'Expected refusal leaked a stack trace')
  assert(r.GetExtState(Drop.EXT,'prepared')=='','Rejected batch retained a prepared transaction')
  return message
end
local ok,err=xpcall(function()
  reaper=r;U.read=function(path)return files[path]end
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  E.snapshot=function(_,path,macro,chain,gain,identity,range)
    snapshots=snapshots+1
    return {path=path,macro=macro,chain=chain,source_gain_db=gain,identity=identity,range=range}
  end
  Render.stamp=function(_,value)value.item_render={revision=2}end
  Render.render=function()renders=renders+1;error('Preflight attempted a render')end

  -- An atomic worker result can arrive during the native modal drag while the
  -- companion's memory/cache and the published measurement remain untouched.
  local s=state();s.analysis_job=job();files[s.analysis_job.result]=J.encode(measurement())
  local before=J.encode(s.analysis_job)
  assert(invoke(s));assert(console=='')
  local prepared=J.decode(r.GetExtState(Drop.EXT,'prepared'))
  assert(#prepared.entries==1 and prepared.entries[1].snapshot.source_gain_db==6)
  assert(J.encode(s.analysis_job)==before and files[s.analysis_job.result] and not files['/normalized-drop/cache/'..L.key(a,'analyzer')..'.json'],
    'Drop pickup took ownership of the companion worker or published its cache')
  assert(invoke(s,'capture'));assert(r.GetExtState(Drop.EXT,'prepared')=='')
  local captured=J.decode(r.GetExtState(Drop.EXT,'captured'))
  assert(captured.entries[1].snapshot.source_gain_db==6,'Windows capture did not use the completed result')

  -- Updated companions accept pending/missing analysis without changing the
  -- project during preflight; the frozen batch carries the unresolved work.
  files={};s.defer_analysis=true
  assert(invoke(s));local queued=J.decode(r.GetExtState(Drop.EXT,'prepared'))
  assert(queued.analysis_pending and queued.entries[1].analysis_pending and queued.entries[1].snapshot.macro.normalization.enabled)
  assert(invoke(s,'capture'));assert(J.decode(r.GetExtState(Drop.EXT,'captured')).entries[1].analysis_pending)
  local pending_job=s.analysis_job;s.analysis_job=nil
  assert(invoke(s,nil,{a.path,b.path}));queued=J.decode(r.GetExtState(Drop.EXT,'prepared'))
  assert(#queued.entries==2 and queued.entries[1].analysis_pending and queued.entries[2].analysis_pending)
  s.path=b.path;s.identity=U.copy(b)
  assert(invoke(s),'A fresh native waveform was rejected by the previous selection heartbeat')
  s.path=a.path;s.identity=U.copy(a)
  s.analysis_job=pending_job;s.defer_analysis=nil
  files={};refused(s,'Analysis pending:')
  files[s.analysis_job.result]=J.encode{job_id='session:1',status='error',error='FFmpeg analysis timed out'}
  assert(refused(s,'Analysis failed:'):find('FFmpeg analysis timed out',1,true))
  files[s.analysis_job.result]=J.encode(measurement());s.analysis_job.cancelled=true
  refused(s,'Analysis required:');s.analysis_job.cancelled=nil
  files[s.analysis_job.cancel]='cancel';refused(s,'Analysis required:');files[s.analysis_job.cancel]=nil
  for _,change in ipairs{
    function(v)v.job_id='other:1'end,function(v)v.identity=b end,function(v)v.profile='obsolete'end,
    function(v)v.analyzer_key='other'end,function(v)v.channels=4 end,function(v)v.duration=-1 end,
    function(v)v.max_momentary_lufs=J.null end,function(v)v.true_peak_dbtp=J.null end,
  }do
    local value=measurement();change(value);files[s.analysis_job.result]=J.encode(value);refused(s,'Analysis failed:')
  end
  files[s.analysis_job.result]='42';refused(s,'Analysis failed:')
  files[s.analysis_job.result]='{';refused(s,'Analysis failed:')
  files={};s=state();refused(s,'Analysis required:')
  s.analysis_error='Set Python and FFmpeg paths in Settings';s.analysis_identity=U.copy(a)
  assert(refused(s,'Analysis failed:'):find('Set Python and FFmpeg paths',1,true))
  s.analysis_identity=U.copy(b);refused(s,'Analysis required:')

  -- Reject untrusted/stale serialized measurements before consulting the disk
  -- cache; a pending snapshot must not hide an independently valid cache.
  for _,invalid in ipairs{{status='pending'},{status='ready'},J.null,'invalid'}do
    s=state();s.measurement=invalid;files={};refused(s,'Analysis required:')
    files['/normalized-drop/cache/'..L.key(a,'analyzer')..'.json']=J.encode(measurement())
    assert(invoke(s));assert(J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot.source_gain_db==6)
  end
  -- Modal D&D uses the same chosen cache as the companion, including a
  -- multi-file selection with no published in-memory measurement.
  s=state();s.settings.cache_directory='/external/Cache 音声';files={}
  for _,id in ipairs{a,b}do files[s.settings.cache_directory..'/'..L.key(id,'analyzer')..'.json']=J.encode(measurement(id))end
  assert(invoke(s,nil,{a.path,b.path}))
  assert(#J.decode(r.GetExtState(Drop.EXT,'prepared')).entries==2)
  s.settings.cache_directory='';refused(s,'Analysis required:',{a.path,b.path})
  s=state();s.measurement=measurement();s.measurement.identity=b;files={};refused(s,'Analysis required:')
  s.measurement=measurement();s.measurement.profile='obsolete';refused(s,'Analysis required:')
  s.measurement=measurement();s.measurement.analyzer_key='other';refused(s,'Analysis required:')
  s.measurement=measurement();s.measurement.status='silence';s.measurement.max_momentary_lufs=J.null;s.measurement.true_peak_dbtp=J.null
  assert(invoke(s));assert(J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot.source_gain_db==0)

  s=state();s.measurement=measurement();files={}
  refused(s,'Analysis required:',{a.path,b.path})
  assert(snapshots==1,'The test must reach the missing second batch measurement')
  s.macro.normalization.enabled=false;s.macro.source_peak_guard.enabled=true;s.measurement=nil
  refused(s,'Analysis required:')
  s.macro.source_peak_guard.enabled=false;assert(invoke(s),'Unnormalized drop unnecessarily required analysis')
  channels=4
  assert(invoke(s),'Multichannel drop was rejected')
  local multi=J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot
  assert(multi.channel_mix.mode==0 and multi.channel_mix.source_channels==4 and multi.channel_mix.output_channels==4)
  assert(multi.source_gain_db==0 and not multi.macro.normalization.enabled and not multi.macro.source_peak_guard.enabled)
  assert(multi.source_processing.fx_bypassed and multi.analysis.basis=='loudest_channel')
  -- Multichannel normalization now requires its own completed measurement,
  -- including the common peak-guard limit applied to every original channel.
  s=state();files={};s.measurement=measurement();refused(s,'Analysis required:')
  local analysis=assert(Analysis.resolve(a.path,channels,s.settings))
  s.analysis_job=job(nil,analysis);refused(s,'Analysis pending:')
  local multi_measurement=measurement(nil,analysis);multi_measurement.true_peak_dbtp=-3
  files[s.analysis_job.result]=J.encode(multi_measurement);s.macro.source_peak_guard.enabled=true
  assert(invoke(s))
  multi=J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot
  assert(multi.source_gain_db==2 and Analysis.same(multi.analysis,analysis))
  assert(multi.macro.normalization.enabled and multi.macro.source_peak_guard.enabled)
  s.settings.preview_downmix=true
  refused(s,'Analysis required:') -- The completed OFF result cannot normalize ON.
  channels=2

  -- In-memory values receive the same validation as persisted measurements.
  local key=L.key(a,'analyzer');local cache=setmetatable({data='/normalized-drop',analyzer_key='analyzer',keys={},memory={}},L)
  cache.memory[key]=measurement();cache.memory[key].true_peak_dbtp=0/0
  files={};assert(not cache:get(a),'Non-finite cached measurement was accepted')
  assert(not L.matches_measurement(measurement(),a,nil))
  assert(not L.same('invalid',a) and not L.same({},{}))

  -- Zwicker modal pickup applies the same solved gain as live Preview, with
  -- the exact target/calibration frozen into the recipe. No LUFS substitute.
  for _,count in ipairs{2,4}do
    channels=count;files={};s=state();s.macro.normalization.metric='zwicker_max'
    local spec=assert(Analysis.resolve(a.path,channels,s.settings,s.macro.normalization))
    local solved=measurement(nil,spec);solved.zwicker_sones=2.7;solved.normalization_gain_db=-5.25;solved.gain_status='ready'
    s.analysis_job=job(nil,spec);files[s.analysis_job.result]=J.encode(solved)
    assert(invoke(s));local frozen=J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot
    assert(frozen.source_gain_db==L.gain(s.macro,solved)and frozen.source_gain_db==-5.25)
    assert(Analysis.same(frozen.analysis,spec)and frozen.macro.normalization.metric=='zwicker_max')
    solved.normalization_gain_db=24;solved.true_peak_dbtp=-.25
    assert(not s.macro.source_peak_guard.enabled)
    files[s.analysis_job.result]=J.encode(solved)
    assert(invoke(s));local limited=J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot
    assert(limited.source_gain_db==-.75,'D&D bypassed the automatic Normalize peak ceiling')
    s.macro.normalization.target_sones=16
    refused(s,'Analysis required:')
    assert(frozen.analysis.meter.target_sones==36 and frozen.macro.normalization.target_sones==36)
    -- With Normalize off only the mapped source peak is needed. A completed
    -- Zwicker result remains sufficient even after changing its unused target.
    s.macro.normalization.enabled=false;s.macro.source_peak_guard.enabled=true
    assert(invoke(s));assert(J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot.source_gain_db==-.75)
    files={};s.analysis_job=nil;s.measurement=solved
    assert(invoke(s),'A published full measurement could not supply peak-only drop gain')
    assert(J.decode(r.GetExtState(Drop.EXT,'prepared')).entries[1].snapshot.source_gain_db==-.75)
    s.measurement=nil;s.macro.normalization.target_sones=36
    files['/normalized-drop/cache/'..L.key(a,'analyzer',spec)..'.json']=J.encode(solved)
    assert(invoke(s),'An existing full disk cache did not satisfy a peak-only drop')
    s.macro.normalization.enabled=true;s.macro.normalization.target_sones=16
    refused(s,'Analysis required:')
  end
  channels=2

  -- Publishing a worker does not leak its per-frame poll timestamp or assign
  -- another selection's analysis failure to the active file.
  local app={project=project,session='session',path=a.path,identity=a,data='/normalized-drop',definition=Model.defaults(),message='',
    loudness={active=job(),wanted=b,error='Other file failed',analyzer_key='analyzer'},
    bank={input='input'},check_project=function()return true end,
    explorer={control=function(_,id)return id end},effective=function()return state().macro end,measurement=function()end}
  app.loudness.active.last_poll=10
  r.JS_Window_IsWindow=function()return true end;r.GetTrackGUID=function(v)return v end
  local drop=setmetatable({r=r,app=app,attached=true,wave=1046,list=1001,arrange='arrange',
    peaks={tick=function()end},resources={tick=function()end}},Drop)
  ext={};drop:tick();local published=J.decode(r.GetExtState(Drop.EXT,'state'))
  assert(published.analysis_job.job_id=='session:1' and not published.analysis_job.last_poll and not published.analysis_error)
  assert(app.loudness.active.last_poll==10,'Publishing mutated the active worker')
  app.loudness.wanted=U.copy(a);drop:tick();published=J.decode(r.GetExtState(Drop.EXT,'state'))
  assert(published.analysis_error=='Other file failed' and L.same(published.analysis_identity,a))
  app.source_channels=4
  local wanted=assert(Analysis.resolve(a.path,4,app.definition.settings))
  app.loudness.wanted_analysis=U.copy(wanted);app.loudness.active.analysis=U.copy(wanted)
  drop:tick();published=J.decode(r.GetExtState(Drop.EXT,'state'))
  assert(Analysis.same(published.analysis_job.analysis,wanted) and Analysis.same(published.analysis_spec,wanted))
  app.definition.settings.preview_downmix=true
  drop:tick();published=J.decode(r.GetExtState(Drop.EXT,'state'))
  assert(not published.analysis_error and not published.analysis_identity,'Old OFF failure was published for the ON basis')
  assert(Analysis.same(published.analysis_job.analysis,wanted),'Publishing changed the running job basis')
  wanted=assert(Analysis.resolve(a.path,4,app.definition.settings))
  app.loudness.wanted_analysis=U.copy(wanted);app.loudness.error='Current basis failed'
  drop:tick();published=J.decode(r.GetExtState(Drop.EXT,'state'))
  assert(published.analysis_error=='Current basis failed' and Analysis.same(published.analysis_spec,wanted))
end,debug.traceback)
U.read,E.snapshot,Render.stamp,Render.render,Explorer.new,reaper=read,snapshot,stamp,render,explorer,reaper_before
assert(ok,err)
