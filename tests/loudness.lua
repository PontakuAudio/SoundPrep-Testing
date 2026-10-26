local U=require('am.util');local L=require('am.loudness');local J=require('am.json');local A=require('am.analysis_policy')
local read,write,remove=U.read,U.write,os.remove
local files,reads,launches,now={},0,0,0
U.read=function(path)reads=reads+1;return files[path]end
U.write=function(path,text)files[path]=text;return true end
os.remove=function(path)files[path]=nil;return true end
local ok,err=xpcall(function()
  local started,cancelled={},{}
  local r={GetOS=function()return 'Win64'end,time_precise=function()return now end,
    ExecProcess=function()error('Analysis must not launch a subprocess')end,
    AM_AnalysisStart=function(request,path)
      launches=launches+1;started[launches]={request=J.decode(request),path=path};return launches
    end,
    AM_AnalysisCancel=function(id)assert(started[id]);cancelled[id]=true;return true end}
  local function cache()
    return setmetatable({r=r,root='C:/macro',data='C:/data',jobdir='C:/jobs',session='test',counter=0,
      settings={analysis_timeout_seconds=10},memory={},keys={},analyzer_key='test'},L)
  end
  local a={path='C:/a.wav',size=1,mtime=1};local b={path='C:/b.wav',size=2,mtime=1}
  r.JS_File_Stat=function(path)local id=path==a.path and a or b;return 0,id.size,0,id.mtime end
  local c=cache();c:request(a);c:request(b);c:request(a)
  assert(cancelled[1]and started[1].request.profile==L.PROFILE and started[1].path==c.active.result)
  assert(not started[1].request.ffmpeg and c.active.native_job_id==1)
  assert(L.same(c.queued,a),'Returning to a cancelled file must replace the stale queued selection')
  files[c.active.result]=J.encode{status='cancelled',job_id=c.active.job_id}
  c:poll();assert(L.same(c.active.identity,a) and launches==2)
  c:request(a);assert(not c.queued,'An uncancelled current job needs no duplicate')
  c:request(a,true);c:request(a)
  assert(L.same(c.queued,a),'A forced refresh must survive a repeated request')
  files[c.active.result]=J.encode{status='ready',job_id=c.active.job_id,identity=a,profile=L.PROFILE,
    analyzer_key='test',duration=1,channels=1,max_momentary_lufs=-16,true_peak_dbtp=-3}
  c:poll();assert(c.active and launches==3 and not c:get(a),'A cancelled completion must not satisfy a force-refresh')
  c=cache();files={};c:request(a);reads=0
  for i=1,100 do now=now+.001;c:poll()end
  assert(reads<=3,'Result-file polling must not perform disk IO on every defer frame')
  now=now+1;files[c.active.result]='42';c:poll()
  assert(not c.active and c.error=='Invalid analysis response','Malformed responses must not terminate the companion')

  local original=A.resolve(a.path,4,{})
  local stereo=A.resolve(a.path,4,{preview_downmix=true})
  local ambix=A.resolve('field_ambix.wav',4,{preview_downmix=true})
  local function result(job,spec)
    return {status='ready',job_id=job.job_id,identity=U.copy(a),profile=L.profile(spec),analysis=U.copy(spec),
      analyzer_key='test',duration=1,channels=spec and spec.source_channels or 1,max_momentary_lufs=-16,true_peak_dbtp=-3}
  end

  -- A mode change on the same file owns a distinct worker and cache entry.
  -- A -> B -> A must replace the queued descriptor after cancellation.
  c=cache();files={};c:request(a,false,original)
  local first=c.active;local request=J.decode(files[first.request])
  assert(A.same(request.analysis,original)and A.same(first.analysis,original)and A.same(c.wanted_analysis,original))
  assert(first.analysis~=original and c.wanted_analysis~=original,'Mutable caller descriptors escaped into active state')
  c:request(a,false,stereo);assert(first.cancelled and A.same(c.queued_analysis,stereo))
  c:request(a,false,original);assert(A.same(c.queued_analysis,original)and A.same(c.wanted_analysis,original))
  files[first.result]=J.encode(result(first,original));now=now+1;c:poll()
  assert(c.active and c.active.job_id~=first.job_id and A.same(c.active.analysis,original))
  assert(not c:get(a,original),'A cancelled completion became a measurement')
  local current=c.active;files[current.result]=J.encode(result(current,original));now=now+1;c:poll()
  assert(not c.active and c:get(a,original)and not c:get(a,stereo))
  local original_key=L.key(a,'test',original);local stereo_key=L.key(a,'test',stereo)
  assert(files['C:/data/cache/'..original_key..'.json']and not files['C:/data/cache/'..stereo_key..'.json'])

  -- A valid completion for a different policy must never silently populate
  -- the current source's cache, even if identity and worker id match.
  c:request(a,false,stereo);current=c.active
  files[current.result]=J.encode(result(current,ambix));now=now+1;c:poll()
  assert(not c.active and c.error=='Invalid analysis response'and not c:get(a,stereo)and not c:get(a,ambix))

  -- Completed-result pickup observes the same descriptor boundary without
  -- claiming the companion job or deleting its result.
  c:request(a,false,stereo);current=c.active;files[current.result]=J.encode(result(current,stereo))
  local value,status=L.completed_result(current,a,'test',stereo)
  assert(value and status=='ready'and c.active==current and files[current.result])
  value,status=L.completed_result(current,a,'test',original);assert(not value and status=='unmeasured')
  value,status=L.completed_result(current,a,'test');assert(not value and status=='unmeasured')
  local wrong=result(current,original);files[current.result]=J.encode(wrong)
  value,status=L.completed_result(current,a,'test',stereo);assert(not value and status=='error')
  files[current.result]=J.encode(result(current,stereo));now=now+1;c:poll()
  assert(c:get(a,stereo))

  -- Force refreshing one policy removes only that policy's persisted cache.
  c:request(a,true,original)
  assert(not files['C:/data/cache/'..original_key..'.json']and files['C:/data/cache/'..stereo_key..'.json'])
  current=c.active;c:request(a,false,stereo)
  assert(current.cancelled and not c.queued and c.queued_analysis==nil and A.same(c.wanted_analysis,stereo))
  files[current.result]=J.encode(result(current,original));now=now+1;c:poll()
  assert(not c.active and not c:get(a,original)and c:get(a,stereo),'A cancelled job replaced a cached mode switch')

  -- Cached misses and descriptor mutations cannot alias another mode.
  c=cache();files={}
  local mutable=U.copy(original);c:request(a,false,mutable);mutable.basis='downmix_discrete'
  assert(A.same(c.active.analysis,original)and A.same(c.wanted_analysis,original))
  c:request(a,false,mutable);assert(A.same(c.queued_analysis,stereo))
  mutable.basis='downmix_ambix';assert(A.same(c.queued_analysis,stereo),'Queued analysis was not frozen')
  now=now+40;c:poll()
  assert(c.active and A.same(c.active.analysis,stereo)and A.same(c.wanted_analysis,stereo),'Timeout lost the queued mode')
  c:close();assert(c.active.cancelled and not c.queued and not c.queued_analysis)

  -- A stale mono/stereo cache at a multichannel key cannot be accepted.
  c=cache();files={};local legacy=result({job_id='legacy'},nil)
  files['C:/data/cache/'..stereo_key..'.json']=J.encode(legacy)
  assert(not c:get(a,stereo))
  local measurement=result({job_id='multi'},stereo)
  files['C:/data/cache/'..stereo_key..'.json']=J.encode(measurement)
  assert(not c:get(a,stereo),'A miss should remain cached until completion or refresh')
  c.memory[stereo_key]=nil;assert(c:get(a,stereo))

  c=cache();r.AM_AnalysisStart=function()return 0 end;c:request(a)
  assert(not c.active and c.error,'A launch failure must be reported immediately')
end,debug.traceback)
U.read,U.write,os.remove=read,write,remove
assert(ok,err)
