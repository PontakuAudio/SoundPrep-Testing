local U=require('am.util')
local Time=require('am.timeline')
local Mix=require('am.channel_mix')
local Selection=require('am.channel_selection')
local M={};M.__index=M
-- Control-rate gain changes stay small even after modal drags or a stalled UI.
-- The native source keeps running; this does not seek or rebuild the FX chain.
M.GAIN_DB_PER_SECOND=6
M.GAIN_MAX_STEP_DB=.15
M.GAIN_MAX_TICK_SECONDS=.025
function M.new(r,project,track)
  local native=r.APIExists('AM_Preview_Create')
  return setmetatable({r=r,project=project,track=track,starts=0,native=native,
    multichannel=native and (r.APIExists('AM_Preview_CreateWithChannels')or r.APIExists('AM_Preview_CreateWithDownmix')),
    downmix_modes=native and r.APIExists('AM_Preview_CreateWithDownmix'),
    get_value=native and r.AM_Preview_GetValue or r.CF_Preview_GetValue,
    set_value=native and r.AM_Preview_SetValue or r.CF_Preview_SetValue,
    play_handle=native and r.AM_Preview_Play or r.CF_Preview_Play,
    stop_handle=native and r.AM_Preview_Stop or r.CF_Preview_Stop},M)
end
function M.channels(r,path)
  if not path then return 0 end
  local source=r.PCM_Source_CreateFromFile(path);if not source then return 0 end
  local channels=r.GetMediaSourceNumChannels(source)
  r.PCM_Source_Destroy(source)
  return channels
end
function M:get(name)return self.get_value(self.handle,name)end
function M:set(name,value)return self.set_value(self.handle,name,value)end
function M:latency_track(track)
  self.fx_track=track
  if self.handle and self.native and self.r.APIExists('AM_Preview_SetLatencyTrack')then
    assert(self.r.AM_Preview_SetLatencyTrack(self.handle,track),'Cannot bind preview FX timing')
  end
end
function M:stop(immediate)
  self.ended_path=nil;self.eof_path=nil
  self.gain_target=nil;self.gain_tick_time=nil
  if self.handle then
    if immediate then assert(self.set_value(self.handle,'D_FADEOUTLEN',0),'Cannot discard the previous source fade')end
    self.stop_handle(self.handle);self.handle=nil
  end
end
function M:playing()
  if not self.handle then return false end
  local ok,pos=self:get('D_POSITION')
  if not ok then
    self.handle=nil;self.ended_path=self.path;self.eof_path=self.path
    self.gain_target=nil;self.gain_tick_time=nil
    return false
  end
  return true,pos,select(2,self:get('D_LENGTH'))
