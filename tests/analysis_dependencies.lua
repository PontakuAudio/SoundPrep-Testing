local A=require('am.analysis_policy');local L=require('am.loudness');local Model=require('am.model')
local App=require('am.app');local U=require('am.util');local J=require('am.json')
local identity={path='/six.wav',size=100,mtime=10}
local definition=Model.defaults();definition.raw.normalization.enabled=true
local macro=Model.effective(definition,nil)
local function spec(m,settings)return A.resolve(identity.path,6,settings or definition.settings,m.normalization)end
local basic=spec(macro)
-- These controls operate after source measurement; they must never launch a
-- fresh worker or change the measurement cache key.
for _,change in ipairs{
  function(m)m.normalization.target_lufs=-24 end,
  function(m)m.normalization.max_boost_db=3 end,
  function(m)m.source_peak_guard.ceiling_dbtp=-6 end,
  function(m)m.source_peak_guard.enabled=true end,
  function(m)m.output_gain_db=6 end,
  function(m)m.source_transform.pitch_semitones=7 end,
  function(m)m.source_transform.rate=.5 end,
  function(m)m.source_transform.reverse=true end,
  function(m)m.source_transform.preserve_pitch=true end,
  function(m)m.export.tail_seconds=4 end,
}do local changed=U.copy(macro);change(changed);assert(A.same(basic,spec(changed)))end
macro.normalization.metric='zwicker_max';local full=spec(macro)
for _,change in ipairs{
  function(n)n.metric='zwicker_p95'end,function(n)n.target_sones=16 end,
  function(n)n.reference_dbfs=-18 end,function(n)n.reference_spl_db=83 end,
}do
  local changed=U.copy(macro);change(changed.normalization)
  assert(not A.same(full,spec(changed)),'Enabled Zwicker reused an obsolete solver result')
  changed.normalization.enabled=false
  assert(A.same(basic,spec(changed)),'Peak-only analysis depends on disabled normalization settings')
end
macro.normalization.enabled=false;macro.source_peak_guard.enabled=true
assert(A.same(basic,spec(macro))and A.same(basic,A.without_meter(full)))
local settings=U.copy(definition.settings);settings.preview_downmix=true
assert(not A.same(basic,spec(macro,settings)))
settings.channel_selections={['6']={left=5,right=6}}
local selected=spec(macro,settings);assert(selected.basis=='selected_channels'and not selected.meter)
settings.preview_downmix=false;settings.preview_downmix_mode='ambix'
assert(A.same(selected,spec(macro,settings)),'Inactive downmix preferences changed a selected-pair measurement')
settings.channel_selections['6'].left=4;assert(not A.same(selected,spec(macro,settings)))

local read,write,remove=U.read,U.write,os.remove
local files,launches,reads,now={},0,0,0
local r={time_precise=function()return now end,RecursiveCreateDirectory=function()end,
  JS_File_Stat=function()return 0,identity.size,0,identity.mtime end,
  AM_AnalysisStart=function()launches=launches+1;return launches end,AM_AnalysisCancel=function()return true end}
local function cache()return L.new(r,'/root','/dependency-data',definition.settings,'dependencies')end
local function result(analysis,job)
  return {status='ready',job_id=job or 'old:1',identity=U.copy(identity),analysis=U.copy(analysis),
    analyzer_key=L.ANALYZER_KEY,profile=L.profile(analysis),channels=6,duration=10,
    max_momentary_lufs=-24,true_peak_dbtp=2,zwicker_sones=40,normalization_gain_db=-9,gain_status='ready'}
end
local function filename(analysis)return '/dependency-data/cache/'..L.key(identity,L.ANALYZER_KEY,analysis)..'.json'end
local ok,err=xpcall(function()
  U.read=function(path)reads=reads+1;return files[path]end
  U.write=function(path,text)files[path]=text;return true end
  os.remove=function(path)files[path]=nil;return true end
  -- An installed cache from before this change can satisfy peak protection
  -- without any audio reread, worker or cache-file mutation.
  local measured=result(full);files[filename(full)]=J.encode(measured)
  definition.raw.normalization=U.copy(macro.normalization);definition.raw.source_peak_guard=U.copy(macro.source_peak_guard)
  local app=setmetatable({r=r,definition=definition,path=identity.path,identity=identity,source_channels=6,loudness=cache()},App)
  assert(app:request_analysis()and launches==0 and not app.loudness.active)
  assert(app:gain()==-3 and A.same(app:measurement().analysis,basic))
  assert(not files[filename(basic)],'Reading a legacy cache wrote a new file')
  local previous=reads;for _=1,20 do assert(app:measurement())end
  assert(reads==previous,'A reused meter kept hitting the disk')
  -- Disabled targets/calibration can change without touching audio again.
  for _,change in ipairs{
    function(n)n.target_sones=24 end,function(n)n.metric='zwicker_p95'end,
    function(n)n.reference_spl_db=85 end,
  }do
    change(definition.raw.normalization);app.effective_macro=nil
    assert(app:request_analysis()and launches==0 and app:gain()==-3)
  end
  -- A cold peak-only request uses the basic native worker, never Zwicker.
  files={};app.loudness=cache();assert(not app:request_analysis())
  assert(launches==1 and not app.loudness.active.analysis.meter)
  -- Completion saves reusable source meters independently of a Zwicker target.
  files={};local c=cache();c:request(identity,false,full);local job=c.active
  files[job.result]=J.encode(result(full,job.job_id));now=1;c:poll()
  assert(files[filename(full)]and files[filename(basic)]and not c.active)
  local restarted=cache();assert(restarted:request(identity,false,basic))
  assert(launches==2 and not restarted.active and not restarted:get(identity,selected))
  local changed=U.copy(identity);changed.mtime=11;assert(not restarted:get(changed,basic))
  -- Modal pickup uses an already complete full result without claiming it.
  files[job.result]=J.encode(result(full,job.job_id))
  local picked=L.completed_result(job,identity,L.ANALYZER_KEY,basic)
  assert(picked and A.same(picked.analysis,basic)and L.gain(macro,picked)==-3 and files[job.result])
  assert(not L.completed_result(job,identity,L.ANALYZER_KEY,selected))
  local selected_full=U.copy(full);selected_full.revision=3;selected_full.basis='selected_channels'
  selected_full.selection=U.copy(selected.selection)
  local mapped=L.for_analysis(result(selected_full),identity,L.ANALYZER_KEY,selected)
  assert(mapped and A.same(mapped.analysis,selected)and L.gain(macro,mapped)==-3)
  assert(not L.for_analysis(result(selected_full),identity,L.ANALYZER_KEY,basic),
    'Selected-pair peaks leaked into the full-channel guard')
  -- The two meters have different silence criteria; finite peak protection
  -- must survive either classification when projecting the shared meters.
  measured.max_momentary_lufs=-110;measured.true_peak_dbtp=2
  local projected=L.without_meter(measured)
  assert(projected.status=='silence'and L.gain(macro,projected)==-3)
  measured.status='silence';measured.max_momentary_lufs=-24
  projected=L.without_meter(measured);assert(projected.status=='ready')
  -- Explicit refresh still invalidates the fallback instead of immediately
  -- declaring completion from the old full result.
  c=cache();c:request(identity,true,basic,full)
  assert(c.active and not c:get(identity,basic,full))
end,debug.traceback)
U.read,U.write,os.remove=read,write,remove;assert(ok,err)
