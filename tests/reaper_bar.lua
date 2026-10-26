-- Run only in the isolated host prepared by tools/prepare_test_host.py.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper
assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'),'Use the disposable test host')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Bar=require('am.bar');local J=require('am.json');local C=require('am.native_contract')
local data=r.GetResourcePath()..'/bar-integration';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/bar.txt','w'));f:setvbuf('no')
local function log(...)for _,v in ipairs({...})do f:write(tostring(v),'\t')end;f:write('\n')end
local app,frame,base=nil,0,nil
local function geometry()return J.decode(r.AM_BarGeometry())end
local function size(w,h)
  local window=assert(app.explorer:window());assert(r.JS_Window_SetPosition(window,120,120,w,h))
end
local function finish(ok,e)
  if app then app:close()end
  log(ok and 'PASS' or 'FAIL',e or '');f:close()
end
local ok,e=xpcall(function()
  assert(Bar.available(r),'Updated native helper is required')
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  local w=r.OpenMediaExplorer('/tmp/audition-macro-dev/test.wav',false)
  if r.GetToggleCommandStateEx(32063,40008)==1 then r.JS_WindowMessage_Send(w,'WM_COMMAND',40008,0,0,0)end
  app=App.new(r,root,data);app.definition.settings.autoplay=false
  for _,track in pairs(app.bank.macros)do assert(r.TrackFX_GetChainVisible(track)==-1,'Preloading opened an FX editor')end
  size(1060,620);app.bar=Bar.new(r,app)
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick();app.bar:tick()
    if frame==3 then
      local g=geometry();log('wide',r.AM_BarGeometry());assert(g.attached and g.same_window and not g.hidden and g.height==72)
      assert(g.control_count==#C.bar.controls+#app.definition.macros,'Updated native controls are not loaded')
      assert(g.list_height+g.height==g.base_height);base=g.base_height
      -- Exercise source-driven visibility on the actual native child controls.
      -- Playback/channel routing is covered separately by preview integration.
      local normal=app.bar:state();assert(not normal.multichannel and not g.downmix_visible)
      local multichannel=app.bar:state();multichannel.multichannel=true;multichannel.downmix=false
      assert(r.AM_BarSetState(J.encode(multichannel)))
      assert(geometry().downmix_visible and not geometry().downmix)
      multichannel.downmix=true;assert(r.AM_BarSetState(J.encode(multichannel)))
      assert(geometry().downmix_visible and geometry().downmix)
      multichannel.multichannel=false;assert(r.AM_BarSetState(J.encode(multichannel)))
      assert(not geometry().downmix_visible and geometry().downmix)
      assert(r.AM_BarSetState(J.encode(normal)))
      assert(not geometry().downmix_visible and geometry().downmix==normal.downmix)
      assert(geometry().base_height==base,'Downmix visibility accumulated lost list height')
      log('downmix visibility/state','PASS')
      assert(not r.AM_BarSetState('[]'));assert(not r.AM_BarSetState('{"macros":42}'))
      size(680,620)
    elseif frame==6 then
      local g=geometry();log('narrow',r.AM_BarGeometry());assert((g.height==72 or g.height==98) and g.list_height+g.height==g.base_height)
      size(1060,620)
    elseif frame==9 then
      assert(geometry().base_height==base,'Repeated resize accumulated lost list height')
      size(680,340)
    elseif frame==12 then
      local g=geometry();log('compact',r.AM_BarGeometry());assert(not g.hidden and (g.height==30 or g.height==54) and g.list_height+g.height==g.base_height)
      size(1060,620)
    elseif frame==15 then
      -- Simulate a native button event arriving between the app and bar ticks.
      -- No following app tick is allowed before reading the drop snapshot.
      local native_poll=r.AM_BarPoll;local queued=true
      r.AM_BarPoll=function()if queued then queued=false;return 'macro:dark'end;return ''end
      local ran,why=pcall(app.bar.tick,app.bar);r.AM_BarPoll=native_poll;assert(ran,why)
      local drop_state=J.decode(r.GetExtState('AuditionMacro.Drop.v1','state'))
      assert(drop_state.macro.id=='dark','Immediate drag would use the previous Macro')
      assert(geometry().base_height==base)
      app.bar:dispatch('macro:heavy');app.bar:dispatch('reverse')
      local reverse=app:effective().source_transform.reverse
      app.bar:dispatch('target:-14');assert(app:effective().normalization.enabled and app:effective().normalization.target_lufs==-14)
      assert(app:effective().source_transform.reverse==reverse,'Normalize must preserve temporary reverse')
      app.bar:dispatch('raw');assert(not app:effective().normalization.enabled)
      app.bar:dispatch('ab');assert(app.selected_id=='heavy')
      assert(not app:effective().source_transform.preserve_pitch)
      app.bar:dispatch('preserve_pitch')
      assert(app:effective().source_transform.preserve_pitch and app.explorer:transform().preserve_pitch)
      app.bar:dispatch('preserve_pitch')
      assert(not app:effective().source_transform.preserve_pitch and not app.explorer:transform().preserve_pitch)
      app.bar:dispatch('monitor:-12');assert(app.definition.settings.monitor_gain_db==-12)
      app.bar:dispatch('edit');assert(app.editor_requested);app.editor_requested=nil
      app.explorer:command(40008)
    elseif frame==19 then
      log('docked',r.AM_BarGeometry());assert(geometry().attached and geometry().same_window)
      app.explorer:command(40008)
    elseif frame==23 then
      size(1060,620)
      app.explorer:command(40069)
    elseif frame==26 then
      assert(not geometry().attached,'Closed ME retained a bar');app.explorer:window(true)
    elseif frame==30 then
      local g=geometry();log('reopened',r.AM_BarGeometry());assert(g.attached and g.same_window)
      local list=app.explorer:control(1001);local _,_,a,_,b=r.JS_Window_GetRect(list)
      app.bar:close()
      local _,_,c,_,d=r.JS_Window_GetRect(list)
      assert(math.abs(d-c)-math.abs(b-a)==(g.hidden and 0 or g.height),'Native list size was not restored')
      assert(r.AM_BarGeometry()=='{}')
    end
  end,debug.traceback)
  if not ok then finish(false,e)elseif frame>=30 then finish(true)else r.defer(tick)end
end
tick()
