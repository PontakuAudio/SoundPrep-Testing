local A=require('am.analysis_policy');local L=require('am.loudness');local M=require('am.model')
local U=require('am.util');local J=require('am.json');local E=require('am.export')
local bank=M.defaults();assert(bank.raw.normalization.metric=='lufs_m_max')
for _,normalization in ipairs{bank.raw.normalization,bank.macros[1].normalization}do
  normalization.target_sones=nil;normalization.reference_dbfs=nil;normalization.reference_spl_db=nil
end
M.validate(bank)
assert(bank.raw.normalization.target_sones==36 and bank.raw.normalization.reference_dbfs==-20 and bank.raw.normalization.reference_spl_db==79)
assert(bank.macros[1].normalization.metric=='lufs_m_max'and bank.macros[1].normalization.target_sones==36)
assert(A.meter{metric='zwicker_max'}.target_sones==36,'Descriptor fallback differs from the new preset target')
for _,metric in ipairs{'lufs_m_max','zwicker_max','zwicker_p95'}do
  bank.raw.normalization.metric=metric
  assert(M.validate(J.decode(J.encode(bank))).raw.normalization.metric==metric)
end
for _,change in ipairs{
  function(n)n.metric='zwicker'end,function(n)n.target_sones=0 end,function(n)n.target_sones=257 end,
  function(n)n.reference_dbfs=-121 end,function(n)n.reference_spl_db=141 end,function(n)n.target_sones=0/0 end,
}do local invalid=U.copy(bank);change(invalid.raw.normalization);assert(not pcall(M.validate,invalid))end

local macro=M.macro('test','Test');local n=macro.normalization;n.enabled=true;n.metric='zwicker_max'
local identity={path='/field_ambix.wav',size=100,mtime=1};local keys={}
for _,count in ipairs{1,2,4,6,128}do
  for _,downmix in ipairs{false,true}do
    local spec=assert(A.resolve(identity.path,count,{preview_downmix=downmix},n))
    assert(A.valid(spec)and spec.revision==2 and spec.source_channels==count and U.equal(spec.meter,A.meter(n)))
    if count<=2 then assert(spec.basis=='source')
    elseif count==4 then assert(spec.basis==(downmix and 'downmix_ambix' or 'ambix_w'))
    else assert(spec.basis==(downmix and 'downmix_discrete' or 'loudest_channel'))end
    assert(L.profile(spec)==L.ZWICKER_PROFILE)
  end
end
local spec=A.resolve(identity.path,4,{},n)
for _,change in ipairs{
  function(m)m.target_sones=16 end,function(m)m.reference_dbfs=-18 end,
  function(m)m.reference_spl_db=83 end,function(m)m.metric='zwicker_p95'end,
}do
  local different=U.copy(spec);change(different.meter)
  assert(A.valid(different)and not A.same(spec,different))
  local key=L.key(identity,'test',different);assert(not keys[key]);keys[key]=true
end
assert(not keys[L.key(identity,'test',spec)])
for _,change in ipairs{
  function(s)s.extra=true end,function(s)s.meter.extra=true end,function(s)s.meter.target_sones=0 end,
  function(s)s.basis='source'end,function(s)s.meter.metric='lufs_m_max'end,function(s)s.source_channels=3.5 end,
  function(s)s.meter=nil end,function(s)s.revision=1 end,
}do local invalid=U.copy(spec);change(invalid);assert(not A.valid(invalid))end
local measurement={identity=U.copy(identity),profile=L.profile(spec),analyzer_key='test',analysis=U.copy(spec),
  status='ready',channels=4,duration=10,max_momentary_lufs=-24,true_peak_dbtp=-12,
  zwicker_sones=2.7,normalization_gain_db=9.25,gain_status='ready'}
