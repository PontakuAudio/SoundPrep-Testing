-- A 1-second native file must not truncate a 2-second slowed CF audition.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local U=require('am.util')
local data=r.GetResourcePath()..'/native-duration';r.RecursiveCreateDirectory(data,0)
local log=assert(io.open(data..'/duration.txt','w'));log:setvbuf('no')
local app,done,started,handle;local frames=0;local before=false
local function finish(ok,e)
  if done then return end;done=true;if app then app:close()end
  log:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');log:close()
end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data);local b=Model.defaults();b.settings.autoplay=false;b.settings.loop=false
  b.macros[1].source_transform.rate=.5;assert(Model.save(data..'/bank.json',b))
  app=App.new(r,root,data);app:activate('heavy');r.OpenMediaExplorer('/tmp/audition-macro-dev/test.wav',false)
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frames=frames+1;app:tick()
    if frames==15 then
      -- A real native command, without companion suppression.
      r.JS_WindowMessage_Send(app.explorer:window(),'WM_COMMAND',1008,0,0,0)
      started=r.time_precise()
    elseif started then
      local elapsed=r.time_precise()-started
      if elapsed<1.7 then
        assert(app.preview:playing(),'Native transport ended the slower audition')
        if handle then assert(handle==app.preview.handle)else handle=app.preview.handle end
      end
      if elapsed>1.15 and not before then
        local _,position=app.preview:playing();assert(position>1 and position<1.7)
        before=true;log:write(('continued beyond native EOF: %.3f sec\n'):format(position))
      end
      if elapsed>1.7 then
        app:native_transport(1009);assert(not app.preview:playing(),'Explicit Stop failed');finish(true)
      end
    end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
