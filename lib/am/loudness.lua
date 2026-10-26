local U=require('am.util');local J=require('am.json');local Policy=require('am.analysis_policy')
local M={};M.__index=M
M.PROFILE='native-lufs-maxm-v1'
M.MULTICHANNEL_PROFILE='native-lufs-maxm-multichannel-v1'
M.ZWICKER_PROFILE='native-zwicker-timevarying-v1'
M.ANALYZER_KEY='native-analysis-v1'
function M.profile(analysis)
  assert(analysis==nil or Policy.valid(analysis),'Invalid source analysis policy')
  return analysis and (analysis.meter~=nil and M.ZWICKER_PROFILE or analysis.source_channels>2 and M.MULTICHANNEL_PROFILE or M.PROFILE)or M.PROFILE
end
function M.identity(r,path)
  local result,size,_,modified=r.JS_File_Stat(path)
  if result~=0 then return nil,'Cannot stat selected file' end
  if type(modified)=='string' then
    local y,mo,d,h,mi,s=modified:match('^(%d+)%.(%d+)%.(%d+) (%d+):(%d+):(%d+)$')
    if not y then return nil,'Unsupported JS_File_Stat timestamp format' end
    modified=os.time{year=tonumber(y),month=tonumber(mo),day=tonumber(d),hour=tonumber(h),min=tonumber(mi),sec=tonumber(s)}
  end
  return {path=path,size=size,mtime=math.floor(modified)}
end
function M.same(a,b)
  return type(a)=='table' and type(b)=='table' and type(a.path)=='string' and type(b.path)=='string' and
    U.path_equal(a.path,b.path) and a.size==b.size and a.mtime==b.mtime
end
function M.key(identity,analyzer,analysis)
  local profile=M.profile(analysis)
  return U.hash(J.encode(identity)..analyzer..profile..(analysis and J.encode(analysis)or ''))
end
local function optional_finite(value)return value==nil or value==J.null or U.finite(value)end
function M.valid_measurement(value,analysis)
  if type(value)~='table' then return false end
  if value.status~='ready' and value.status~='silence' then return false end
  if value.status=='ready' and (not U.finite(value.max_momentary_lufs) or not U.finite(value.true_peak_dbtp)) then return false end
  if value.status=='silence' and (not optional_finite(value.max_momentary_lufs) or not optional_finite(value.true_peak_dbtp))then return false end
  if not U.finite(value.duration) or value.duration<0 or not Policy.same(value.analysis,analysis)then return false end
  if analysis and analysis.meter~=nil then
    if value.status=='ready' and (not U.finite(value.zwicker_sones)or value.zwicker_sones<0 or
      not U.finite(value.normalization_gain_db)or type(value.gain_status)~='string' or value.gain_status=='')then return false end
    if value.status=='silence' and (not optional_finite(value.zwicker_sones)or not optional_finite(value.normalization_gain_db))then return false end
  end
  return analysis and value.channels==analysis.source_channels or not analysis and (value.channels==1 or value.channels==2)
end
function M.matches_measurement(value,identity,analyzer,analysis)
  return type(analyzer)=='string' and M.valid_measurement(value,analysis) and M.same(value.identity,identity) and
    value.profile==M.profile(analysis) and value.analyzer_key==analyzer
end
function M.without_meter(value)
  assert(M.matches_measurement(value,value.identity,value.analyzer_key,value.analysis),'Invalid analysis response')
  if not(value.analysis and value.analysis.meter)then return value end
  local base=U.copy(value);base.analysis=Policy.without_meter(value.analysis);base.profile=M.profile(base.analysis)
  base.zwicker_sones=nil;base.normalization_gain_db=nil;base.gain_status=nil;base.zwicker_tail_seconds=nil
  -- Zwicker uses an auditory silence criterion; restore the native LUFS one.
  base.status=U.finite(base.true_peak_dbtp)and U.finite(base.max_momentary_lufs)and base.max_momentary_lufs>=-100 and 'ready'or 'silence'
  return base
end
local function supplies_base(available,wanted)
  return available and Policy.valid(available)and available.meter~=nil and Policy.same(Policy.without_meter(available),wanted)
end
function M.for_analysis(value,identity,analyzer,analysis)
  if M.matches_measurement(value,identity,analyzer,analysis)then return value end
  if type(value)=='table' and supplies_base(value.analysis,analysis)and
    M.matches_measurement(value,identity,analyzer,value.analysis)then return M.without_meter(value)end
