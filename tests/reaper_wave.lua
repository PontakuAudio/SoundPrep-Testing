-- Real native waveform notification tests in an owned, silent REAPER host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_WavePoll'),'Update the test host helper')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local Time=require('am.timeline')
local data=r.GetResourcePath()..'/wave-test';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/wave.txt','w'));f:setvbuf('no')
local app,frame,done=nil,0,false;local handle,starts,last_source,range_deadline
local deadline=r.time_precise()+180
local function finish(ok,e)
  if done then return end;done=true;if app then app:close()end
  f:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');f:close()
end
local function command(id)r.BR_Win32_SendMessage(app.explorer:window(),0x111,id,0)end
local function source_clock()
  local rounded=r.GetToggleCommandStateEx(32063,40032)==1
  if rounded then app.explorer:command(40032)end
  local text=app.explorer:text(1016)
  if rounded then app.explorer:command(40032)end
  local _,_,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
  if mode&256==0 or b<=a then a=0;b=1 end
  return (a+Time.clock(text)/Time.clock(text:match('/%s*(.*)'))*(b-a))*12
end
local function mouse(message,x,y,flags)
  r.BR_Win32_SendMessage(app.explorer:control(1046),message,flags or 0,((y or 30)<<16)|x)
end
local function select_range(a,b)
  range_deadline=r.time_precise()+3
  for _,v in ipairs{{1455,a},{1456,b}}do
    local c=app.explorer:control(v[1]);r.JS_Window_SetFocus(c);r.JS_Window_SetTitle(c,v[2])
    r.BR_Win32_SendMessage(c,0x100,13,0);r.BR_Win32_SendMessage(c,0x101,13,0)
  end
end
local function click(x,full_view)
  local focused=r.JS_Window_GetFocus()
  mouse(0x201,x,30,1);mouse(0x202,x,30,0)
  local expected=source_clock()
  if full_view then
    -- Independent source-coordinate oracle. Do not merely assert that our
    -- clock reader and seek consumer repeat the same coordinate mistake.
    local sized,width=r.JS_Window_GetClientSize(app.explorer:control(1046));assert(sized and width>0)
    assert(math.abs(expected-x/width*12)<24/width,'Native click disagrees with full waveform geometry')
  end
  f:write(('click x=%d clock=%s expected=%.6f actual=%s range=%s\n'):format(x,app.explorer:text(1016),expected,tostring(app.preview:source_position() or 'stopped'),(app.range and table.concat(app.range,',') or 'full')))
  if app.preview:playing()then
    local _,_,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
    local has_range=mode&256~=0 and b>a
    local changed=(app.range~=nil)~=has_range or (app.range and (math.abs(app.range[1]-a*12)>.002 or math.abs(app.range[2]-b*12)>.002))
    if not changed then
      assert(math.abs(app.preview:source_position()-expected)<.04,'Seek waited for Lua or used wrong source coordinates')
    end
  end
  app:tick()
  assert(app.last_seek and math.abs(app.last_seek.source-expected)<.002,'Missing native seek bookmark')
  -- Our observer never restores focus to the list; the native waveform may
  -- legitimately take focus. Search/list focus changes are tested separately.
  assert(focused==r.JS_Window_GetFocus() or r.JS_Window_GetFocus()==app.explorer:control(1046))
  last_source=expected;return expected
end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data);local bank=assert(Model.load(data..'/bank.json'))
  bank.settings.autoplay=false;bank.settings.loop=true;bank.settings.prepare_in_background=false
  bank.raw=Model.raw_settings();for _,m in ipairs(bank.macros)do m.normalization.enabled=false end
  Model.save(data..'/bank.json',bank);app=App.new(r,root,data)
  r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/long.wav',false)
  app.explorer:command(42093);app.explorer:toggle(40032,false)
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick()
    assert(r.time_precise()<deadline,'Timed out waiting for standard range controls')
    if frame==12 then
      mouse(0x201,400,30,1);mouse(0x202,400,30,0);app:tick()
      app:play();handle=app.preview.handle;starts=app.preview.starts
      click(400,true);assert(app.preview.handle==handle and app.preview.starts==starts)
      app:activate('heavy');handle=app.preview.handle;starts=app.preview.starts
      click(400,true);assert(app.preview.handle==handle and app.preview.starts==starts)
      app.explorer:set_number(1454,.5)
    elseif frame==16 then
      assert(select(2,app.preview:get('D_PLAYRATE'))==.5)
      click(200,true);assert(app.preview.handle==handle and app.preview.starts==starts)
      app:reverse()
    elseif frame==20 then
      handle=app.preview.handle;starts=app.preview.starts
      click(450,true);assert(app.preview.handle==handle and app.preview.starts==starts)
      assert(app:effective().source_transform.reverse)
      app.explorer:toggle(40032,true)
      click(333);assert(r.GetToggleCommandStateEx(32063,40032)==1,'Changed clock display preference')
      f:write('immediate Raw, rate 0.5, Reverse and rounded clock seeks; same preview/FX instances\n')
      command(1009)
    elseif frame==24 then
      assert(not app.preview:playing());click(150)
      assert(not app.preview:playing(),'Stopped click unexpectedly started audio')
      command(1008)
    elseif frame==28 then
      assert(app.preview:playing() and math.abs(app.preview:source_position()-last_source)<.2,'Play lost stopped-click bookmark')
      command(1010)
    elseif frame==32 then
      assert(not app.preview:playing());click(420);command(40028)
    elseif frame==36 then
      assert(app.preview:playing() and math.abs(app.preview:source_position()-last_source)<.2,'Play from last seek lost bookmark')
      app:activate(nil);app.explorer:toggle(40032,false)
    elseif frame==42 then
      select_range('0:03.000','0:09.000')
    elseif frame==46 then
      if not(app.range and math.abs(app.range[1]-3)<.002 and math.abs(app.range[2]-9)<.002) and r.time_precise()<range_deadline then frame=45;return end
      assert(app.range and math.abs(app.range[1]-3)<.002 and math.abs(app.range[2]-9)<.002,'Native range did not propagate')
      app.explorer:command(42092)
    elseif frame==50 then
      local expected=click(350)
      assert(expected>3 and expected<9,'Zoomed click used full-file pixel mapping')
      assert(math.abs(app.preview:source_position()-expected)<.04)
      f:write('stopped/paused bookmarks, Play from last seek, range and native zoom coordinates\n')
      app.explorer:command(42093)
      select_range('0:02.000','0:05.000')
    elseif frame==56 then
      local ok,_,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
      if not(ok and mode&256~=0 and math.abs(a*12-2)<.002 and math.abs(b*12-5)<.002) and r.time_precise()<range_deadline then frame=55;return end
      assert(ok and mode&256~=0 and math.abs(a*12-2)<.002 and math.abs(b*12-5)<.002,'Native range edit was intercepted')
      assert(app.range and math.abs(app.range[1]-a*12)<.002 and math.abs(app.range[2]-b*12)<.002)
      assert(not app.last_seek,'Range edit retained an old click bookmark')
      f:write('native range edits remain native and preview bounds follow\n')
      app.explorer:command(40069)
    elseif frame==60 then
      assert(not app.explorer:window());r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/long.wav',false)
    elseif frame==68 then
      app.explorer:command(42093);click(300)
      assert(r.MediaExplorerGetLastPlayedFileInfo(),'Waveform was unloaded by a seek')
      f:write('close/reopen reattaches observer and waveform remains loaded\n');finish(true)
    elseif frame>120 then error('Timed out')end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