end
function M:start(path,macro,gain_db,settings,range,position)
  local r=self.r
  assert(r.ValidatePtr2(self.project,self.track,'MediaTrack*'),'Preview output track was removed')
  local source=assert(r.PCM_Source_CreateFromFile(path),'Cannot decode selected file')
  local channels=r.GetMediaSourceNumChannels(source)
  if channels>128 or (channels>2 and not self.multichannel)then
    r.PCM_Source_Destroy(source)
    return false,channels>128 and 'Preview supports up to 128 source channels.' or
      'Multichannel preview requires the updated native helper. Update it with REAPER closed, then restart.'
  end
  local selection=Selection.get(settings,channels)
  if selection and (not Selection.valid(channels,selection)or not r.APIExists(selection.channels and 'AM_Preview_CreateWithChannelSubset' or 'AM_Preview_CreateWithChannelSelection'))then
    r.PCM_Source_Destroy(source)
    return false,'Input channel selection requires a valid mapping and the updated native helper. Update it with REAPER closed, then restart.'
  end
  local downmix_mode=0
  if not selection and channels>2 and settings.preview_downmix then
    local reason
    downmix_mode,reason=Mix.resolve(path,channels,settings.preview_downmix_mode)
    if not downmix_mode or (downmix_mode==2 and not self.downmix_modes)then
      r.PCM_Source_Destroy(source)
      return false,reason or 'AmbiX stereo preview requires the updated native helper. Update it with REAPER closed, then restart.'
    end
  end
  local handle
  local ok,err=xpcall(function()
    assert(channels>=1,'Not an audio source')
    local length,is_qn=r.GetMediaSourceLength(source);assert(not is_qn and length>0,'Not an audio source')
    local a,b=0,length
    if range then a=U.clamp(range[1],0,length);b=U.clamp(range[2],a,length);assert(b>a,'Empty preview range')end
    local t=macro.source_transform
    if t.reverse or range then
      local section=assert(r.PCM_Source_CreateFromType('SECTION'),'Cannot create source section')
      local configured=r.CF_PCM_Source_SetSectionInfo(section,source,a,b-a,t.reverse)
      if not configured then r.PCM_Source_Destroy(section);error('Cannot configure source section')end
      r.PCM_Source_Destroy(source);source=section
    end
    if self.native then
      if selection and selection.channels then handle=r.AM_Preview_CreateWithChannelSubset(source,self.project,self.track,Selection.csv(selection))
      elseif selection then handle=r.AM_Preview_CreateWithChannelSelection(source,self.project,self.track,selection.left,selection.right)
      elseif channels>2 then
        if self.downmix_modes then handle=r.AM_Preview_CreateWithDownmix(source,self.project,self.track,downmix_mode)
        else handle=r.AM_Preview_CreateWithChannels(source,self.project,self.track,downmix_mode~=0)end
      else handle=r.AM_Preview_Create(source,self.project,self.track)end
      assert(handle,'Cannot create native preview')
    else
      handle=assert(r.CF_CreatePreview(source),'Cannot create SWS preview')
      assert(r.CF_Preview_SetOutputTrack(handle,self.project,self.track),'Cannot set preview output')
    end
    local values={B_LOOP=settings.loop and 1 or 0,B_PPITCH=t.preserve_pitch and 1 or 0,
      D_PITCH=t.pitch_semitones,D_PLAYRATE=t.rate,D_VOLUME=U.gain(gain_db or 0),
      D_FADEINLEN=(settings.preview_fade_ms or 0)/1000,D_FADEOUTLEN=(settings.preview_fade_ms or 0)/1000,I_PITCHMODE=-1}
    if settings.measure_align and (not self.native or r.APIExists('AM_WaveCursorState'))then values.D_MEASUREALIGN=settings.measure_align end
    for k,v in pairs(values)do assert(self.set_value(handle,k,v),'Cannot set '..k)end
    if self.native and r.APIExists('AM_Preview_SetWaveform')then
      assert(r.AM_Preview_SetWaveform(handle,path,length,a,b,t.reverse),'Cannot bind waveform coordinates')
    end
    if position and position>0 then assert(self.set_value(handle,'D_POSITION',position),'Cannot set preview position')end
    if self.fx_track and self.native and r.APIExists('AM_Preview_SetLatencyTrack')then
      assert(r.AM_Preview_SetLatencyTrack(handle,self.fx_track),'Cannot bind preview FX timing')
    end
    self:stop()
    assert(self.play_handle(handle),'Cannot start preview')
    if self.native then r.AM_Preview_BindControls(handle)end
    self.handle=handle;self.path=path;self.ended_path=nil;self.macro=U.copy(macro);self.range=range and U.copy(range)
    self.source_length=length;self.gain_db=gain_db or 0;self.source_channels=channels
    self.channel_selection=U.copy(selection)
    self.output_channels=selection and Selection.output(selection)or channels>2 and not settings.preview_downmix and channels or 2
    self.downmix_mode=downmix_mode
    self.starts=self.starts+1
  end,debug.traceback)
  r.PCM_Source_Destroy(source)
  if not ok then if handle then self.stop_handle(handle)end;error(err)end
  return true
end
function M:source_position()
  local playing,pos=self:playing()
  if playing then
    local transform=U.copy(self.macro.source_transform)
    if self.native then transform.rate=select(2,self:get('D_PLAYRATE'))end
    return Time.source(pos,self.source_length,self.range,transform)
  end
