-- Explicit baking of editable drops, including after trims/FX edits and after
-- restarting the companion. Never opens a second project or launches a host.
local U=require('am.util');local J=require('am.json');local C=require('am.chunk')
local I=require('am.insert');local L=require('am.loudness');local D=require('am.render_item')
local Channels=require('am.render_channels')
local M={}
function M.recipe(r,item,plan)
  local snapshot=J.decode(assert(U.read(plan.snapshot),'Drop snapshot is missing'))
  local mix=Channels.validate(snapshot)
  local take=assert(r.GetTake(item,0));local source=r.GetMediaItemTake_Source(take);local reverse=false
  while true do
    local ok,_,_,rev=r.PCM_Source_GetSectionInfo(source);if ok and rev then reverse=not reverse end
    local parent=r.GetMediaSourceParent(source);if not parent then break end;source=parent
  end
  local path=r.GetMediaSourceFileName(source,'')
  assert(U.path_equal(path,plan.original),'The drop source was replaced')
  if snapshot.channel_mix then
    assert(L.same(snapshot.identity,L.identity(r,path)) and
      r.GetMediaSourceNumChannels(source)==snapshot.channel_mix.source_channels,
      'Multichannel source changed; drop the file again to capture its channel routing')
  end
  assert(r.GetMediaItemTakeInfo_Value(take,'D_PAN')==0 and r.GetMediaItemTakeInfo_Value(take,'I_CHANMODE')==Channels.take_mode(snapshot),
    'Restore the captured take pan/channel mode before rendering this drop')
  local length=r.GetMediaSourceLength(source);local rate=r.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE')
  local offset=r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS');local duration=r.GetMediaItemInfo_Value(item,'D_LENGTH')
  assert(rate>0 and duration>0,'Invalid drop length or rate')
  local a,b=offset,offset+duration*rate
  if reverse then a,b=length-b,length-a end
  local handles=plan.handles or a<0 or b>length
  snapshot.range={math.max(0,a),math.min(length,b)}
  if snapshot.range[2]<=snapshot.range[1]then snapshot.range=J.null;handles=true end
  if I.processing_key(r,item)~=plan.processing_key then
    -- The take already contains the Macro output-gain stage. Retain the
    -- current edited chain without appending that gain a second time.
    snapshot.chain=C.portable(C.block(C.read_item(r,item),'TAKEFX') or '')
    snapshot.macro.output_gain_db=0
    if mix then
      -- The edited take already includes the frozen source matrix and output
      -- gain. Keep its current width without prepending either stage again.
      mix.chain_applied=true
      mix.fx_channels=math.max(2,math.ceil(r.GetMediaItemTakeInfo_Value(take,'I_TAKEFX_NCH')/2)*2)
      Channels.validate(snapshot)
    end
    snapshot.macro.source_transform={reverse=reverse,rate=rate,
      pitch_semitones=r.GetMediaItemTakeInfo_Value(take,'D_PITCH'),
      preserve_pitch=r.GetMediaItemTakeInfo_Value(take,'B_PPITCH')~=0}
    local gain=r.GetMediaItemTakeInfo_Value(take,'D_VOL');assert(gain>=0,'Invalid take gain')
    snapshot.source_gain_db=gain>0 and 20*math.log(gain,10) or -300
    snapshot.take_pitch_mode=r.GetMediaItemTakeInfo_Value(take,'I_PITCHMODE')
    snapshot.fade_ms=0 -- Shared item fades remain editable and apply to both takes.
  end
  snapshot.identity=assert(L.identity(r,path));D.stamp(r,snapshot)
  return snapshot,length,handles,offset/rate,duration
end
function M.selected(r)
  local project=r.EnumProjects(-1)
  assert(r.GetPlayStateEx(project)==0,'Stop project playback/recording before rendering selected drops')
  -- Remember the consumer before a long synchronous render can age its
  -- heartbeat. The companion resumes queued peaks when the render returns.
  local heartbeat=tonumber(r.GetExtState('AuditionMacro.v1','heartbeat'))
  local defer_peaks=heartbeat and r.time_precise()-heartbeat<3
  local entries={}
  for n=0,r.CountSelectedMediaItems(project)-1 do
    local item=r.GetSelectedMediaItem(project,n)
    if r.CountTakes(item)==1 then
      local text=select(2,r.GetSetMediaItemTakeInfo_String(r.GetTake(item,0),'P_EXT:AuditionMacro','',false))
      local ok,plan=pcall(J.decode,text)
      if ok and plan.pending and plan.snapshot then
        local snapshot,length,handles,offset,duration=M.recipe(r,item,plan)
        entries[#entries+1]={item=item,snapshot=snapshot,length=length,handles=handles,offset=offset,duration=duration,
          directory=plan.snapshot:match('^(.*)[/\\]'),chunk=C.read_item(r,item)}
      end
    end
  end
  assert(#entries>0,'Select Source + FX drops to render')
  r.Undo_BeginBlock2(project)
  local ok,err=xpcall(function()
    local items={}
    for _,e in ipairs(entries)do
      local plan=I.prepare(r,e.snapshot,e.length,e.handles,e.directory,nil,D.render)
      -- A moved/trimmed item keeps its position, length and source alignment.
      plan.duration=e.duration;if e.handles then plan.offset=e.offset end
      I.add_rendered(r,project,e.item,plan);items[#items+1]=e.item
    end
    I.build_missing_peaks(r,project,items,defer_peaks)
  end,debug.traceback)
  if not ok then for _,e in ipairs(entries)do if r.ValidatePtr2(project,e.item,'MediaItem*')then C.write_item(r,e.item,e.chunk)end end end
  r.Undo_EndBlock2(project,ok and 'Render selected SoundPrep drops' or 'SoundPrep render failed',-1)
  assert(ok,err)
  return #entries
end
return M
