-- Real native workers and REAPER items, with injected native drag callbacks.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local Model=require('am.model');local L=require('am.loudness')
local A=require('am.analysis_policy');local D=require('am.drop_analysis');local I=require('am.insert');local C=require('am.chunk')
local Explorer=require('am.media_explorer');local EXT=require('am.drop').EXT
local saved={context=r.AM_DropContext,result=r.AM_DropResult,explorer=Explorer.new,read=U.read}
local report={status='RUNNING',cases=J.array{},host_version=r.GetAppVersion()}
local project=r.EnumProjects(-1);local data=host..'/drop-analysis-data';local context,accepted,current,index,done
local cases={{name='pending waveform',borrow=true,range=true,move=true},
  {name='selection cancels borrowed worker',borrow=true,cancel=true},
  {name='unmeasured multi-file list',list=true,multi=true},
  {name='Zwicker pending',zwicker=true},
  {name='processed source during playback',multi=true,downmix=true,play=true},
  {name='Undo before analysis completes',borrow=true,undo=true}}
local function finish(ok,err)
  if done then return end;done=true;r.OnStopButtonEx(project)
  if current then current.app.loudness:close();current.manager:close()end
  r.AM_DropContext,r.AM_DropResult,Explorer.new,U.read=saved.context,saved.result,saved.explorer,saved.read
  for _,key in ipairs{'state','prepared','captured','analysis_queue','queue','busy','preview_stop','message'}do r.DeleteExtState(EXT,key,false)end
  report.status=ok and 'PASS'or 'FAIL';report.error=err
  assert(U.write(host..'/drop-analysis.json',J.encode(report)))
