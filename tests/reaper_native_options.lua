-- Native Tempo match, Start on bar, seek actions and EOF list advancement.
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model')
local data=r.GetResourcePath()..'/native-options';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/options.txt','w'));f:setvbuf('no')
local app,done,handle,before,advance_start,expected;local frame=0
local saved={};for _,id in ipairs{1012,42171,42004,40019,40020,40021,40022}do saved[id]=r.GetToggleCommandStateEx(32063,id)end
local function finish(ok,e)
  if done then return end;done=true;r.OnStopButton()
  if app then
    for _,id in ipairs{1012,42171,42004}do if saved[id]>=0 then app.explorer:toggle(id,saved[id]==1)end end
    for _,id in ipairs{40019,40020,40021,40022}do if saved[id]==1 then app.explorer:command(id)end end
    app:close()
  end
  f:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');f:close()
end
local function command(id)r.BR_Win32_SendMessage(app.explorer:window(),0x111,id,0)end
local function value(k)return select(2,app.preview:get(k))end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0);r.SetCurrentBPM(0,120,true)
  App.initialize(r,root,data);local b=assert(Model.load(data..'/bank.json'))
  b.settings.autoplay=false;b.settings.loop=true;b.settings.prepare_in_background=false;b.raw=Model.raw_settings()
  for _,m in ipairs(b.macros)do m.normalization.enabled=false end
  Model.save(data..'/bank.json',b);app=App.new(r,root,data)
  r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/long.wav',false)
  app.explorer:command(40019);app.explorer:toggle(1012,false);app.explorer:toggle(42004,false)
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick()
    if frame==14 then app:play();handle=app.preview.handle
    elseif frame==20 then
      command(40020)
      local _,_,_,_,_,_,_,_,bpm=r.MediaExplorerGetLastPlayedFileInfo();assert(bpm>0)
      assert(math.abs(value('D_PLAYRATE')-120/bpm)<1e-6,'Tempo waited for Lua')
    elseif frame==26 then
      assert(app.preview.handle==handle);assert(math.abs(app:effective().source_transform.rate-value('D_PLAYRATE'))<1e-6)
      command(40021)
    elseif frame==32 then
      local _,_,_,_,_,_,_,_,bpm=r.MediaExplorerGetLastPlayedFileInfo()
      assert(math.abs(value('D_PLAYRATE')-60/bpm)<1e-6)
      app:activate('heavy');assert(math.abs(tonumber(app.explorer:text(1454))-.72)<.001,'Tempo multiplier written into rate knob')
      assert(math.abs(value('D_PLAYRATE')-.72*60/bpm)<1e-6)
      command(40022)
    elseif frame==38 then
      local _,_,_,_,_,_,_,_,bpm=r.MediaExplorerGetLastPlayedFileInfo()
      assert(math.abs(value('D_PLAYRATE')-.72*240/bpm)<1e-6)
      command(40019);app:activate(nil);app.preview:seek_source(6)
    elseif frame==44 then before=app.preview:source_position();command(40034);app:tick()
      assert(app.preview:source_position()>before,'Fast forward did not move processed audio')
      before=app.preview:source_position();command(40033);app:tick()
      assert(app.preview:source_position()<before,'Rewind did not move processed audio')
      f:write('Tempo match 1x/half/double/off, Macro rate knob, forward/rewind: PASS\n')
      app.preview:stop();app.explorer:toggle(1012,true);app.explorer:toggle(42171,true)
      r.SetEditCurPos(.15,false,false);r.OnPlayButton()
    elseif frame==50 then
      app:play()
      assert(value('D_MEASUREALIGN')==1,'Start on bar was not passed to REAPER')
    elseif frame==56 then
      f:write(('Start on bar position before next measure: %.6f, project=%d %.6f, peak=%.6f\n'):format(value('D_POSITION'),r.GetPlayState(),r.GetPlayPosition(),r.Track_GetPeakInfo(app.bank.raw,0)))
      assert(value('D_POSITION')<.05,'Started before next bar')
    elseif frame==130 then
      assert(value('D_POSITION')>.2,'Did not start at next bar');r.OnStopButton();app.preview:stop()
      app.explorer:toggle(1012,false);app.explorer:toggle(1068,false);app.definition.settings.loop=false
      app.explorer:toggle(42004,true)
      r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/test.wav',false)
    elseif frame==142 then
      app.explorer:command(40030);expected=app.explorer:selection()
      r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/test.wav',false)
    elseif frame==154 then
      app:play();advance_start=r.time_precise()
    elseif advance_start then
      if app.path==expected and app.preview:playing()then
        f:write('EOF uses native next-file order and starts it with autoplay disabled: '..expected..'\n');finish(true)
      else assert(r.time_precise()-advance_start<6,'Native auto-advance did not start next file')end
    end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
