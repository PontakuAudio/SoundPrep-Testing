-- Close only disposable projects in an isolated REAPER resource directory.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use the disposable test host')
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local U=require('am.util');local J=require('am.json')
local Bank=require('am.bank');local Preview=require('am.preview');local Drop=require('am.drop')
local result={status='RUNNING',version=r.GetAppVersion(),checks=J.array{}}
local app;local console,dialog=r.ShowConsoleMsg,r.ShowMessageBox
local warnings={}
r.ShowConsoleMsg=function(text)warnings[#warnings+1]=text end
r.ShowMessageBox=function(text)error('Unexpected dialog: '..text)end
local function check(name)result.checks[#result.checks+1]=name end
local function start(name)
  local data=host..'/'..name;r.RecursiveCreateDirectory(data..'/chains',0)
  local definition=Model.defaults()
  for _,m in ipairs(definition.macros)do assert(U.write(data..'/'..m.fx_chain,'SHOW -1\nLASTSEL 0\nDOCKED 0\n'))end
  assert(Model.save(data..'/bank.json',definition))
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  -- The project, bank, native preview and drop shutdown use real APIs. Explorer
  -- restoration is counted here; background hosts cannot create its controls.
  local project=r.EnumProjects(-1)
  app=setmetatable({r=r,root=root,data=data,project=project,session=U.hash(r.genGuid()),
    definition=definition,bank=Bank.new(r,project,data,definition,'lifecycle'),
    explorer_restores=0,loudness={poll=function()end,close=function()end}},App)
  app.preview=Preview.new(r,project,app.bank.input)
  app.explorer={restore=function()app.explorer_restores=app.explorer_restores+1 end}
  app.drop=assert(Drop.new(r,app));app:publish()
  local originals={};for _,m in ipairs(definition.macros)do originals[m.fx_chain]=assert(U.read(data..'/'..m.fx_chain))end
  app.preview:start(host..'/silence.wav',Model.effective(definition,nil),0,definition.settings)
  assert(app.preview:playing())
  return originals
end
local function closed(originals)
  assert(app.closed and app.cleaned and not app.preview.handle,'Companion did not close/release preview')
  assert(#warnings==0,'False save/preservation warning: '..table.concat(warnings))
  for path,text in pairs(originals)do assert(U.read(app.data..'/'..path)==text,'Missing FX overwrote saved preset')end
  assert(r.GetExtState(App.EXT,'session')=='')
  assert(r.GetExtState(require('am.drop').EXT,'state')=='')
  assert(app.explorer_restores==1,'Explorer settings were not restored exactly once')
  app:close();app.drop:tick();assert(#warnings==0,'Repeated exit emitted a warning')
end
local ok,err=xpcall(function()
  require('am.native').require(r)
  -- A different tab pauses the companion; closing the attached tab stops it.
  local originals=start('close-tab');local attached=app.project
  r.Main_OnCommand(41929,0);local other=r.EnumProjects(-1)
  r.InsertTrackAtIndex(0,false);local untouched=r.GetTrack(other,0)
  app:tick();app.drop:tick()
  assert(not app.closed and not app.cleaned and not app.preview:playing())
  check('Tab switch pauses preview and leaves the companion alive')
  r.SelectProjectInstance(attached);r.Main_SaveProjectEx(attached,host..'/close-tab.rpp',8)
  r.Main_OnCommand(40860,0)
  assert(r.EnumProjects(-1)==other)
  app:tick();closed(originals)
  assert(r.CountTracks(other)==1 and r.ValidatePtr2(other,untouched,'MediaTrack*'),'Cleanup modified the other tab')
  check('Closing the attached tab exits without warning or changing the other project')
  r.DeleteTrack(untouched)
  -- Close the last tab: the resulting empty project can reuse its pointer.
  originals=start('close-last');attached=app.project
  r.Main_SaveProjectEx(attached,host..'/close-last.rpp',8)
  r.Main_OnCommand(40860,0)
  app.drop:tick();closed(originals)
  check('Closing the last project protects saved FX and the direct drop callback')
  -- File > New can reuse the project object while discarding all tracks.
  originals=start('replace-project');attached=app.project
  r.Main_SaveProjectEx(attached,host..'/replace-project.rpp',8)
  r.Main_OnCommand(40023,0)
  result.replaced_pointer_reused=r.EnumProjects(-1)==attached
  assert(not app.bank:valid(app.bank.input),'New Project retained the old preview track')
  app:tick();closed(originals)
  check('New Project exits safely even when the project pointer is reused')
end,debug.traceback)
if app then pcall(app.close,app)end
r.ShowConsoleMsg=console;r.ShowMessageBox=dialog
result.status=ok and 'PASS' or 'FAIL';result.error=err
assert(U.write(host..'/project-lifecycle.json',J.encode(result)))
if ok then r.Main_OnCommand(40004,0)end -- Quit this disposable host only.
