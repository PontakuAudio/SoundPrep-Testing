-- Main-thread cost only; this is not an audio latency or CPU benchmark.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local host=reaper;assert(host.file_exists(host.GetResourcePath()..'/.audition-macro-test'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local U=require('am.util');local J=require('am.json')
local counts={};local r=setmetatable({}, {__index=host})
for _,name in ipairs{'JS_Window_Find','JS_Window_FindChildByID','JS_File_Stat','file_exists','SetExtState','SetMediaTrackInfo_Value','AM_BarSetState','AM_DropAttach','AM_DropAttachSources','JS_Window_GetTitle','GetToggleCommandStateEx'}do
  r[name]=function(...)counts[name]=(counts[name]or 0)+1;return host[name](...)end
end
local read,encode=U.read,J.encode
U.read=function(...)counts.read=(counts.read or 0)+1;return read(...)end
J.encode=function(...)counts.encode=(counts.encode or 0)+1;return encode(...)end
local data=host.GetResourcePath()..'/performance-test';host.RecursiveCreateDirectory(data,0)
local file=assert(io.open(data..'/'..(AM_PERFORMANCE_NAME or 'performance')..'.json','w'))
local app;local frame=0;local done=false;local times={}
local function finish(ok,err)
  if done then return end;done=true
  times=U.copy(times) -- Cleanup is outside the measured interval.
  if app then app:close()end
  file:write(encode({status=ok and 'PASS' or 'FAIL',error=err,results=times}));file:close()
end
local ok,err=xpcall(function()
  host.SetMediaTrackInfo_Value(host.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data)
  local b=Model.defaults();b.settings.autoplay=false
  for i=4,9 do local m=Model.macro('bench'..i,'Bench '..i);m.fx_chain=b.macros[1].fx_chain;b.macros[#b.macros+1]=m end
  for _,m in ipairs(b.macros)do m.normalization.enabled=false end
  assert(Model.save(data..'/bank.json',b));app=App.new(r,root,data)
  app.bar=require('am.bar').new(r,app)
  host.OpenMediaExplorer('/tmp/audition-macro-dev/long.wav',false)
end,debug.traceback)
if not ok then finish(false,err);return end
local samples={}
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1
    if frame==20 then counts={} end
    local start=host.time_precise();app:tick();app.bar:tick()
    if frame>=20 then samples[#samples+1]=(host.time_precise()-start)*1e6 end
    if frame==139 then
      table.sort(samples);local sum=0;for _,s in ipairs(samples)do sum=sum+s end
      times.idle={frames=#samples,mean_us=sum/#samples,p50_us=samples[60],p95_us=samples[114],calls=counts}
      counts={};local start=host.time_precise()
      for i=1,1000 do app.bank:activate(app.definition.macros[(i%9)+1].id,0)end
      times.switch={iterations=1000,mean_us=(host.time_precise()-start)*1e3,calls=counts}
      finish(true)
    end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then host.defer(tick)end
end
tick()
