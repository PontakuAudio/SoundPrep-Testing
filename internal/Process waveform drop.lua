-- @description SoundPrep - internal Media Explorer drop transaction (not a user action)
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]internal[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local r=reaper;local J=require('am.json');local U=require('am.util');local L=require('am.loudness')
local Selection=require('am.channel_selection');local C=require('am.chunk');local E=require('am.export');local Mix=require('am.channel_mix');local EXT=require('am.drop').EXT
local Analysis=require('am.analysis_policy')
if not r.APIExists('AM_DropContext') or r.AM_DropContext()==''then return end
local ctx=J.decode(r.AM_DropContext())
local function reject(message)error({expected_drop_rejection=true,message=message},0)end
local function reject_analysis(path,status,detail)
  local name=U.basename(path);local message
  if status=='pending'then message='Analysis pending: '..name..'. Wait for completion, then drag again.'
  elseif status=='error'then
    detail=tostring(detail or 'Analysis failed'):gsub('[\r\n]+',' ')
    message='Analysis failed: '..name..' — '..detail..'. Check Edit settings, then use Analyse / refresh and drag again.'
  elseif status=='cancelled'then message='Analysis required: '..name..' was cancelled. Use Edit > Analyse / refresh, then drag again.'
  else message='Analysis required: '..name..'. Use Edit > Analyse / refresh, then drag again.'end
  reject(message)
end
local function track(guid)
  for i=0,r.CountTracks(0)-1 do local t=r.GetTrack(0,i);if r.GetTrackGUID(t)==guid then return t end end
end
local function prepare(project,payload)
  local began=r.time_precise()
  local analysis_pending=false
  for _,entry in ipairs(payload.entries)do if entry.analysis_pending then analysis_pending=true;break end end
  local state,entries=payload.state,payload.entries
  local _,filename=r.EnumProjects(-1,'')
  local directory=filename~='' and (filename:match('^(.*)[/\\]')..'/Audition Macro Media') or (state.data..'/inserted-media')
  -- Capture never changes project contents. Scratch-track rendering belongs
  -- inside the destination's existing Undo block, after native insertion.
  r.SetExtState(EXT,'prepared',J.encode{transaction=ctx.id,project=tostring(project),entries=entries,
    directory=directory,handles=state.settings.insert_handles,input=state.input,began=began,
    session=state.session,defer_items=state.defer_items,auto_render=state.settings.auto_render_drops,
    analysis_pending=analysis_pending,analysis_job=state.analysis_job,settings=state.settings,data=state.data,analyzer_key=state.analyzer_key},false)
end
local ok,err=xpcall(function()
  local project=r.EnumProjects(-1)
  if ctx.phase=='prepare' or ctx.phase=='capture'then
    r.DeleteExtState(EXT,'prepared',false)
    local state=J.decode(r.GetExtState(EXT,'state'))
    -- The native modal drag suspends defer. Read payload identities and waveform
    -- range now, not from a potentially old selection heartbeat.
    assert(state.project==tostring(project),'SoundPrep is not active in this project')
    local is_list=ctx.origin=='list';local paths=ctx.paths or {ctx.path}
    local macro=U.copy(state.macro)
    -- Native pitch/rate might have changed immediately before entering the drag.
    local explorer=require('am.media_explorer').new(r)
    local native=explorer:transform();local tempo=explorer:tempo_factor()
    for k,v in pairs(native)do
      if k=='preserve_pitch' or U.finite(v) and (k=='rate' and v>=.1 and v<=4 or k=='pitch_semitones' and v>=-24 and v<=24)then
        macro.source_transform[k]=k=='rate' and v*tempo or v
      end
    end
    local chain='';local macro_channels=2
    if state.track then
      local t=assert(track(state.track),'Macro track was removed')
      macro_channels=r.GetMediaTrackInfo_Value(t,'I_NCHAN')
      local fx=C.block(C.read_track(r,t),'FXCHAIN')
      -- Strip the preview-only live PDC policy, restoring the saved chain's
      -- policy just as bank:chain() does for explicit exports.
      chain=fx and C.pdc_options(fx,state.pdc_options,true) or ''
    end
    local cache=setmetatable({data=state.data,settings=state.settings,analyzer_key=state.analyzer_key,memory={},keys={}},L)
    local entries={}
    -- Validate the complete batch before any render, so a missing measurement
    -- never inserts a mixture of normalized and unnormalized files.
    for _,path in ipairs(paths)do
      local identity=L.identity(r,path)
      if not identity then reject('Cannot read dropped file: '..U.basename(path))end
      if not is_list then
        -- The native payload can already show a new waveform while the
        -- companion still publishes the previous selection's heartbeat.
        assert(state.defer_analysis or U.path_equal(path,state.path),'Select and audition this file before dragging')
        if U.path_equal(path,state.path)then assert(L.same(state.identity,identity),'Source changed; audition again before dragging')end
      end
      local source=r.PCM_Source_CreateFromFile(path)
      if not source then reject('Cannot decode dropped file: '..U.basename(path))end
      local length,qn=r.GetMediaSourceLength(source)
      local channels=r.GetMediaSourceNumChannels(source);local kind=r.GetMediaSourceType(source,'');r.PCM_Source_Destroy(source)
      if qn or not U.finite(length) or length<=0 or not U.finite(channels) or channels%1~=0 or channels<1 or channels>128 or
        kind=='MIDI' or kind=='VIDEO' or kind=='RPP_PROJECT'then
        reject('Unsupported audio source: '..U.basename(path)..'. Drops require 1–128 audio channels.')
      end
      local range=require('am.drop_range').read(r,ctx,path,length)
      local analysis,analysis_reason=Analysis.resolve(path,channels,state.settings,macro.normalization)
      if analysis_reason then reject(U.basename(path)..': '..analysis_reason)end
      local entry_macro=U.copy(macro);local entry_chain=chain
      local channel_mix,source_processing,measurement,analysis_pending
      local selection=Selection.get(state.settings,channels)
      if channels>2 or selection then
        local mode,reason=selection and 3 or 0
        if not selection and state.settings.preview_downmix then mode,reason=Mix.resolve(path,channels,state.settings.preview_downmix_mode)end
        if not mode then reject(U.basename(path)..': '..reason)end
        local output=selection and Selection.output(selection)or mode==0 and channels or 2
        local bypass=mode==0 or output>2
        local width=math.max(2,math.ceil(output/2)*2,bypass and 2 or macro_channels)
        channel_mix={revision=selection and (selection.channels and 4 or 3)or 1,selection=U.copy(selection),source_channels=channels,output_channels=output,mode=mode,
          preference=state.settings.preview_downmix_mode or 'auto',fx_channels=width}
        source_processing={fx_bypassed=bypass,bypass_reason=bypass and (selection and 'independent_microphones' or 'multichannel_downmix_off')or nil}
        -- Keep original channels independent of stereo Macro FX, just as the
        -- audition does. Source transforms and the Macro output gain remain.
        if bypass then entry_chain=''end
      end
      measurement=L.for_analysis(state.measurement,identity,state.analyzer_key,analysis)
      if not measurement and state.analyzer_key then
        local fallback=not macro.normalization.enabled and Analysis.resolve(path,channels,state.settings,macro.normalization,true)or nil
        measurement=cache:get(identity,analysis,fallback)
      end
      if entry_macro.normalization.enabled or entry_macro.source_peak_guard.enabled then
        if not measurement then
          local status,detail
          measurement,status,detail=L.completed_result(state.analysis_job,identity,state.analyzer_key,analysis)
          if not measurement then
            if status=='unmeasured' and L.same(identity,state.analysis_identity) and
              Analysis.same(state.analysis_spec,analysis) and state.analysis_error then
              status,detail='error',state.analysis_error
            end
            if state.defer_analysis and (status=='pending' or status=='unmeasured' or status=='cancelled')then
              analysis_pending=true
            else reject_analysis(path,status,detail)end
          end
        end
      end
      local snapshot=E.snapshot(r,path,entry_macro,entry_chain,L.gain(entry_macro,measurement),identity,range,state.settings)
      snapshot.analysis=analysis and U.copy(analysis)
      snapshot.channel_mix=channel_mix;snapshot.source_processing=source_processing
      require('am.render_item').stamp(r,snapshot)
      entries[#entries+1]={snapshot=snapshot,length=length,analysis_pending=analysis_pending}
    end
    local payload={transaction=ctx.id,project=tostring(project),state=state,entries=entries}
    if ctx.phase=='capture'then r.SetExtState(EXT,'captured',J.encode(payload),false)
    else prepare(project,payload)end
  elseif ctx.phase=='prepare_captured'then
    local payload=J.decode(r.GetExtState(EXT,'captured'))
    assert(payload.transaction==ctx.id and payload.project==tostring(project),'Stale drag snapshot')
    prepare(project,payload)
  elseif ctx.phase=='finish'then
    local prepared=J.decode(r.GetExtState(EXT,'prepared'))
    assert(prepared.transaction==ctx.id and prepared.project==tostring(project),'Stale drop transaction')
    if prepared.analysis_pending then
      require('am.drop_analysis').enqueue(r,project,prepared,ctx.items)
    else require('am.drop_transaction').finish(r,project,prepared,ctx.items)end
    r.DeleteExtState(EXT,'prepared',false)
    if prepared.began then r.SetExtState(EXT,'last_drop_seconds',tostring(r.time_precise()-prepared.began),false)end
    -- Only an accepted insertion stops auditioning; capture and cancelled drags
    -- also cover ordinary waveform range edits. The companion owns the handle.
    r.SetExtState(EXT,'preview_stop',prepared.session,false)
    local main=r.GetMainHwnd();local arrange=r.JS_Window_FindChildByID(main,1000)
    if arrange then
      -- A floating Media Explorer can remain the key window on macOS.
      -- Activate the destination window before assigning its child focus.
      r.JS_Window_SetForeground(main);r.JS_Window_SetFocus(arrange)
    end
  elseif ctx.phase=='cancel' or ctx.phase=='discard'then
    r.DeleteExtState(EXT,'prepared',false)
    r.DeleteExtState(EXT,'captured',false)
    if ctx.phase=='cancel' and not r.GetExtState(EXT,'message'):match('^Drop cancelled:')then
      r.SetExtState(EXT,'message','Drop cancelled. Drag audio into Arrange as new items.',false)
    end
  else error('Invalid transaction phase')end
end,function(err)
  if type(err)=='table' and err.expected_drop_rejection then return err end
  return debug.traceback(err)
end)
r.DeleteExtState(EXT,'busy',false)
if not ok then
  r.DeleteExtState(EXT,'prepared',false)
  local message=type(err)=='table' and err.expected_drop_rejection and err.message or tostring(err)
  r.SetExtState(EXT,'message','Drop cancelled: '..message:match('^[^\n]+'),false)
  r.ShowConsoleMsg('SoundPrep drop cancelled:\n'..message..'\n')
end
r.AM_DropResult(ok)
