local U=require('am.util');local J=require('am.json');local C=require('am.chunk');local L=require('am.loudness')
local Channels=require('am.render_channels');local Selection=require('am.channel_selection')
local M={}
function M.snapshot(r,path,macro,chain,source_gain,identity,range,settings)
  assert(L.same(identity,L.identity(r,path)),'Source changed; select it again before export')
  local snapshot={schema_version=1,path=path,identity=U.copy(identity),macro=U.copy(macro),chain=chain or '',
    source_gain_db=source_gain,range=range and U.copy(range) or J.null,fade_ms=settings.fade_ms,
    created_at=os.date('!%Y-%m-%dT%H:%M:%SZ'),monitor_gain_excluded=true}
  if next(settings.channel_selections or {})then
    local source=assert(r.PCM_Source_CreateFromFile(path),'Cannot decode selected input channels')
    local channels=r.GetMediaSourceNumChannels(source);r.PCM_Source_Destroy(source)
    local selection=Selection.get(settings,channels)
    if selection then
      local output=Selection.output(selection)
      snapshot.channel_mix={revision=selection.channels and 4 or 3,source_channels=channels,output_channels=output,mode=3,
        selection=U.copy(selection),fx_channels=math.ceil(output/2)*2}
      if output>2 then snapshot.chain='';snapshot.source_processing={fx_bypassed=true,bypass_reason='independent_microphones'}end
    end
  end
  return snapshot
end
function M.populate(r,snapshot,track)
  r.GetSetMediaTrackInfo_String(track,'P_NAME',snapshot.macro.name,true)
  r.SetMediaTrackInfo_Value(track,'D_VOL',U.gain(snapshot.macro.output_gain_db))
  local ret,chunk=r.GetTrackStateChunk(track,'',false);assert(ret)
  assert(r.SetTrackStateChunk(track,C.replace(chunk,C.fresh(Channels.chain(r,snapshot,false),r.genGuid)),false))
  if snapshot.channel_mix then r.SetMediaTrackInfo_Value(track,'I_NCHAN',Channels.width(snapshot))end
  r.TrackFX_Show(track,0,0)
  for i=0,r.TrackFX_GetCount(track)-1 do r.TrackFX_Show(track,i,2)end
  local item=assert(r.AddMediaItemToTrack(track));local take=assert(r.AddTakeToMediaItem(item))
  local source=assert(r.PCM_Source_CreateFromFile(snapshot.path),'Cannot decode source')
  local length,is_qn=r.GetMediaSourceLength(source)
  if is_qn or length<=0 then r.PCM_Source_Destroy(source);error('Not an audio source')end
  local t=snapshot.macro.source_transform;local a,b=0,length
  if snapshot.range~=J.null then a=snapshot.range[1];b=snapshot.range[2]end
  if t.reverse or snapshot.range~=J.null then
    local section=r.PCM_Source_CreateFromType('SECTION')
    if not section then r.PCM_Source_Destroy(source);error('Cannot create source section')end
    local configured=r.CF_PCM_Source_SetSectionInfo(section,source,a,b-a,t.reverse)
    r.PCM_Source_Destroy(source)
    if not configured then r.PCM_Source_Destroy(section);error('Cannot configure source section')end
    source=section
  end
  if not r.SetMediaItemTake_Source(take,source)then
    r.PCM_Source_Destroy(source);error('Cannot assign export media')
  end -- Take owns source from here.
  r.SetMediaItemTakeInfo_Value(take,'I_CHANMODE',Channels.take_mode(snapshot))
  r.SetMediaItemTakeInfo_Value(take,'D_VOL',U.gain(snapshot.source_gain_db))
  r.SetMediaItemTakeInfo_Value(take,'D_PLAYRATE',t.rate)
  r.SetMediaItemTakeInfo_Value(take,'D_PITCH',t.pitch_semitones)
  r.SetMediaItemTakeInfo_Value(take,'B_PPITCH',t.preserve_pitch and 1 or 0)
  r.SetMediaItemTakeInfo_Value(take,'I_PITCHMODE',snapshot.take_pitch_mode or -1)
  local duration=(b-a)/t.rate
  r.SetMediaItemInfo_Value(item,'D_POSITION',0);r.SetMediaItemInfo_Value(item,'D_LENGTH',duration)
  r.SetMediaItemInfo_Value(item,'D_FADEINLEN',snapshot.fade_ms/1000)
  r.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',snapshot.fade_ms/1000)
  r.SetMediaItemInfo_Value(item,'B_LOOPSRC',0)
  return item,duration
