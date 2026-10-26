-- Exercise the real launcher and native panels in a disposable host without ReaImGui.
-- The modal drag gate is injected; native panel lifetime and preview are real.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use the disposable test host')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Bar=require('am.bar');local U=require('am.util');local J=require('am.json')
local app,done,modal,stopped
local updates,phase,cycles=0,0,0;local began=r.time_precise();local deadline=began+30
local data=host..'/editor-lifecycle';r.RecursiveCreateDirectory(data,0)
local result={status='RUNNING',checks=J.array{},version=r.GetAppVersion()}
local create,barTick,context,dialog=App.new,Bar.tick,r.AM_DropContext,r.ShowMessageBox
local edit,updatesBefore,untilTime,foreground,preview,focus
local path=host.."/media 素材/test one's 音.wav"
local function check(name)
  result.checks[#result.checks+1]=name
  assert(U.write(host..'/windows-review-progress.json',J.encode(result)))
end
local function finish(ok,err)
  if done then return end;done=true
  App.new=create;Bar.tick=barTick;r.AM_DropContext=context;r.ShowMessageBox=dialog
  if app then app:close()end
  result.status=ok and 'PASS' or 'FAIL';result.error=err;result.elapsed=r.time_precise()-began
  assert(U.write(host..'/windows-review.json',J.encode(result)))
  assert(U.write(data..'/editor.txt',result.status..'\n'..(err or '')..'\n'))
end
r.atexit(function()finish(false,'Editor test terminated early')end)
App.new=function(api,path,_)
  App.new=create;app=create(api,path,data)
  app.definition.settings.autoplay=false;app.definition.settings.loop=true
  return app
end
Bar.tick=function(self)updates=updates+1;return barTick(self)end
r.AM_DropContext=function()return modal and '{"phase":"gesture"}' or context()end
-- A failing launcher must report to the test, not block on a modal message box.
r.ShowMessageBox=function(message,title)stopped=title..': '..message;return 1 end
local ok,why=xpcall(function()
  assert(not r.APIExists('ImGui_GetBuiltinPath'),'This regression requires a host without ReaImGui')
  assert(r.file_exists(path),'Missing synthetic media fixture')
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.OpenMediaExplorer(path,false)
  assert(loadfile(root..'/SoundPrep.lua'))()
end,debug.traceback)
if not ok then finish(false,why);return end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()<deadline,'Editor lifecycle timed out in phase '..phase)
    assert(not stopped,stopped)
    assert(app and not app.cleaned,'Companion stopped during editor lifecycle')
    local geometry=J.decode(r.AM_BarGeometry())
    if phase==0 then
      if r.time_precise()-began<.5 or not U.path_equal(app.path,path)then return end
      assert(app.bar and not geometry.editor_open,'Startup opened an editor')
      app:activate('heavy');app:play()
      app.editor_requested=true;phase=1
    elseif phase==1 then
      if not geometry.editor_open then return end
      app.bar:dispatch('editor@'..J.encode{id='heavy',op='set',key='name',value='Unsaved マイク preset'})
      untilTime=r.time_precise()+.2;phase=2
    elseif phase==2 then
      if r.time_precise()<untilTime then return end
      edit=app:preset_draft('heavy');assert(edit.name=='Unsaved マイク preset')
      assert(app.preview:playing());preview=app.preview.handle
      check('Native editor opens lazily and accepts edits through the real launcher without ReaImGui')
      modal=true;updatesBefore=updates;untilTime=r.time_precise()+.8
      foreground=r.JS_Window_GetForeground();focus=app.editor_panel_focus;phase=3
    elseif phase==3 then
      if r.time_precise()<untilTime then return end
      assert(geometry.editor_open and updates==updatesBefore,'Drag wait updated or closed the native panel')
      assert(r.JS_Window_GetForeground()==foreground and app.editor_panel_focus==focus,'Drag wait changed focus')
      assert(app:preset_draft('heavy')==edit and app.preview.handle==preview and app.preview:playing())
      check('Drag gate preserves native panel, unsaved edits and preview without updates or focus changes')
      modal=false;app.settings_requested=true;app.channels_requested=true;phase=4
    elseif phase==4 then
      if updates==updatesBefore or not geometry.settings_open or not geometry.microphones_open then return end
      assert(geometry.editor_open and app:preset_draft('heavy')==edit)
      check('Native App settings and microphone selection coexist with the editor after the drag wait')
      app.bar:dispatch('settings:close');app.bar:dispatch('channels:close')
      app.bar:dispatch('editor:close');phase=5
    elseif phase==5 then
      if geometry.editor_open or geometry.settings_open or geometry.microphones_open then return end
      assert(app:preset_draft('heavy')==edit and app:effective().name==edit.name,'Closing panels discarded live edits')
      app.editor_requested=true;phase=6
    elseif phase==6 then
      if not geometry.editor_open then return end
      assert(app:preset_draft('heavy')==edit and not app.closed and app.bar)
      cycles=cycles+1
      if cycles<2 then app.bar:dispatch('editor:close');phase=5
      else
        check('Two native editor close/reopen cycles preserve the draft, companion and embedded bar')
        finish(true)
      end
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
