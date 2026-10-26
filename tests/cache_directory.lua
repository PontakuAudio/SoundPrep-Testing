local App=require('am.app');local L=require('am.loudness');local Model=require('am.model')
local U=require('am.util');local J=require('am.json')
local read,write,remove=U.read,U.write,os.remove
local files,blocked,created={},nil,{}
U.read=function(path)return files[path]end
U.write=function(path,text)
  if blocked and path:find(blocked,1,true)then return nil,'Permission denied'end
  files[path]=text;return true
end
os.remove=function(path)files[path]=nil;return true end
local ok,err=xpcall(function()
  local bank=Model.defaults();bank.settings.cache_directory=nil
  assert(Model.validate(bank).settings.cache_directory=='','Old banks must keep the original cache location')
  for _,path in ipairs{'relative/path','C:relative','~/cache','/bad\npath','/bad\0path',false,12}do
    local b=Model.defaults();b.settings.cache_directory=path
    assert(not pcall(Model.validate,b),'Invalid cache path accepted: '..tostring(path))
  end
  for _,path in ipairs{'/Volumes/Cache 音声','C:\\SoundPrep cache','\\\\server\\share\\cache','/','C:\\'}do
    local b=Model.defaults();b.settings.cache_directory=path
    assert(Model.validate(J.decode(J.encode(b))).settings.cache_directory==path)
  end

  local launches,guid,now=0,0,0
  local a={path='/sound.wav',size=10,mtime=1};local b={path='/other.wav',size=20,mtime=2}
  local r={RecursiveCreateDirectory=function(path)created[path]=true;return 1 end,
    genGuid=function()guid=guid+1;return 'cache-test-'..guid end,time_precise=function()return now end,
    JS_File_Stat=function(path)local id=path==a.path and a or b;return 0,id.size,0,id.mtime end,
    AM_AnalysisStart=function()launches=launches+1;return launches end,AM_AnalysisCancel=function()return true end}
  local l=L.new(r,'/app','/data',bank.settings,'session')
  local app=setmetatable({r=r,data='/data',definition=bank,loudness=l,session='session'},App)
  assert(created['/data/cache']and created['/data/jobs/session'])
  assert(l.jobdir=='/data/jobs/session')
  local function cachepath(root,id)return root..'/'..L.key(id,l.analyzer_key)..'.json'end
  local function result(id,job)
    return {status='ready',identity=id,profile=L.PROFILE,analyzer_key=l.analyzer_key,job_id=job and job.job_id,
      channels=1,duration=1,max_momentary_lufs=-18,true_peak_dbtp=-3}
  end
  local old=cachepath('/data/cache',b);files[old]=J.encode(result(b))
  l:request(a);local active=l.active;local active_before=J.encode(active)
  l.memory[L.key(b,l.analyzer_key)]=false
  local destination='/Volumes/Cache 音声'
  files[cachepath(destination,b)]=J.encode(result(b))

  -- Failed probes and a failed bank save cannot redirect the running worker
  -- or change either the in-memory setting or the last persisted setting.
  assert(Model.save('/data/bank.json',bank));local saved=files['/data/bank.json']
  for _,failure in ipairs{'/unwritable','/new/jobs/','/data/bank.json'}do
    blocked=failure
    local changed=pcall(app.set_cache_directory,app,failure=='/unwritable' and failure or '/new')
    assert(not changed and bank.settings.cache_directory=='' and l.jobdir=='/data/jobs/session')
    assert(files['/data/bank.json']==saved and J.encode(l.active)==active_before)
  end
  blocked=nil
  r.JS_Dialog_BrowseForFolder=function(_,initial)assert(initial=='/data/cache');return 0,''end
  assert(not app:choose_cache_directory()and files['/data/bank.json']==saved)
  r.JS_Dialog_BrowseForFolder=function(_,initial)assert(initial=='/data/cache');return 1,destination end
  assert(app:choose_cache_directory())
  assert(bank.settings.cache_directory==destination and l.jobdir==destination..'/jobs/session')
  assert(created[destination]and created[l.jobdir])
  assert(Model.load('/data/bank.json').settings.cache_directory==destination)
  assert(J.encode(l.active)==active_before and l:get(b),'Switch lost live work or retained a stale miss')
  assert(files[old],'Changing folders deleted the previous cache')
  for path in pairs(files)do assert(not path:find('.soundprep-write-',1,true),'Write probe leaked')end

  -- The old job finishes using its captured result path, then persists in the
  -- chosen cache. Future launches (and forced refresh) use the new location.
  files[active.result]=J.encode(result(a,active));now=1;l:poll()
  assert(not l.active and not files[active.result]and not files[active.request])
  assert(files[cachepath(destination,a)]and not files[cachepath('/data/cache',a)])
  local measured=l:get(a);assert(measured)
  local restarted=L.new(r,'/app','/data',Model.load('/data/bank.json').settings,'restart')
  assert(restarted:get(a)and restarted.jobdir==destination..'/jobs/restart')
  l:request(a,true)
  assert(l.active.result==destination..'/jobs/session/2.result.json'and not files[cachepath(destination,a)])
  local second=l.active;files[second.result]=J.encode(result(a,second));now=2;l:poll()
  measured=l:get(a)
  assert(app:set_cache_directory('')and l:get(a)==measured,'Reset interrupted the current measurement')
  assert(l.jobdir=='/data/jobs/session'and Model.load('/data/bank.json').settings.cache_directory=='')
  assert(files[cachepath(destination,a)]and files[old],'Reset removed cached results')
  assert(not app:set_cache_directory(''))
  l:request(a,true);assert(l.active.result=='/data/jobs/session/3.result.json')
  assert(files[cachepath(destination,a)],'Refresh deleted a cache in a different folder')
end,debug.traceback)
U.read,U.write,os.remove=read,write,remove
assert(ok,err)