end
local function fixture(channels)
  local frames={}
  for i=0,23999 do
    local frame={};for ch=1,channels do frame[ch]=string.pack('<i2',math.floor(math.sin(i*2*math.pi*997/48000)*1200/ch))end
    frames[#frames+1]=table.concat(frame)
  end
  local samples=table.concat(frames);local path=data..'/'..channels..'ch.wav'
  assert(U.write(path,'RIFF'..string.pack('<I4',36+#samples)..'WAVEfmt '..
    string.pack('<I4I2I2I4I4I2I2',16,1,channels,48000,48000*channels*2,channels*2,16)..'data'..string.pack('<I4',#samples)..samples))
  return path
end
local function process(phase)
  context.phase=phase;accepted=nil;dofile(root..'/internal/Process waveform drop.lua')
  assert(accepted,r.GetExtState(EXT,'message'))
end
local function start_case()
  index=(index or 0)+1;local case=cases[index];if not case then finish(true);return end
  for i=r.CountMediaItems(project)-1,0,-1 do local item=r.GetMediaItem(project,i);r.DeleteTrackMediaItem(r.GetMediaItem_Track(item),item)end
  for _,key in ipairs{'state','prepared','captured','analysis_queue','queue','message'}do r.DeleteExtState(EXT,key,false)end
  r.Undo_OnStateChange2(project,'Pending analysis case setup')
  local input=r.GetTrack(project,0);local target=r.GetTrack(project,1);r.SetOnlyTrackSelected(target)
  local definition=Model.defaults();definition.raw.normalization.enabled=true;definition.raw.normalization.target_lufs=-18
  definition.settings.cache_directory=data..'/case-'..index;definition.settings.preview_downmix=case.downmix or false
  if case.zwicker then definition.raw.normalization.metric='zwicker_max' end
  local paths=case.list and {data..'/2ch.wav',data..'/4ch.wav'}or {data..(case.multi and '/4ch.wav'or '/2ch.wav')}
  local macro=Model.effective(definition,nil);local first=assert(L.identity(r,paths[1]))
  local session='drop-analysis-'..index
  local app={project=project,session=session,root=root,definition=definition,message=''}
  app.loudness=L.new(r,root,data,definition.settings,session)
  if case.borrow then app.loudness:request(first,false,A.resolve(paths[1],2,definition.settings,macro.normalization))end
  local state={project=tostring(project),session=session,path=paths[1],identity=first,macro=macro,
    settings=definition.settings,data=data,input=r.GetTrackGUID(input),defer_items=true,defer_analysis=true,
    analyzer_key=L.ANALYZER_KEY,analysis_job=U.copy(app.loudness.active)}
  r.SetExtState(EXT,'state',J.encode(state),false)
  context={id=index,origin=case.range and 'waveform'or 'list',path=paths[1],paths=J.array(paths),
    preview={path=paths[1],mode=256,start=.2,['end']=.8}}
  -- Deterministically force the narrow pending window without replacing the
  -- native worker or its numeric result. Release it after native insertion.
  U.read=function(path)if state.analysis_job and path==state.analysis_job.result then return end;return saved.read(path)end
  process('capture');process('prepare_captured')
  local prepared=J.decode(r.GetExtState(EXT,'prepared'));assert(prepared.analysis_pending)
  r.Undo_BeginBlock2(project);r.SetEditCurPos(2,false,false);context.items=J.array{}
  for _,path in ipairs(paths)do
    local result=case.range and r.InsertMediaSection(path,0,.2,.8,0)or r.InsertMedia(path,0);assert(result==1)
    local item=r.GetMediaItem(project,r.CountMediaItems(project)-1)
    context.items[#context.items+1]=select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))
  end
  process('finish');r.Undo_EndBlock2(project,'Pending SoundPrep test drop',-1)
  U.read=saved.read
  assert(r.GetExtState(EXT,'analysis_queue')~='')
  for i=0,r.CountMediaItems(project)-1 do assert(r.GetMediaItemInfo_Value(r.GetMediaItem(project,i),'B_MUTE')==1)end
  if case.move then r.SetMediaItemInfo_Value(r.GetMediaItem(project,0),'D_POSITION',4)end
  if case.cancel then app.loudness:cancel_active()end
  if case.play then r.SetEditCurPos(0,false,false);r.OnPlayButtonEx(project);assert(r.GetPlayStateEx(project)==1)end
  if case.undo then assert(r.Undo_DoUndo2(project)==1 and r.CountMediaItems(project)==0)end
  -- Subsequent live preferences cannot alter the captured target.
  definition.raw.normalization.target_lufs=-40
  current={case=case,app=app,manager=D.new(r,app),prepared=prepared,started=r.time_precise(),paths=paths}
end
local function verify()
  local value=current;local case=value.case
  if case.undo then
    assert(r.CountMediaItems(project)==0,'Pending analysis recreated an undone drop')
  else
    assert(not value.app.message:find('stopped:',1,true),value.app.message)
    local cache=setmetatable({data=data,settings=value.prepared.settings,analyzer_key=L.ANALYZER_KEY,memory={},keys={}},L)
    for i,entry in ipairs(value.prepared.entries)do
      local item=r.GetMediaItem(project,i-1);local snapshot=entry.snapshot
      local measurement=assert(cache:get(snapshot.identity,snapshot.analysis),'No completed native measurement')
      local gain=L.gain(snapshot.macro,measurement)
      assert(r.GetMediaItemInfo_Value(item,'B_MUTE')==0,'Completed item remained muted')
      if case.downmix then
        assert(r.TakeFX_GetCount(r.GetActiveTake(item))>0,'Deferred channel processing was omitted')
        local queued=J.decode(r.GetExtState(EXT,'queue'));assert(#queued==1)
        assert(queued[1].entries[1].guard==I.render_guard(C.read_item(r,item)),'Unmute invalidated the deferred render guard')
      else
        assert(math.abs(r.GetMediaItemInfo_Value(item,'D_VOL')-U.gain(gain))<1e-10,'Frozen normalization gain was not applied')
        assert(r.CountTakes(item)==1 and r.TakeFX_GetCount(r.GetActiveTake(item))==0)
      end
      if case.range then assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-.3)<1e-9)end
      if case.move then assert(r.GetMediaItemInfo_Value(item,'D_POSITION')==4)end
    end
    if case.play then assert(r.GetPlayStateEx(project)==1,'Late normalization stopped playback')end
    if case.move then
      assert(r.Undo_DoUndo2(project)==1 and r.CountMediaItems(project)==1,'Completion Undo removed the native insertion')
      assert(r.GetMediaItemInfo_Value(r.GetMediaItem(project,0),'B_MUTE')==1,'Completion Undo did not restore the waiting item')
      assert(r.Undo_DoUndo2(project)==1 and r.CountMediaItems(project)==0,'Insertion Undo did not remove the drop')
      assert(r.Undo_DoRedo2(project)==1 and r.Undo_DoRedo2(project)==1 and r.CountMediaItems(project)==1)
      assert(r.GetMediaItemInfo_Value(r.GetMediaItem(project,0),'B_MUTE')==0,'Redo did not restore the completed drop')
    end
  end
  report.cases[#report.cases+1]={name=case.name,seconds=r.time_precise()-value.started,items=r.CountMediaItems(project)}
  value.app.loudness:close();value.manager:close();current=nil;r.OnStopButtonEx(project)
end
local function tick()
  local ok,err=xpcall(function()
    if not current then start_case();if done then return end end
    assert(r.time_precise()-current.started<45,'Analysis completion timed out')
    current.app.loudness:poll();current.manager:tick()
    if #current.manager.jobs==0 then verify()end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
local ok,err=xpcall(function()
  for _,name in ipairs{'AM_AnalysisStart','AM_AnalysisCancel','AM_DropContext','AM_DropResult'}do assert(r.APIExists(name),'Missing '..name)end
  r.RecursiveCreateDirectory(data,0);fixture(2);fixture(4)
  r.AM_DropContext=function()return J.encode(context)end;r.AM_DropResult=function(value)accepted=value end
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  r.InsertTrackAtIndex(0,false);r.InsertTrackAtIndex(1,false)
  for i=0,1 do r.SetMediaTrackInfo_Value(r.GetTrack(project,i),'B_MAINSEND',0)end
  r.Undo_OnStateChange2(project,'Pending analysis test setup')
end,debug.traceback)
if not ok then finish(false,err)else r.defer(tick)end