assert(L.matches_measurement(measurement,identity,'test',spec))
assert(L.gain(macro,measurement)==9.25,'Zwicker gain must use the solver result, not a LUFS or log-sones shortcut')
macro.normalization.max_boost_db=6
local gain,status=L.gain(macro,measurement);assert(gain==6 and status=='boost capped')
macro.source_peak_guard.enabled=true;measurement.true_peak_dbtp=-2
gain,status=L.gain(macro,measurement);assert(gain==1 and status=='source peak capped')
macro.normalization.target_sones=16;gain,status=L.gain(macro,measurement)
assert(gain==0 and status=='unmeasured','A previous target solution leaked into a changed target')
macro.normalization.target_sones=spec.meter.target_sones
for _,change in ipairs{
  function(v)v.normalization_gain_db=nil end,function(v)v.normalization_gain_db=math.huge end,
  function(v)v.zwicker_sones=-1 end,function(v)v.zwicker_sones=J.null end,function(v)v.gain_status=nil end,
}do local invalid=U.copy(measurement);change(invalid);assert(not L.matches_measurement(invalid,identity,'test',spec))end
measurement.status='silence';measurement.max_momentary_lufs=J.null;measurement.zwicker_sones=J.null
measurement.normalization_gain_db=J.null;measurement.true_peak_dbtp=3
assert(L.matches_measurement(measurement,identity,'test',spec))
gain,status=L.gain(macro,measurement);assert(gain==-4 and status=='source peak capped')

-- Native construction never discovers tools or launches a process. The target,
-- meter and calibration are copied into the job and its atomic file result.
local read,write,remove=U.read,U.write,os.remove
local files,started,cancelled,now={},{},{},0
local ok,err=xpcall(function()
  U.read=function(path)return files[path]end;U.write=function(path,value)files[path]=value;return true end
  os.remove=function(path)files[path]=nil;return true end
  local r={RecursiveCreateDirectory=function()end,time_precise=function()return now end,
    file_exists=function()error('Native analysis must not search for executables')end,
    ExecProcess=function()error('Native analysis must not start a subprocess')end,
    JS_File_Stat=function()return 0,identity.size,0,identity.mtime end,
    AM_AnalysisStart=function(request,path)
      local id=#started+1;started[id]={request=J.decode(request),path=path};return id
    end,AM_AnalysisCancel=function(id)cancelled[id]=true;return true end}
  local cache=L.new(r,'/root','/data',M.defaults().settings,'zwicker')
  assert(cache.analyzer_key==L.ANALYZER_KEY and not cache.python and not cache.ffmpeg)
  cache:request(identity,false,spec)
  local first=cache.active;assert(first.native_job_id==1 and first.analysis~=spec and first.analysis.meter~=spec.meter)
  assert(A.same(started[1].request.analysis,spec)and started[1].request.profile==L.ZWICKER_PROFILE)
  assert(started[1].path==first.result and not started[1].request.ffmpeg)
  local target=U.copy(spec);target.meter.target_sones=16
  cache:request(identity,false,target);assert(cancelled[1]and first.cancelled and A.same(cache.queued_analysis,target))
  files[first.result]=J.encode{job_id=first.job_id,status='cancelled'};now=1;cache:poll()
  local active=cache.active;assert(active.native_job_id==2 and A.same(active.analysis,target))
  local result={status='ready',job_id=active.job_id,identity=U.copy(identity),profile=L.ZWICKER_PROFILE,
    analyzer_key=L.ANALYZER_KEY,analysis=U.copy(target),channels=4,duration=10,max_momentary_lufs=-24,
    true_peak_dbtp=-12,zwicker_sones=2.7,normalization_gain_db=12.4,gain_status='ready'}
  -- An independently completed result must work during modal D&D before poll.
  files[active.result]=J.encode(result)
  local found=L.completed_result(active,identity,L.ANALYZER_KEY,target)
  assert(found and found.normalization_gain_db==12.4 and cache.active==active)
  assert(not L.completed_result(active,identity,L.ANALYZER_KEY,spec))
  now=2;cache:poll();assert(not cache.active and cache:get(identity,target)and not cache:get(identity,spec))
  local before=#started;cache:request(identity,false,target);assert(#started==before)
  cache:request(identity,true,target);cache:close();assert(cancelled[cache.active.native_job_id])
end,debug.traceback)
U.read,U.write,os.remove=read,write,remove;assert(ok,err)

-- Export's optional second normalization must never interpret a sones target
-- as a REAPER LUFS target; the rejection precedes filesystem/project changes.
macro.export.normalize_final=true
local succeeded,error=pcall(E.render,{}, {macro=macro},'/exports','test',false)
assert(not succeeded and tostring(error):find('Final export normalization supports LUFS only',1,true))