end
function M.render(r,snapshot,directory,stem,open_dialog)
  assert(not snapshot.macro.export.normalize_final or snapshot.macro.normalization.metric=='lufs_m_max',
    'Final export normalization supports LUFS only. Disable it to export with the Zwicker source gain.')
  assert(not stem:find('[/\\%z\r\n]') and stem~='' and not stem:find('%$'),'Use a plain output file name')
  r.RecursiveCreateDirectory(directory,0)
  local target=directory..'/'..stem..'.wav'
  assert(not r.file_exists(target),'Output exists; choose a new name')
  assert(L.same(snapshot.identity,L.identity(r,snapshot.path)),'Source changed after snapshot')
  local original=r.EnumProjects(-1);local project
  local ok,err=xpcall(function()
    r.Main_OnCommand(41929,0) -- New project tab (ignore default template)
    project=r.EnumProjects(-1);assert(project~=original,'Could not create export project')
    r.InsertTrackAtIndex(0,false);local track=r.GetTrack(project,0)
    local item,duration=M.populate(r,snapshot,track)
    local e=snapshot.macro.export
    -- REAPER 7.80's custom render bounds round-trip through a millisecond UI
    -- field when opening the render command. A project time selection preserves
    -- the exact rate-adjusted duration instead of truncating ~1 ms of audio.
    r.GetSet_LoopTimeRange2(project,true,false,0,duration,false)
    local values={RENDER_SETTINGS=0,RENDER_BOUNDSFLAG=2,RENDER_CHANNELS=Channels.output(snapshot),RENDER_SRATE=48000,
      RENDER_STARTPOS=0,RENDER_ENDPOS=duration,RENDER_TAILFLAG=4,RENDER_TAILMS=e.tail_seconds*1000,
      RENDER_ADDTOPROJ=0,RENDER_DITHER=0,
      RENDER_NORMALIZE=(e.normalize_final and 9 or 0)+(e.true_peak_limit and 192 or 0),
      RENDER_NORMALIZE_TARGET=U.gain(snapshot.macro.normalization.target_lufs),RENDER_BRICKWALL=U.gain(e.ceiling_dbtp)}
    for k,v in pairs(values)do r.GetSetProjectInfo(project,k,v,true)end
    r.GetSetProjectInfo_String(project,'RENDER_FILE',directory,true)
    r.GetSetProjectInfo_String(project,'RENDER_PATTERN',stem,true)
    r.GetSetProjectInfo_String(project,'RENDER_FORMAT','evaw',true)
    r.GetSetProjectInfo_String(project,'RENDER_FORMAT2','',true)
    r.Main_SaveProjectEx(project,directory..'/'..stem..'.rpp',8)
    assert(U.write(directory..'/'..stem..'.macro.json',J.encode(snapshot)))
    if open_dialog then r.Main_OnCommand(40015,0)
    else
      r.Main_OnCommand(42230,0) -- Render using latest settings, auto-close render dialog.
      assert(r.file_exists(target),'Render cancelled or output was not created; snapshot project is retained')
      r.Main_SaveProjectEx(project,directory..'/'..stem..'.rpp',8)
      r.Main_OnCommand(40860,0) -- Close saved scratch tab.
    end
  end,debug.traceback)
  if not open_dialog or not ok then r.SelectProjectInstance(original)end
  if not ok then error(err)end
  return target
end
return M
