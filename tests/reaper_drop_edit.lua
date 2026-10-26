-- Native Cocoa drop, then immediate Timeline edits, deferred peaks and manual
-- baking after edits. Only runs in the owned, muted integration-test host.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local U=require('am.util');local J=require('am.json')
local I=require('am.insert');local D=require('am.render_item')
local path='/tmp/audition-macro-dev/media-fixtures/test.wav'
local log=assert(io.open(host..'/drop-edit.txt','w'));log:setvbuf('no')
local report={times=J.array{},checks=J.array{}};local app,item,frame,stage,due=nil,nil,0,0,0
local exec=r.ExecProcess;r.ExecProcess=function()error('D&D launched a process')end
local function finish(ok,err)
  r.ExecProcess=exec;if app then app:close()end
  report.status=ok and'PASS'or'FAIL';report.error=err;U.write(host..'/drop-edit.json',J.encode(report))
  log:write(ok and'PASS\n'or'FAIL '..tostring(err)..'\n');log:close()
end
local function check(name)report.checks[#report.checks+1]=name;log:write(name..'\n')end
local function drop()
  app.drop:tick();local arrange=r.JS_Window_FindChildByID(r.GetMainHwnd(),1000)
  local prior=r.JS_Window_GetForeground()
  report.focus_before_drop={focus=tostring(r.JS_Window_GetFocus()),foreground=prior and r.JS_Window_GetTitle(prior)}
  r.JS_Window_SetForeground(app.explorer:window()) -- Floating ME owns keyboard focus before the drop.
  local project=r.EnumProjects(-1);local tabs=0;while r.EnumProjects(tabs)do tabs=tabs+1 end
  local began=r.time_precise()
  assert(r.AM_TestWaveformDrop(app.explorer:control(1001),arrange,path),r.GetExtState('AuditionMacro.Drop.v1','message'))
  report.times[#report.times+1]=r.time_precise()-began
  assert(r.EnumProjects(-1)==project and not r.EnumProjects(tabs),'Drop opened/switched a project')
  local focus=r.JS_Window_GetFocus();local fg=r.JS_Window_GetForeground()
  report.focus={actual=tostring(focus),expected=tostring(arrange),foreground=fg and r.JS_Window_GetTitle(fg),
    actual_title=focus and r.JS_Window_GetTitle(focus),actual_class=focus and r.JS_Window_GetClassName(focus)}
  assert(r.JS_Window_GetFocus()==arrange,'Drop did not return keyboard focus to Arrange')
  if r.APIExists('JS_Window_IsEnabled')then assert(r.JS_Window_IsEnabled(r.GetMainHwnd()),'Drop left the main window disabled')end
  item=r.GetMediaItem(0,0);assert(item)
end
local ok,err=xpcall(function()
  r.Main_OnCommand(41929,0);r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.InsertTrackAtIndex(0,false);r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  local data=host..'/drop-edit-'..U.hash(r.genGuid());App.initialize(r,root,data)
  local bank=Model.defaults();bank.settings.autoplay=false;assert(Model.save(data..'/bank.json',bank))
  app=App.new(r,root,data);r.OpenMediaExplorer(path,false)
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,err=xpcall(function()
    frame=frame+1;app:tick();if frame<12 then return end
    if stage==0 then
      app:activate('heavy');app:tick();drop()
      assert(r.CountTakes(item)==2 and r.GetActiveTake(item)==r.GetTake(item,1))
      r.SetMediaItemInfo_Value(item,'D_POSITION',4);r.SetMediaItemInfo_Value(item,'D_LENGTH',.5)
      r.SetEditCurPos2(app.project,4.2,false,false)
      check('Automatic Rendered drop supports immediate move, trim and edit cursor, with Arrange focus')
      stage=1;due=r.time_precise()+.4
    elseif stage==1 and r.time_precise()>due then
      assert(r.GetMediaItemInfo_Value(item,'D_POSITION')==4 and r.GetMediaItemInfo_Value(item,'D_LENGTH')==.5)
      local take=r.GetActiveTake(item);local peaks=r.new_array(64)
      local count=r.GetMediaItemTake_Peaks(take,100,4,2,16,0,peaks)&0xfffff
      local peak=0;for i=1,count*2 do peak=math.max(peak,math.abs(peaks[i]))end
      assert(count>0 and peak>.001,'Deferred peaks are unavailable')
      check('Deferred peaks appear without selection/focus changes or overwriting the trim')
      assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
      drop();assert(r.CountTakes(item)==2)
      check('Cached native drop still has both takes and a single insertion Undo')
      assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
      app.definition.settings.auto_render_drops=false
      app:activate('dark');app:tick()
      local render=D.render;D.render=function()error('Manual mode rendered inside the drop')end
      local ok,e=pcall(drop);D.render=render;assert(ok,e)
      assert(r.CountTakes(item)==1)
      r.SetMediaItemInfo_Value(item,'D_POSITION',7);r.SetMediaItemInfo_Value(item,'D_LENGTH',.4)
      r.SetMediaItemTakeInfo_Value(r.GetTake(item,0),'D_STARTOFFS',.2)
      -- A saved/reopened drop remains independently bakeable after edits.
      local saved=host..'/editable-drop.rpp';r.Main_SaveProjectEx(0,saved,8)
      app:close();app=nil;r.Main_openProject(saved);item=r.GetMediaItem(0,0);r.SetMediaItemSelected(item,true)
      assert(require('am.drop_render').selected(r)==1)
      assert(r.GetMediaItemInfo_Value(item,'D_POSITION')==7 and r.GetMediaItemInfo_Value(item,'D_LENGTH')==.4)
      assert(math.abs(r.GetMediaItemTakeInfo_Value(r.GetActiveTake(item),'D_STARTOFFS')-.2)<1e-8)
      assert(r.CountTakes(item)==2)
      check('Manual bake after save/reopen preserves trimmed source alignment, item position and length')
      assert(r.Undo_DoUndo2(0)==1 and r.CountTakes(r.GetMediaItem(0,0))==1)
      item=r.GetMediaItem(0,0);local take=r.GetTake(item,0)
      r.TakeFX_SetParam(take,0,0,.1);r.SetMediaItemTakeInfo_Value(take,'D_PLAYRATE',.8)
      r.SetMediaItemSelected(item,true)
      assert(require('am.drop_render').selected(r)==1)
      assert(r.GetMediaItemInfo_Value(item,'D_LENGTH')==.4)
      assert(math.abs(r.GetMediaItemTakeInfo_Value(r.GetActiveTake(item),'D_STARTOFFS')-.25)<1e-8)
      check('Explicit bake reads current Take FX and rate edits without changing Timeline geometry')
      finish(true);stage=2
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif stage~=2 then r.defer(tick)end
end
r.defer(tick)
