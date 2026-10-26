-- Run only in the owned, silent integration-test host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local U=require('am.util');local Model=require('am.model')
local data=r.GetResourcePath()..'/switching-test';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/switching.txt','w'));f:setvbuf('no')
local app;local frame=0;local done=false
local function finish(ok,err)
  if done then return end;done=true
  if app then app:close()end
  f:write(ok and 'PASS\n' or 'FAIL '..tostring(err)..'\n');f:close()
end
local function check_switch(fn,reuse)
  local old=app.preview.handle;local source=assert(app.preview:source_position())
  fn()
  assert(app.preview:playing(),'Playback stopped')
  local now=app.preview:source_position()
  assert(math.abs(now-source)<.12,('Source jumped: %.6f -> %.6f'):format(source,now))
  if reuse then assert(app.preview.handle==old,'Preview instance was recreated')end
  f:write(('source %.6f -> %.6f; handle %s\n'):format(source,now,reuse and 'reused' or 'new section'))
end
local ok,err=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data)
  local b=assert(Model.load(data..'/bank.json'));b.settings.autoplay=false;b.settings.loop=true
  for _,m in ipairs(b.macros)do m.normalization.enabled=false end
  Model.save(data..'/bank.json',b)
  app=App.new(r,root,data)
  r.OpenMediaExplorer('/tmp/audition-macro-dev/long.wav',false)
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick()
    if frame==20 then
      app:activate(nil);app:play();app.preview:seek_source(6)
    elseif frame==25 then
      local loads=app.bank.loads;local starts=app.preview.starts
      check_switch(function()app:activate('heavy')end,true)
      check_switch(function()app:activate('dark')end,true)
      check_switch(function()app:ab()end,true)
      check_switch(function()app:ab()end,true)
      assert(app.preview.starts==starts,'Pitch/Rate/AB restarted playback')
      check_switch(function()app:reverse()end,false)
      check_switch(function()app:reverse()end,false)
      local edit=U.copy(Model.find(app.definition,app.selected_id));edit.output_gain_db=-3;edit.source_transform.pitch_semitones=3
      check_switch(function()app:apply_edit(edit)end,true)
      app:native_transport(1010);local source=app.paused_source
      assert(not app.preview:playing() and source)
      app:activate('reverse');app:native_transport(1010)
      assert(math.abs(app.preview:source_position()-source)<.12,'Paused bookmark lost on Macro switch')
      assert(app.bank.loads==loads,'FX instances reloaded')
      f:write('pause/resume bookmark, live edit, FX lifetime OK\n');finish(true)
    elseif frame>200 then error('Test timed out')end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
