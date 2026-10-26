-- Owned, persistent render host. A superseded render completes in this process;
-- only the latest recipe can be published by the parent. No per-file launches.
local config_path=assert(_G.AM_PREPARE_CONFIG)
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]worker[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local Insert=require('am.insert')
local config=J.decode(assert(U.read(config_path)));local dir=config.directory;local r=reaper
assert(U.path_equal(r.GetResourcePath(),dir..'/host'),'Worker resource mismatch')
assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-worker'),'Worker ownership marker missing')
r.JS_Window_Show(r.GetMainHwnd(),'HIDE')
assert(U.write(r.GetResourcePath()..'/.audition-macro-worker-ready','ready'))
assert(U.write(dir..'/worker-ready','ready'))
local last_job,last_poll=nil,0
local function tick()
  local now=r.time_precise()
  if now-last_poll>=.1 then
    last_poll=now
    local text=U.read(dir..'/job.json');local valid,job=pcall(J.decode,text or '')
    if valid and job.job_id~=last_job then
      last_job=job.job_id
      assert(job.output:sub(1,#dir+1)==dir..'/' and not job.output:find('/../',1,true),'Invalid staging directory')
      assert(U.write(dir..'/running.json',J.encode{job_id=job.job_id}))
      local ok,plan=xpcall(function()
        if job.entries then
          for _,entry in ipairs(job.entries)do Insert.prepare(r,entry.snapshot,entry.length,entry.handles,job.output)end
          return true
        end
        return Insert.prepare(r,job.snapshot,job.length,job.handles,job.output)
      end,debug.traceback)
      assert(U.write(job.result,J.encode{job_id=job.job_id,status=ok and 'ready' or 'error',
        error=not ok and tostring(plan) or nil}))
      os.remove(dir..'/running.json')
    end
  end
  r.defer(tick)
end
tick()
