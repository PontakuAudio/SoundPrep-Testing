-- Real audio/standard waveform integration; physical gestures are separate QA.
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_WaveCursorState'),'Update the native helper')
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local J=require('am.json');local Time=require('am.timeline')
local data=r.GetResourcePath()..'/cursor-test';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/cursor.txt','w'));f:setvbuf('no')
local app,frame,done,initial,handle,loads,paused,range_deadline
frame=0
local function finish(ok,e)
  if done then return end;done=true;if app then app:close()end
  f:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');f:close()
end
local function state()return J.decode(r.AM_WaveCursorState())end
local function command(id)r.BR_Win32_SendMessage(app.explorer:window(),0x111,id,0)end
local function range(a,b)
  range_deadline=r.time_precise()+3
  for _,v in ipairs{{1455,a},{1456,b}}do
    local c=app.explorer:control(v[1]);r.JS_Window_SetFocus(c);r.JS_Window_SetTitle(c,v[2])
    r.BR_Win32_SendMessage(c,0x100,13,0);r.BR_Win32_SendMessage(c,0x101,13,0)
  end
end
local function check()
  local s=state();local source=app.preview:source_position()
  assert(s.attached and source,'Cursor or audio detached')
  local distance=math.abs(s.fraction*12-source)
  if app.range and app.definition.settings.loop then
    distance=math.min(distance,math.abs((app.range[2]-app.range[1])-distance))
  end
  assert(distance<.15,('Cursor drifted from audio position: %.6f vs %.6f'):format(s.fraction*12,source))
  local text=Time.clock(app.explorer:text(1016))
  assert(text and math.abs(text-s.position)<.1,'Clock did not follow audio')
  return s
end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data);local b=assert(Model.load(data..'/bank.json'))
  b.settings.autoplay=false;b.settings.prepare_in_background=false;b.settings.loop=true;b.raw=Model.raw_settings()
  for _,m in ipairs(b.macros)do m.normalization.enabled=false end
  Model.save(data..'/bank.json',b);app=App.new(r,root,data)
  r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/long.wav',false)
  app.explorer:command(42093);app.explorer:toggle(40032,false)
  app.explorer:command(40019);app.explorer:toggle(1012,false)
  range('0:00.000','0:12.000')
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick()
    if frame==12 then
      local _,_,_,a,b=r.MediaExplorerGetLastPlayedFileInfo()
      if (math.abs(a)>.0001 or math.abs(b-1)>.0001) and r.time_precise()<range_deadline then frame=11;return end
      assert(math.abs(a)<.0001 and math.abs(b-1)<.0001,'Fixture retained previous selection')
      app:play();handle=app.preview.handle;loads=app.bank.loads
    elseif frame==18 then initial=check();assert(initial.visible)
    elseif frame==28 then
      local s=check();assert(s.x>initial.x and s.position>initial.position,'Playhead is stationary')
      app.explorer:set_number(1454,.5)
    elseif frame==38 then
      local s=check();assert(math.abs(s.length-24)<.001 and app.preview.handle==handle)
      app:reverse()
    elseif frame==44 then initial=check()
    elseif frame==54 then
      local s=check();assert(s.fraction<initial.fraction,'Reverse cursor moves forwards')
      command(1010)
    elseif frame==60 then paused=state();assert(not app.preview:playing())
    elseif frame==68 then
      local s=state();assert(s.fraction==paused.fraction and s.position==paused.position,'Paused cursor moves')
      command(1010)
    elseif frame==76 then
      check();app:activate('heavy');assert(app.bank.loads==loads,'Cursor created new FX instances')
    elseif frame==84 then check();app:activate(nil)
    elseif frame==92 then range('0:03.000','0:09.000')
    elseif frame==98 then
      if not(app.range and math.abs(app.range[1]-3)<.002 and math.abs(app.range[2]-9)<.002) and r.time_precise()<range_deadline then frame=97;return end
      assert(app.range and math.abs(app.range[1]-3)<.002 and math.abs(app.range[2]-9)<.002)
      app.explorer:command(42092)
    elseif frame==106 then
      local wave=app.explorer:control(1046);local x=350
      r.BR_Win32_SendMessage(wave,0x201,1,30<<16|x);r.BR_Win32_SendMessage(wave,0x202,0,30<<16|x)
      app:tick();command(1010);app:tick()
    elseif frame==112 then
      local s=state();assert(s.visible and math.abs(s.x-350)<8,'Zoomed cursor disagrees with native click: '..s.x)
      f:write(('zoomed native click: x=350, cursor=%d; no native transport running\n'):format(s.x))
      command(1010)
      app.explorer:command(42093);range('0:03.000','0:03.300')
    elseif frame==122 then
      if not(app.range and math.abs(app.range[2]-3.3)<.002) and r.time_precise()<range_deadline then frame=121;return end
      initial=app.preview.starts;app.explorer:command(42092)
    elseif frame==128 then
      local wave=app.explorer:control(1046)
      r.BR_Win32_SendMessage(wave,0x201,1,30<<16|350);r.BR_Win32_SendMessage(wave,0x202,0,30<<16|350)
      app:tick();command(1010);app:tick()
    elseif frame==132 then
      local s=state();assert(s.visible and math.abs(s.x-350)<4,'Narrow zoom lost pixel precision: '..s.x)
      f:write(('0.3-second zoom: native x=350, cursor=%d\n'):format(s.x))
      command(1010);app:tick();initial=app.preview.starts
    elseif frame==146 then
      local s=check();assert(s.fraction>=.25 and s.fraction<=.275 and s.position<=.3,'Loop cursor escaped range')
      assert(app.preview.starts==initial,'Loop recreated audio')
      command(1009);app:tick();assert(not app.preview:playing())
      app.explorer:command(40069)
    elseif frame==150 then
      assert(not state().attached,'Closed ME retained cursor timer/compositor')
      r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/long.wav',false)
    elseif frame==160 then app:play()
    elseif frame==168 then
      check();app:close();assert(not state().attached,'Detach leaked cursor timer')
      f:write('forward, live rate, reverse, pause/resume, Macro/Raw, range, zoom, repeat, close/reopen, detach\n');finish(true)
    elseif frame>220 then error('Timed out')end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
