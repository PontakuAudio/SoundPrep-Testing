-- Run the real launcher and native bar with only the APIs they need available.
local App=require('am.app');local Bar=require('am.bar');local J=require('am.json')
local old_reaper,create,new= _G.reaper,App.new,Bar.new
local ok,err=xpcall(function()
  for _,fail_attach in ipairs{false,true}do
    local project,window,list={},{},{};local callback,at_exit,dialog,modal
    local attached,updated,polled,ticks,published,detached=0,0,0,0,0,0
    local app={project=project,draft={name='Unsaved value'},explorer={window=function()return window end,control=function()return list end}}
    local r={GetOS=function()return 'Linux'end,GetExtState=function()return ''end,atexit=function(fn)at_exit=fn end,
      APIExists=function(name)return name=='AM_DropContext'end,AM_DropContext=function()return modal and 'drag' or ''end,
      EnumProjects=function()return project end,defer=function(fn)callback=fn end,
      ShowMessageBox=function(text)dialog=text end,
      AM_BarAttach=function(w,l)assert(w==window and l==list);attached=attached+1;return not fail_attach end,
      AM_BarSetState=function(state)updated=updated+1;assert(J.decode(state));return true end,
      AM_BarPoll=function()polled=polled+1;return ''end,AM_BarDetach=function()detached=detached+1 end}
    app.r=r
    function app:check_project()return true end
    function app:tick()ticks=ticks+1 end
    function app:publish()published=published+1 end
    function app:close()
      if self.cleaned then return end
      self.closed=true;self.cleaned=true;if self.bar then self.bar:close()end
    end
    App.new=function()return app end
    Bar.new=function(api,a)
      local bar=new(api,a)
      -- Controller payloads have dedicated tests; keep the real native lifecycle.
      function bar:state()return {editor_open=a.editor_panel_open==true,focus=a.editor_panel_focus or 0}end
      return bar
    end
    _G.reaper=r
    dofile('./SoundPrep.lua')
    if fail_attach then
      assert(dialog and dialog:find('Could not attach',1,true)and app.cleaned)
      assert(not callback and detached==1,'Failed native startup left a companion running')
    else
      assert(not dialog and callback and not app.editor_panel_open,'Startup opened an editor')
      app.editor_requested=true;callback()
      assert(app.editor_panel_open and not app.editor_requested)
      local draft=app.draft;local before={attached,updated,polled,ticks,app.editor_panel_focus}
      modal=true;for _=1,20 do callback()end
      assert(attached==before[1]and updated==before[2]and polled==before[3]and ticks==before[4]and published==20)
      assert(app.editor_panel_focus==before[5]and app.draft==draft,'Drag wait changed editor state')
      modal=false;callback();assert(ticks==before[4]+1)
      for _=1,2 do
        app.bar:dispatch('editor:close');callback();assert(not app.editor_panel_open and not app.closed)
        app.editor_requested=true;callback();assert(app.editor_panel_open and app.draft==draft)
      end
      app.bar:dispatch('quit');callback();assert(app.cleaned and detached==1)
    end
    at_exit();assert(detached==1,'Exit cleanup detached twice')
  end
end,debug.traceback)
App.new=create;Bar.new=new;_G.reaper=old_reaper
assert(ok,err)