end
function M:reconfigure(macro,gain_db,settings)
  local playing,pos=self:playing();if not playing then return false end
  local before=U.copy(self.macro.source_transform);local after=macro.source_transform
  if self.native then
    before.rate=select(2,self:get('D_PLAYRATE'));before.pitch_semitones=select(2,self:get('D_PITCH'))
    before.preserve_pitch=select(2,self:get('B_PPITCH'))~=0
  end
  local source=Time.source(pos,self.source_length,self.range,before)
  if before.reverse~=after.reverse then
    -- A SECTION's direction is immutable once CF has duplicated it. Rebuild
    -- just the source, preserving its location; the FX bank remains alive.
    local transitioning=self.gain_target~=nil
    local started,reason=self:start(self.path,macro,transitioning and self.gain_db or gain_db,settings,self.range,
      Time.position(source,self.source_length,self.range,after))
    if started==false then return false,reason end
    if transitioning then self:fade_gain(gain_db)end
    return true
  end
  local r,h=self.r,self.handle
  for _,v in ipairs{{'B_PPITCH',after.preserve_pitch and 1 or 0,before.preserve_pitch~=after.preserve_pitch},
    {'D_PITCH',after.pitch_semitones,before.pitch_semitones~=after.pitch_semitones},
    {'D_PLAYRATE',after.rate,before.rate~=after.rate}}do
    if v[3]then assert(self.set_value(h,v[1],v[2]),'Cannot update '..v[1])end
  end
  if before.rate~=after.rate and not self.native then
    assert(self.set_value(h,'D_POSITION',Time.position(source,self.source_length,self.range,after)),'Cannot retain preview position')
  end
  -- Pitch/Rate edits request the same final normalization while it is moving.
  -- Preserve that transition; an explicit different gain keeps legacy behavior.
  if self.gain_target~=gain_db and (self.gain_db~=gain_db or self.gain_target~=nil)then
    assert(self:update_gain(gain_db),'Cannot update D_VOLUME')
  end
  self.macro=U.copy(macro)
  return true
end
function M:seek_source(source)
  if self:playing()then
    local transform=U.copy(self.macro.source_transform)
    if self.native then transform.rate=select(2,self:get('D_PLAYRATE'))end
    return self:seek(Time.position(source,self.source_length,self.range,transform))
  end
  return false
end
function M:seek(pos)
  if self:playing()then return self:set('D_POSITION',math.max(0,pos))end
  return false
end
function M:update_gain(db)
  assert(U.finite(db),'Invalid preview gain')
  self.gain_target=nil;self.gain_tick_time=nil
  if self:playing()and self:set('D_VOLUME',U.gain(db))then self.gain_db=db;return true end
  return false
end
function M:fade_gain(db)
  assert(U.finite(db),'Invalid preview gain')
  if not self:playing()then return false end
  if db==self.gain_db then self.gain_target=nil;self.gain_tick_time=nil;return true end
  if self.gain_target~=db then
    if self.gain_target==nil then self.gain_tick_time=self.r.time_precise()end
    self.gain_target=db
  end
  return true
end
function M:tick_gain(now)
  if self.gain_target==nil then return false end
  if not self:playing()then return false end
  now=now or self.r.time_precise()
  local dt=U.clamp(now-(self.gain_tick_time or now),0,M.GAIN_MAX_TICK_SECONDS)
  self.gain_tick_time=now
  local difference=self.gain_target-self.gain_db
  local step=math.min(math.abs(difference),M.GAIN_DB_PER_SECOND*dt,M.GAIN_MAX_STEP_DB)
  if step==0 then return false end
  local next_gain=step>=math.abs(difference) and self.gain_target or self.gain_db+(difference>0 and step or -step)
  if not self:set('D_VOLUME',U.gain(next_gain))then
    self.gain_target=nil;self.gain_tick_time=nil;return false
  end
  self.gain_db=next_gain
  if next_gain==self.gain_target then self.gain_target=nil;self.gain_tick_time=nil end
  return true
end
return M
