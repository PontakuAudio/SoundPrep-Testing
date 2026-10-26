local J=require('am.json');local U=require('am.util')
local ChannelMix=require('am.channel_mix')
local Selection=require('am.channel_selection')
local Channels=require('am.channel_panel')
local Settings=require('am.settings_panel')
local Editor=require('am.editor_panel')
local Loudness=require('am.loudness')
local Analysis=require('am.analysis_policy')
local M={};M.__index=M
function M.available(r)
  local info,err=require('am.native').inspect(r)
  return info~=nil,err
end
function M.new(r,app)return setmetatable({r=r,app=app},M)end
function M:state()
  local a=self.app;local m=a:effective();local slots={};local macros=J.array{}
  for slot,id in pairs(a.definition.slots)do slots[id]=slot end
  for _,item in ipairs(a.definition.macros)do
    macros[#macros+1]={id=item.id,label=(slots[item.id] or '–')..'  '..item.name}
  end
  local paused=self.r.EnumProjects(-1)~=a.project
  local gain,status=a:gain();local measured=a:measurement()
  local spec=Analysis.resolve(a.path or (a.identity and a.identity.path),a.source_channels or 0,a.definition.settings,m.normalization)
  local analysis_active=a.loudness.active and not a.loudness.active.cancelled and Loudness.same(a.loudness.active.identity,a.identity)
    and Analysis.same(spec,a.loudness.active.analysis)
  local analysis_queued=a.loudness.queued and Loudness.same(a.loudness.queued,a.identity)and Analysis.same(spec,a.loudness.queued_analysis)
  local analysis_error=a.loudness.error and Loudness.same(a.loudness.wanted,a.identity)
    and Analysis.same(spec,a.loudness.wanted_analysis)and a.loudness.error
  local label=('%s · Pitch %+.1f · Rate %.2fx'):format(m.name,m.source_transform.pitch_semitones,m.source_transform.rate)
  if measured and measured.status=='ready' then
    if m.normalization.enabled and m.normalization.metric~='lufs_m_max' then
      label=label..(' · Zwicker %s %.2f sones · gain %+.1f dB'):format(m.normalization.metric=='zwicker_p95' and 'P95' or 'Max',measured.zwicker_sones,gain)
    else label=label..(' · %.1f LUFS-M · gain %+.1f dB'):format(measured.max_momentary_lufs,gain)end
  elseif analysis_active then label=label..' · analysing…'
  elseif analysis_queued then label=label..' · analysis queued…'
  elseif m.normalization.enabled then label=label..' · '..status end
  if a.preview:playing() and a.preview.gain_target~=nil then
    label=label..(' · applying %+.1f → %+.1f dB'):format(a.preview.gain_db,a.preview.gain_target)
  end
  if analysis_error then label='Analysis failed: '..analysis_error end
  -- A rejected drop must not hide later progress, the actual worker failure,
  -- or a completed measurement. Preserve unrelated application notices.
  local analysis_notice=a.message:match('^Unmeasured:')or a.message:match('^Drop cancelled: Analysis ')
  if a.message~='' and not (analysis_notice and (measured or analysis_active or analysis_queued or analysis_error))then label=a.message end
  local selection=Selection.get(a.definition.settings,a.source_channels)
  if selection then
    label=label..(' · %dch → %s'):format(a.source_channels,Selection.label(selection))
  elseif (a.source_channels or 0)>2 then
    local setting=a.definition.settings
    local mix,reason=ChannelMix.describe(a.path,a.source_channels,setting.preview_downmix_mode)
    local mode=ChannelMix.resolve(a.path,a.source_channels,setting.preview_downmix_mode)
    label=label..(' · %dch%s'):format(a.source_channels,setting.preview_downmix and not reason and ' → 2ch' or '')
    if setting.preview_downmix then label=label..' · '..mix..(mode==2 and ' (W/Y M/S)' or '')end
    if spec then label=label..' · Normalize: '..Analysis.label(spec)end
    if not setting.preview_downmix then label=label..' · Macro FX bypassed'end
  end
  if paused then label='Paused — return to the attached project' end
  return {active=a.selected_id or 'raw',macros=macros,reverse=m.source_transform.reverse,preserve_pitch=m.source_transform.preserve_pitch,
    normalize=m.normalization.enabled,target=m.normalization.target_lufs,
    target_label=m.normalization.metric~='lufs_m_max' and ('Norm %.2f sones'):format(m.normalization.target_sones) or nil,
    downmix=not selection and a.definition.settings.preview_downmix==true,multichannel=(a.source_channels or 0)>2,
    monitor=a.definition.settings.monitor_gain_db,status=label,paused=paused,
    -- Omitted panel state closes the native view. Only build its contents while
    -- open, so hidden diagnostics/microphone pages do not drive bar updates.
    channels=a.channel_panel_open and Channels.state(a)or nil,
    settings=a.settings_panel_open and Settings.state(a)or nil,editor=Editor.state(a)}
end
function M:dispatch(command)
  local a=self.app
  if command=='quit' then a.closed=true;return end
  if command=='channels:close'then Channels.dispatch(a,command);return end
  if command=='settings:close'then Settings.dispatch(a,command);return end
  if command=='editor:close'then Editor.dispatch(a,command);return end
  if self.r.EnumProjects(-1)~=a.project then return end
  if command:match('^search[:@]') then
    a.message='Search assistance is not included in this release. Use the Media Explorer search field.'
  elseif command=='raw' or command=='macro:raw' then a:activate(nil)
  elseif command:match('^macro:') then a:activate(command:sub(7))
  elseif command=='ab' then a:ab()
  elseif command=='reverse' then a:reverse()
  elseif command=='preserve_pitch' then a:set_preserve_pitch(not a:effective().source_transform.preserve_pitch)
  elseif command=='downmix' then a:set_downmix(Selection.get(a.definition.settings,a.source_channels)~=nil or not a.definition.settings.preview_downmix)
  elseif command=='channels' or command:match('^channels@')then Channels.dispatch(a,command)
  elseif command=='normalize' then a:set_normalization(not a:effective().normalization.enabled)
  elseif command=='target:custom' then Editor.open(a,1)
  elseif command:match('^target:') then
    if a:effective().normalization.metric~='lufs_m_max'then Editor.open(a,1)
    else a:set_normalization(true,assert(tonumber(command:sub(8))))end
  elseif command:match('^monitor:') then
    local gain=assert(tonumber(command:sub(9)));assert(U.finite(gain) and gain>=-60 and gain<=0)
    a.definition.settings.monitor_gain_db=gain;a.bank:activate(a.selected_id,a:effective().output_gain_db);a:save()
  elseif command=='settings' or command:match('^settings@')then Settings.dispatch(a,command)
  elseif command:match('^editor@')then Editor.dispatch(a,command)
  elseif command=='edit' then Editor.open(a)
  else error('Unknown native bar command: '..command) end
end
function M:tick()
  Settings.tick(self.app)
  if self.app.editor_requested then Editor.open(self.app);self.app.editor_requested=nil end
  if self.app.settings_requested then Settings.open(self.app);self.app.settings_requested=nil end
  if self.app.channels_requested then self.app.channel_panel_open=true;self.app.channels_requested=nil end
  local w=self.app.explorer:window();local list=self.app.explorer:control(1001)
  if not w or not list then self:close();return end
  assert(self.r.AM_BarAttach(w,list),'Could not attach the Media Explorer control bar')
  if w~=self.window or list~=self.list then self.window=w;self.list=list;self.last_state=nil end
  local dispatched=false
  for _=1,64 do
    local command=self.r.AM_BarPoll();if command=='' then break end
    dispatched=true
    local ok,e=pcall(self.dispatch,self,command);if not ok then self.app.message=tostring(e)end
  end
  -- A Cocoa drag may suspend the next defer tick. Publish the new recipe in
  -- this same callback so an immediate drag cannot use the previous Macro.
  if dispatched and not self.app.closed and self.app.drop then self.app.drop:tick()end
  local state=self:state()
  if dispatched or not U.equal(state,self.last_state)then assert(self.r.AM_BarSetState(J.encode(state)),'Could not update the Media Explorer control bar');self.last_state=state end
end
function M:close()
  local ok,err=pcall(Settings.flush,self.app)
  self.r.AM_BarDetach();self.window=nil;self.list=nil;self.last_state=nil
  if not ok then self.app.message=tostring(err)end
end
return M