end
-- Native modal drags suspend companion polling. Inspect a completed worker
-- response without claiming the job, deleting files or changing the cache.
-- The caller supplies the source identity it has just read from disk.
-- Returns measurement, status, error; status is ready/silence, pending,
-- unmeasured (no matching job), cancelled, or error.
function M.completed_result(job,identity,analyzer,analysis)
  if type(job)~='table' or not M.same(job.identity,identity) or
    not(Policy.same(job.analysis,analysis)or supplies_base(job.analysis,analysis))then return nil,'unmeasured' end
  if job.cancelled or type(job.cancel)=='string' and U.read(job.cancel)then return nil,'cancelled' end
  if type(job.result)~='string' or type(job.job_id)~='string'then return nil,'error','Invalid analysis job' end
  local text=U.read(job.result);if not text then return nil,'pending' end
  local ok,result=pcall(J.decode,text)
  if not ok or type(result)~='table' or result==J.null or result.job_id~=job.job_id then
    return nil,'error','Invalid analysis response'
  end
  if result.status=='cancelled'then return nil,'cancelled' end
  if result.status=='error'then
    return nil,'error',type(result.error)=='string' and result.error~='' and result.error or 'Analysis failed'
  end
  if not M.matches_measurement(result,identity,analyzer,job.analysis)then
    return nil,'error','Analysis response does not match this source and analysis profile'
  end
  if not Policy.same(job.analysis,analysis)then result=M.without_meter(result)end
  return result,result.status
end
function M.gain(macro,measurement)
  local n=macro.normalization;local guard=macro.source_peak_guard
  if not n.enabled and not guard.enabled then return 0,'off' end
  if not measurement or measurement.status~='ready' and measurement.status~='silence' then return 0,measurement and measurement.status or 'unmeasured' end
  local silent=measurement.status=='silence'
  if not silent and (not U.finite(measurement.max_momentary_lufs) or not U.finite(measurement.true_peak_dbtp))then return 0,'invalid' end
  local meter=Policy.meter(n)
  if meter and (not measurement.analysis or not Policy.valid(measurement.analysis)or not U.equal(meter,measurement.analysis.meter))then return 0,'unmeasured' end
  if n.enabled and not meter and measurement.analysis and measurement.analysis.meter~=nil then return 0,'unmeasured' end
  if meter and not silent and not U.finite(measurement.normalization_gain_db)then return 0,'invalid' end
  local requested=not silent and n.enabled and (meter and measurement.normalization_gain_db or n.target_lufs-measurement.max_momentary_lufs)or 0
  local gain=math.min(requested,n.max_boost_db)
  local reason=gain<requested and 'boost capped' or silent and 'silence' or meter and n.enabled and measurement.gain_status or 'ready'
  -- Normalization always honors the source ceiling, including older banks
  -- with guard=false. A loudness target/max boost alone cannot bound peaks on
  -- transient material; Monitor gain is downstream of the preview input.
  -- The optional guard also applies this cap with normalization switched off.
  if U.finite(measurement.true_peak_dbtp)then
    local cap=guard.ceiling_dbtp-measurement.true_peak_dbtp
    if cap<gain then gain=cap;reason='source peak capped' end
  end
  return math.max(-120,gain),reason
end
function M.cache_directory(data,settings)
  local directory=settings and settings.cache_directory
  return directory and directory~='' and directory or data..'/cache'
end
function M.job_directory(data,settings,session)
  local directory=settings and settings.cache_directory
  return (directory and directory~='' and directory or data)..'/jobs/'..session
end
function M.new(r,root,data,settings,session)
  local self=setmetatable({r=r,root=root,data=data,settings=settings,session=session,counter=0,memory={},keys=setmetatable({},{__mode='k'})},M)
  self.analyzer_key=M.ANALYZER_KEY
  self.jobdir=M.job_directory(data,settings,session)
  r.RecursiveCreateDirectory(M.cache_directory(data,settings),0);r.RecursiveCreateDirectory(self.jobdir,0)
  return self
end
function M:remember(value,analysis,persist)
  local key=M.key(value.identity,self.analyzer_key,analysis)
  self.memory[key]=value
  if persist then U.write(M.cache_directory(self.data,self.settings)..'/'..key..'.json',J.encode(value))end
  if analysis and analysis.meter then
    local base=M.without_meter(value)
    self:remember(base,base.analysis,persist)
  end
end
function M:get(identity,analysis,fallback)
  M.profile(analysis)
  local tag=analysis and J.encode(analysis)or ''
  local keys=self.keys[identity]
  if type(keys)~='table'then keys={};self.keys[identity]=keys end
  local key=keys[tag]
  if not key then key=M.key(identity,self.analyzer_key,analysis);keys[tag]=key end
  local value=self.memory[key]
  if M.matches_measurement(value,identity,self.analyzer_key,analysis)then return value end
  if value~=false then
    local text=U.read(M.cache_directory(self.data,self.settings)..'/'..key..'.json')
    if text then local ok,v=pcall(J.decode,text);if ok then value=v end end
    if M.matches_measurement(value,identity,self.analyzer_key,analysis)then
      self:remember(value,analysis,false);return value
    end
  end
  -- Migrate an existing full result lazily, including during modal drops.
  -- No directory scan, write or worker is needed to reuse its source meters.
  if supplies_base(fallback,analysis)then
    local full=self:get(identity,fallback)
    if full then local base=M.without_meter(full);self.memory[key]=base;return base end
  end
  -- A miss is cached too. Completion/force-analysis explicitly invalidates it.
  self.memory[key]=false
