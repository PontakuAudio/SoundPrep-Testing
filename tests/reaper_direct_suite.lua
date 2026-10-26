-- Shared real-API acceptance suite. OS-specific runners provide only host/observer options.
local M={}
function M.run(r,root,options)
options=options or {}
local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'))
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local C=require('am.chunk')
local I=require('am.insert');local E=require('am.export');local L=require('am.loudness');local M=require('am.model')
local Direct=require('am.render_item');local EXT=require('am.drop').EXT
local result={status='RUNNING',checks=J.array{},times=J.array{},drops=J.array{},render_calls=J.array{}}
local path=host.."/media 素材/test one's 音.wav";local directory=host..'/direct-media'
local chain='BYPASS 0 0 0\n<JS utility/volume_pan ""\n-12 0 0\n>\nWAK 0 0\n'
local lastSnapshot;local references={}
local function check(name)result.checks[#result.checks+1]=name;U.write(host..'/'..(options.report or 'direct-review')..'-progress.json',J.encode(result))end
local function preferences()
  local out={}
  for _,key in ipairs{'RECORD_PATH','RECORD_PATH_SECONDARY','OPENCOPY_CFGIDX','APPLYFX_FORMAT'}do out[key]=select(2,r.GetSetProjectInfo_String(0,key,'',false))end
  for _,key in ipairs{'applyfxtail','itemfxtail','showpeaksbuild'}do out[key]=r.SNM_GetIntConfigVar(key,-9999)end
  return out
end
local exec=r.ExecProcess;r.ExecProcess=function()error('A drop must not launch a process')end
local function run()
local ok,err=xpcall(function()
  result.driver=select(2,r.GetAudioDeviceInfo('MODE'))
  if options.driver then assert(result.driver==options.driver,'Unexpected test audio driver')end
  require('am.native').require(r)
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.RecursiveCreateDirectory(directory,0)
  r.InsertTrackAtIndex(0,false);local target=r.GetTrack(0,0)
  r.GetSetMediaTrackInfo_String(target,'P_NAME','Existing destination',true)
  r.SetTrackSelected(target,true)
  local keeper=r.AddMediaItemToTrack(target);r.AddTakeToMediaItem(keeper)
  r.SetMediaItemInfo_Value(keeper,'D_LENGTH',1);r.SetMediaItemSelected(keeper,true)
  local prefs=preferences();local project=r.EnumProjects(-1)
  if options.observe_progress then
    assert(r.AM_QuietItemAction,'Quiet-render API missing')
    assert(not r.AM_QuietItemAction(40015,project),'Quiet API accepted an unrelated action')
    assert((U.read(host..'/window-shows.txt') or ''):find('OBSERVER READY',1,true),'Visibility observer missing')
    U.write(host..'/window-shows.txt','')
  end
  for n=1,3 do
    local macro=M.effective(M.defaults(),n==1 and 'heavy' or 'dark');macro.output_gain_db=-3
    macro.source_transform.reverse=n==3
    local snapshot=E.snapshot(r,path,macro,chain,6,L.identity(r,path),n==3 and {.2,1.1} or nil,M.defaults().settings)
    Direct.stamp(r,snapshot);lastSnapshot=snapshot
    local foreground=r.JS_Window_GetForeground();local foregroundTitle=foreground and r.JS_Window_GetTitle(foreground);local began=r.time_precise()
    local output=Direct.render(r,snapshot,directory,'direct'..n)
    local elapsed=r.time_precise()-began
    local after=r.JS_Window_GetForeground()
    assert(after==foreground,'Direct render foreground changed: '..tostring(foregroundTitle)..' -> '..tostring(after and r.JS_Window_GetTitle(after)))
    assert(r.EnumProjects(-1)==project and not r.EnumProjects(1),'Direct render opened/switched a project tab')
    assert(r.IsMediaItemSelected(keeper) and r.IsTrackSelected(target) and r.CountTracks(0)==1)
    assert(U.equal(prefs,preferences()),'Render preferences were not restored')
    local src=r.PCM_Source_CreateFromFile(output)
    result.times[#result.times+1]={seconds=elapsed,length=r.GetMediaSourceLength(src),path=output};r.PCM_Source_Destroy(src)
    references[n]=snapshot
  end
  if options.observe_progress then
    local shows=U.read(host..'/window-shows.txt') or ''
    assert(not shows:find('Item: Apply track/take FX',1,true) and not shows:find('Building Peaks',1,true),'Short render flashed progress')
    check('Short native render and peak dialogs never became visible')
  end
  check('Direct FX, pitch/rate and cropped reverse; no process, tab or foreground change; preferences and selection restored')
  local raw=E.snapshot(r,path,M.effective(M.defaults(),nil),'',0,L.identity(r,path),nil,M.defaults().settings)
  local rawPath=Direct.render(r,raw,directory,'raw')
  local rawSource=r.PCM_Source_CreateFromFile(rawPath);assert(r.GetMediaSourceLength(rawSource)==2);r.PCM_Source_Destroy(rawSource)
  check('Raw with no FX produces a complete stereo render')
  local quiet=r.AM_QuietItemAction;r.AM_QuietItemAction=nil -- Older DLL fallback must retain cleanup on failure.
  local action=r.Main_OnCommandEx;r.Main_OnCommandEx=function(id,...)if id==40209 then error('Injected renderer failure')end;return action(id,...)end
  local good,why=pcall(Direct.render,r,lastSnapshot,directory,'failure');r.Main_OnCommandEx=action
  r.AM_QuietItemAction=quiet
  assert(not good and tostring(why):find('Injected renderer failure',1,true))
  assert(r.CountTracks(0)==1 and r.IsMediaItemSelected(keeper) and U.equal(prefs,preferences()))
  assert(not r.file_exists(directory..'/failure.wav'))
  check('Injected render failure removes scratch track and restores all changed preferences and selections')
  local rate48=J.encode(lastSnapshot.item_render)
  r.GetSetProjectInfo(project,'PROJECT_SRATE',44100,true);r.GetSetProjectInfo(project,'PROJECT_SRATE_USE',1,true)
  Direct.stamp(r,lastSnapshot);assert(J.encode(lastSnapshot.item_render)~=rate48,'Cache key ignored project sample rate')
  local ratePlan=I.prepare(r,lastSnapshot,2,false,directory,nil,Direct.render)
  local rateSource=r.PCM_Source_CreateFromFile(ratePlan.target)
  assert(r.GetMediaSourceSampleRate(rateSource)==44100);r.PCM_Source_Destroy(rateSource)
  r.GetSetProjectInfo(project,'PROJECT_SRATE_USE',0,true)
  r.SetEditCurPos(0,false,false);r.OnPlayButton()
  local playing=r.GetPlayStateEx(project);assert((playing&1)==1)
  local allowed=pcall(Direct.render,r,lastSnapshot,directory,'during-playback')
  assert(not allowed and r.GetPlayStateEx(project)==playing,'Renderer must reject processing during playback');r.OnStopButton()
  r.GetSetProjectInfo(project,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(project,'PROJECT_SRATE_USE',1,true)
  check('44100 Hz invalidates the cache and passes duration validation; renderer cannot interrupt playback')
  r.InsertTrackAtIndex(1,false);local input=r.GetTrack(0,1)
  C.write_item(r,keeper,C.read_item(r,keeper))
  assert(r.SetTrackStateChunk(input,C.replace(C.read_track(r,input),C.pdc_options(chain,'PDC_OPTIONS 2',true)),false))
  local macro=M.effective(M.defaults(),'heavy');macro.output_gain_db=-3
  local state={project=tostring(project),session='direct',path=path,identity=L.identity(r,path),macro=macro,defer_items=true,
    settings=M.defaults().settings,data=host..'/drop-data',input=r.GetTrackGUID(input),track=r.GetTrackGUID(input)}
  local targetGuid=r.GetTrackGUID(target)
  r.Undo_OnStateChangeEx2(project,'Integration starting point',-1,-1)
  local savedContext,savedResult=r.AM_DropContext,r.AM_DropResult
  local function drop(count,origin,handles,mode)
    local manual=mode=='manual'
    for i=0,r.CountTracks(project)-1 do local t=r.GetTrack(project,i);if r.GetTrackGUID(t)==targetGuid then target=t end end
    state.settings.insert_handles=handles~=false
    state.settings.auto_render_drops=not manual
    require('am.media_explorer').new(r):set_transform(state.macro.source_transform)
    r.SetExtState(EXT,'state',J.encode(state),false)
    local ctx={id=#result.drops+1,origin=origin or 'list',path=path,paths=J.array{},items=J.array{},
      preview={path=path,mode=384,start=.1,['end']=.55}}
    for _=1,count do ctx.paths[#ctx.paths+1]=path end
    if mode then r.SetEditCurPos(0,false,false);r.OnPlayButton()end
    if mode=='paused'then r.OnPauseButtonEx(project);assert(r.GetPlayStateEx(project)==2)end
    local transportBefore=r.GetPlayStateEx(project)
    local function process(phase)
      ctx.phase=phase;local success
      r.AM_DropContext=function()return J.encode(ctx)end;r.AM_DropResult=function(value)success=value end
      dofile(root..'/internal/Process waveform drop.lua');assert(success,r.GetExtState(EXT,'message'))
    end
    -- Match posted WM_DROPFILES: prepare is outside the native undo block.
    local before=r.CountMediaItems(project);local began=r.time_precise();local renderCalls=0;local render=Direct.render
    Direct.render=function(...)renderCalls=renderCalls+1;return render(...)end
    process('prepare')
    assert(r.CountTracks(project)==2 and r.CountMediaItems(project)==before,'Prepare changed project contents')
    assert(r.GetPlayStateEx(project)==transportBefore,'Capturing a drag stopped playback')
    r.Undo_BeginBlock2(project);local items={}
    for n=1,count do
      local item=r.AddMediaItemToTrack(target);local take=r.AddTakeToMediaItem(item)
      r.SetMediaItemTake_Source(take,r.PCM_Source_CreateFromFile(path));r.SetMediaItemInfo_Value(item,'D_POSITION',n*5)
      r.SetMediaItemInfo_Value(item,'D_LENGTH',2)
      ctx.items[#ctx.items+1]=select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false));items[#items+1]=item
    end
    process('finish');r.Undo_EndBlock2(project,'Insert Audition Macro',-1)
    Direct.render=render;result.render_calls[#result.render_calls+1]=renderCalls
    result.drops[#result.drops+1]=r.time_precise()-began
    if manual then
      for _,item in ipairs(items)do assert(r.CountTakes(item)==1 and r.TakeFX_GetCount(r.GetTake(item,0))>0,'No immediately playable Source + FX')end
      assert((r.GetPlayStateEx(project)&1)==1,'Drop interrupted playback')
      local definition=M.defaults();definition.settings.auto_render_drops=false
      local consumer=require('am.drop_pending').new(r,{project=project,session='direct',definition=definition})
      consumer:tick();assert(#consumer.jobs==1 and r.CountTakes(items[1])==1,'Playback drop rendered too early')
      r.SetMediaItemInfo_Value(items[1],'D_POSITION',42)
      r.SetMediaItemInfo_Value(items[2],'D_LENGTH',.25);r.DeleteTrackMediaItem(target,items[3])
      r.OnStopButton();consumer:tick()
      assert(r.CountTakes(items[1])==1,'Manual mode rendered automatically on Stop')
      definition.settings.auto_render_drops=true;consumer:tick()
      assert(r.CountTakes(items[1])==2 and r.GetMediaItemInfo_Value(items[1],'D_POSITION')==42,'Moved item lost or not rendered')
      assert(r.CountTakes(items[2])==1 and r.GetMediaItemInfo_Value(items[2],'D_LENGTH')==.25 and r.CountMediaItems(project)==before+2)
      check('Manual drops keep playing; later rendering preserves moves and skips trimmed/deleted items')
      return
    elseif mode then
      assert(r.GetExtState(EXT,'queue')=='','Automatic playback drop left a deferred render')
      if mode=='cached'then
        assert(r.GetPlayStateEx(project)==transportBefore and renderCalls==0,'Cached drop stopped playback or re-rendered')
      else
        assert(r.GetPlayStateEx(project)==0 and renderCalls>0,'Uncached drop did not stop and finish rendering')
      end
    end
    for _,item in ipairs(items)do
      assert(r.CountTakes(item)==2 and r.GetActiveTake(item)==r.GetTake(item,1))
      assert(r.TakeFX_GetCount(r.GetTake(item,0))>0 and r.TakeFX_GetCount(r.GetTake(item,1))==0)
      local takeFX=C.block(C.read_item(r,item),'TAKEFX')
      assert(not takeFX:match('[\r\n]%s*PDC_OPTIONS 2%s*[\r\n]'),'Preview-only PDC policy leaked into source take')
      local take=r.GetTake(item,1);local source=r.GetMediaItemTake_Source(take)
      local editable=r.GetTake(item,0);local original=r.GetMediaItemTake_Source(editable)
      assert(math.abs(r.GetMediaSourceLength(original)-2)<1/48000,'Source + FX was destructively cropped')
      local expectedOffset=origin=='waveform' and (state.macro.source_transform.reverse and .9 or .2) or 0
      assert(math.abs(r.GetMediaItemTakeInfo_Value(editable,'D_STARTOFFS')-expectedOffset)<1e-8,'Source take does not align with rendered range')
      assert(r.file_exists(r.GetMediaSourceFileName(source,'')))
      if origin=='waveform'then
        assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-.9/.72)<1e-8)
        if handles==false then assert(math.abs(r.GetMediaSourceLength(source)-.9/.72)<1/48000)end
      end
      -- Switching takes and restoring both edges must expose the full source.
      local duration=r.GetMediaItemInfo_Value(item,'D_LENGTH')
      r.SetActiveTake(editable);r.SetMediaItemTakeInfo_Value(editable,'D_STARTOFFS',0)
      r.SetMediaItemInfo_Value(item,'D_LENGTH',2/state.macro.source_transform.rate)
      assert(r.GetMediaSourceLength(r.GetMediaItemTake_Source(r.GetActiveTake(item)))==2 and r.GetMediaItemInfo_Value(item,'B_LOOPSRC')==0)
      r.SetMediaItemTakeInfo_Value(editable,'D_STARTOFFS',expectedOffset);r.SetMediaItemInfo_Value(item,'D_LENGTH',duration);r.SetActiveTake(take)
    end
    r.Undo_DoUndo2(project);assert(r.CountMediaItems(project)==before,'One Undo did not remove the whole drop')
    r.Undo_DoRedo2(project);assert(r.CountMediaItems(project)==before+count and r.CountTracks(project)==2,'Redo leaked scratch tracks')
    if mode=='cached'then r.OnStopButtonEx(project)end
    return items
  end
  drop(1);drop(2);drop(1,'waveform',true);drop(1,'waveform',false)
  assert(result.render_calls[1]==1 and result.render_calls[2]==0 and result.render_calls[3]==0 and result.render_calls[4]==1,'Cache did not reuse full-source media')
  check('Cold list drop, cached multi-file list drop, full handles and cropped waveform drops produce two takes with single Undo/Redo')
  state.macro.source_transform.reverse=true;drop(1,'waveform',false)
  state.macro.output_gain_db=-3.5 -- Force an uncached render for the playback path.
  drop(1,'waveform',false,true)
  drop(1,'waveform',false,'cached')
  check('Uncached playback waveform drop stops and renders immediately; cached repeat keeps playing; each has one Undo/Redo')
  state.macro.source_transform.reverse=false
  state.macro.output_gain_db=-4;drop(2,nil,nil,true)
  drop(2,nil,nil,'cached')
  state.macro.output_gain_db=-4.5;drop(1,nil,nil,'paused')
  check('Playing multi-file and paused drops complete both takes during insertion; cached batches preserve playback')
  state.macro.output_gain_db=-5;drop(3,nil,nil,'manual')
  r.AM_DropContext,r.AM_DropResult=savedContext,savedResult
  assert(U.equal(prefs,preferences()))
  for n,snapshot in ipairs(references)do E.render(r,snapshot,directory,'reference'..n,false)end
  local saved=directory..'/takes.rpp';r.Main_SaveProjectEx(project,saved,8);r.Main_openProject(saved)
  local restored=0
  for n=0,r.CountMediaItems(0)-1 do
    local item=r.GetMediaItem(0,n)
    if r.CountTakes(item)==2 then
      local take=r.GetTake(item,0);local source=r.GetMediaItemTake_Source(take)
      assert(math.abs(r.GetMediaSourceLength(source)-2)<1/48000,'Save/reopen lost full original source')
      assert(r.TakeFX_GetCount(take)>0 and r.GetActiveTake(item)==r.GetTake(item,1))
      local plan=J.decode(select(2,r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro','',false)))
      local snapshot=J.decode(assert(U.read(plan.snapshot)))
      local expected=I.layout(2,plan.range,snapshot.macro.source_transform,true).offset*snapshot.macro.source_transform.rate
      assert(math.abs(r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')-expected)<1e-8,'Save/reopen lost source offset')
      restored=restored+1
    end
  end
  assert(restored>=7);check('Project save/reopen retains full original sources, FX, aligned ranges and active Rendered takes')
end,debug.traceback)
r.ExecProcess=exec
result.status=ok and 'PASS' or 'FAIL';result.error=err
assert(U.write(host..'/'..(options.report or 'direct-review')..'.json',J.encode(result)))
end
r.OpenMediaExplorer(path,false) -- Exercise the same native controls on both OSes.
local explorer=require('am.media_explorer').new(r)
local waiting=r.time_precise()
local function ready()
  local audio=select(2,r.GetAudioDeviceInfo('MODE'))~='' or r.time_precise()-waiting>10
  if audio and explorer:control(1454)then run()else r.defer(ready)end
end
r.defer(ready)
end
return M
