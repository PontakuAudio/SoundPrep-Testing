-- Actual REAPER APIs in a marked, muted host; shared by macOS/Windows.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local J=require('am.json');local U=require('am.util');local C=require('am.chunk')
local I=require('am.insert');local T=require('am.take_fx');local E=require('am.export');local Model=require('am.model')
local report={checks=J.array{},status='RUNNING'}
local function check(s)report.checks[#report.checks+1]=s end
local function restored_item()
  for i=0,r.CountMediaItems(0)-1 do local item=r.GetMediaItem(0,i);if r.CountTakes(item)==2 then return item end end
  error('Baked source item missing')
end
local ok,err=xpcall(function()
  require('am.native').require(r)
  r.Main_OnCommand(41929,0);local project=r.EnumProjects(-1)
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(project),'D_VOL',0)
  r.GetSetProjectInfo(project,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(project,'PROJECT_SRATE_USE',1,true)
  r.InsertTrackAtIndex(0,false);local track=r.GetTrack(project,0)
  local fx=r.TrackFX_AddByName(track,'VST: ReaDelay (Cockos)',false,-1);assert(fx>=0,'ReaDelay missing')
  r.TrackFX_SetParam(track,fx,0,.73)
  local expected={[0]=r.TrackFX_GetParam(track,fx,0),[1]=-9,[3]=-3}
  local bypass=r.TrackFX_AddByName(track,'JS: utility/volume_pan',false,-1);assert(bypass>=0)
  r.TrackFX_SetParam(track,bypass,0,-9);r.TrackFX_SetEnabled(track,bypass,false)
  local offline=r.TrackFX_AddByName(track,'JS: utility/volume_pan',false,-1);assert(offline>=0)
  r.TrackFX_SetParam(track,offline,0,-18);r.TrackFX_SetOffline(track,offline,true)
  local chain=C.portable(C.block(C.read_track(r,track),'FXCHAIN'))
  for i=r.TrackFX_GetCount(track)-1,0,-1 do r.TrackFX_Delete(track,i)end
  local path=host..'/media-fixtures/test.wav';assert(r.file_exists(path),'Prepare the test host media fixture first')
  local macro=Model.macro('fx-resource','FX resource test');macro.output_gain_db=-3;macro.export.tail_seconds=0
  local snapshot=E.snapshot(r,path,macro,chain,0,assert(require('am.loudness').identity(r,path)),nil,Model.defaults().settings)
  local dir=host..'/take-fx-'..U.hash(r.genGuid())
  local plan=I.prepare(r,snapshot,1,true,dir)
  local keeper=r.AddMediaItemToTrack(track);r.AddTakeToMediaItem(keeper)
  r.SetMediaItemInfo_Value(keeper,'D_LENGTH',1)
  local foreign=r.TakeFX_AddByName(r.GetTake(keeper,0),'JS: utility/volume_pan',-1);assert(foreign>=0)
  r.Undo_BeginBlock2(project)
  local item=r.AddMediaItemToTrack(track);local source=r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(source,r.PCM_Source_CreateFromFile(path))
  I.replace(r,project,item,plan);r.SetMediaItemSelected(item,true)
  r.Undo_EndBlock2(project,'Resource test insertion',-1)
  source=r.GetTake(item,0);local rendered=r.GetTake(item,1)
  assert(r.GetActiveTake(item)==rendered and r.TakeFX_GetCount(source)==4)
  local guids={}
  for i=0,3 do assert(r.TakeFX_GetOffline(source,i),'Inactive source FX is still online');guids[i]=r.TakeFX_GetFXGUID(source,i)end
  assert(not r.TakeFX_GetEnabled(source,1))
  report.offline_chunk=C.block(C.read_item(r,item),'TAKEFX')
  check('Cold insertion offlines every source FX, including bypassed FX, while Rendered has no FX')
  local controller=T.new(r,project);controller:tick()
  r.SetActiveTake(source)
  local undo=r.Undo_CanUndo2(project)
  assert(undo=='Resource test insertion','Insertion did not form one Undo point')
  controller:tick()
  for i=0,3 do
    assert(r.TakeFX_GetOffline(source,i)==(i==2),'Original offline flags were not restored')
    assert(r.TakeFX_GetFXGUID(source,i)==guids[i],'Offline cycle changed FX GUID')
    if i~=2 then assert(math.abs(r.TakeFX_GetParam(source,i,0)-expected[i])<1e-7,'Offline cycle changed parameter '..i)end
  end
  assert(not r.TakeFX_GetEnabled(source,1),'Offline cycle changed bypass flag')
  report.undo_before=undo;report.undo_after=r.Undo_CanUndo2(project)
  assert(report.undo_after==undo,'Resource controller changed insertion Undo')
  check('Selecting Source restores only managed FX and preserves GUIDs, parameters, bypass and insertion Undo')
  r.SetActiveTake(rendered);controller:tick()
  assert(r.TakeFX_GetOffline(source,0) and not r.TakeFX_GetOffline(r.GetTake(keeper,0),0))
  r.TakeFX_Show(source,0,1);r.SetActiveTake(rendered)
  report.source_chain_visible=r.TakeFX_GetChainVisible(source)
  assert(report.source_chain_visible>=0,'Source chain editor did not open')
  controller:tick()
  for i=0,3 do assert(r.TakeFX_GetOffline(source,i),'Inspecting the inactive chain restored source FX')end
  r.TakeFX_Show(source,0,0)
  check('Opening the inactive Source FX chain keeps every FX Offline while Rendered remains active')
  assert(T.restore(r,source)==3)
  r.TakeFX_Show(source,0,3);r.SetActiveTake(rendered)
  assert(r.TakeFX_GetFloatingWindow(source,0),'Source floating editor did not open')
  T.new(r,project):tick()
  for i=0,3 do assert(r.TakeFX_GetOffline(source,i),'An inactive floating editor prevented source Offline')end
  r.TakeFX_Show(source,0,2)
  check('Fresh companion offlines an inactive Source even with a floating plug-in editor open')
  local saved=dir..'/resource-test.rpp';r.Main_SaveProjectEx(project,saved,8);r.Main_openProject(saved)
  item=restored_item();source=r.GetTake(item,0);rendered=r.GetTake(item,1)
  report.reopened={offline=r.TakeFX_GetOffline(source,0),active_rendered=r.GetActiveTake(item)==rendered,
    items=r.CountMediaItems(0),takes=r.CountTakes(item),path=saved}
  assert(report.reopened.offline and report.reopened.active_rendered,'Save/reopen changed source resource or take selection')
  r.SetMediaItemSelected(item,true)
  assert(T.restore_selected(r)==3 and r.GetActiveTake(item)==source and r.TakeFX_GetOffline(source,2))
  assert(not r.TakeFX_GetEnabled(source,1) and math.abs(r.TakeFX_GetParam(source,0,0)-expected[0])<1e-7)
  check('Offline state survives save/reopen; explicit restore works with the companion closed')
  assert(r.Undo_DoUndo2(0)==1);item=restored_item()
  assert(r.GetActiveTake(item)==r.GetTake(item,1) and r.TakeFX_GetOffline(r.GetTake(item,0),0))
  assert(r.Undo_DoRedo2(0)==1);item=restored_item()
  assert(r.GetActiveTake(item)==r.GetTake(item,0) and not r.TakeFX_GetOffline(r.GetTake(item,0),0))
  check('Explicit restore Undo/Redo restores both take selection and FX resource state')
  source=r.GetTake(item,0);rendered=r.GetTake(item,1);r.SetActiveTake(rendered)
  assert(T.offline_project(r,r.EnumProjects(-1))==3)
  local chunk=C.read_item(r,item);local cut=assert(chunk:find('\nTAKE SEL\n',1,true))
  C.write_item(r,item,chunk:sub(1,cut-1)..'\n>\n') -- Remove Rendered while no controller is running.
  assert(r.CountTakes(item)==1 and r.TakeFX_GetOffline(r.GetTake(item,0),0))
  T.new(r,r.EnumProjects(-1)):tick();source=r.GetTake(item,0)
  assert(not r.TakeFX_GetOffline(source,0) and r.TakeFX_GetOffline(source,2))
  check('Fresh companion restores the sole Source after Rendered was removed while closed')
end,debug.traceback)
report.status=ok and'PASS'or'FAIL';report.error=err
U.write(host..'/take-fx.json',J.encode(report))