end
function M:request(identity,force,analysis,fallback)
  M.profile(analysis)
  self.wanted=U.copy(identity);self.wanted_analysis=U.copy(analysis)
  if force then
    local k=M.key(identity,self.analyzer_key,analysis);self.memory[k]=nil;os.remove(M.cache_directory(self.data,self.settings)..'/'..k..'.json')
    if supplies_base(fallback,analysis)then
      k=M.key(identity,self.analyzer_key,fallback);self.memory[k]=nil;os.remove(M.cache_directory(self.data,self.settings)..'/'..k..'.json')
    end
  end
  local found=not force and self:get(identity,analysis,fallback)
  if found then
    self.queued=nil;self.queued_analysis=nil;self.error=nil
    if self.active and (not M.same(self.active.identity,identity)or not Policy.same(self.active.analysis,analysis))then self:cancel_active()end
    return found
  end
  if type(self.r.AM_AnalysisStart)~='function' or type(self.r.AM_AnalysisCancel)~='function'then
    self.error='Native analysis requires the updated helper. Update it with REAPER closed, then restart.';return nil
  end
  if self.active then
    if not M.same(self.active.identity,identity) or not Policy.same(self.active.analysis,analysis) or force then self:cancel_active()end
    -- Cancellation is irreversible for this worker. A -> B -> A must restart A,
    -- not keep B queued or assume the cancelled A will still produce a result.
    self.queued=self.active.cancelled and U.copy(identity) or nil
    self.queued_analysis=self.active.cancelled and U.copy(analysis) or nil
    return nil
  end
  self.counter=self.counter+1;local job=self.jobdir..'/'..self.counter
  local request={job_id=self.session..':'..self.counter,identity=identity,profile=M.profile(analysis),
    timeout=self.settings.analysis_timeout_seconds,analyzer_key=self.analyzer_key,analysis=U.copy(analysis)}
  assert(U.write(job..'.request.json',J.encode(request)))
  local ok,launched=pcall(self.r.AM_AnalysisStart,J.encode(request),job..'.result.json')
  if not ok or not U.finite(launched)or launched<=0 or launched%1~=0 then
    os.remove(job..'.request.json');self.error='Could not start native analysis';return nil
  end
  self.active={identity=U.copy(identity),analysis=U.copy(analysis),result=job..'.result.json',cancel=job..'.cancel',request=job..'.request.json',
    started=self.r.time_precise(),job_id=request.job_id,native_job_id=launched}
  self.error=nil
end
function M:cancel_active()
  if self.active and not self.active.cancelled then
    assert(U.write(self.active.cancel,'cancel'));self.active.cancelled=true
    if self.active.native_job_id and self.r.AM_AnalysisCancel then self.r.AM_AnalysisCancel(self.active.native_job_id)end
  end
end
local function restart_queued(self)
  if not self.queued then return end
  local identity,analysis=self.queued,self.queued_analysis
  self.queued=nil;self.queued_analysis=nil
  self:request(identity,false,analysis)
end
function M:poll()
  local job=self.active;if not job then return end
  local now=self.r.time_precise()
  if job.last_poll and now-job.last_poll<.05 then return end
  job.last_poll=now
  local text=U.read(job.result)
  if not text then
    if now-job.started>self.settings.analysis_timeout_seconds+20 then
      self:cancel_active();self.error='Native analysis did not respond';self.active=nil
      restart_queued(self)
    end
    return
  end
  local ok,result=pcall(J.decode,text)
  ok=ok and type(result)=='table' and result~=J.null and result.job_id==job.job_id
  if job.cancelled then
    -- A worker may finish just before seeing its cancel file. Do not let that
    -- result satisfy a queued force-refresh or surface an obsolete error.
  elseif ok and (result.status=='ready' or result.status=='silence') then
    local now=M.identity(self.r,job.identity.path)
    if not M.matches_measurement(result,job.identity,self.analyzer_key,job.analysis)then self.error='Invalid analysis response'
    elseif M.same(now,job.identity)then
      self:remember(result,job.analysis,true)
    end
  elseif ok and result.status=='error' then self.error=result.error
  elseif not ok or result.status~='cancelled' then self.error='Invalid analysis response' end
  os.remove(job.result);os.remove(job.request);os.remove(job.cancel)
  self.active=nil
  restart_queued(self)
end
function M:close()self:cancel_active();self.queued=nil;self.queued_analysis=nil end
return M
