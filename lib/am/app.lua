local U=require('am.util');local J=require('am.json');local Model=require('am.model')
local Bank=require('am.bank');local Explorer=require('am.media_explorer');local Preview=require('am.preview')
local Loudness=require('am.loudness');local Export=require('am.export')
local Time=require('am.timeline')
local Mix=require('am.channel_mix')
local Selection=require('am.channel_selection')
local Analysis=require('am.analysis_policy')
local M={};M.__index=M
M.EXT='AuditionMacro.v1'
function M.initialize(r,root,data)
  r.RecursiveCreateDirectory(data..'/chains',0)
  if not r.file_exists(data..'/bank.json')then
    local b=Model.defaults()
    for _,m in ipairs(b.macros)do
      local chain=assert(U.read(root..'/resources/'..m.fx_chain))
      assert(U.write(data..'/'..m.fx_chain,chain))
    end
    assert(Model.save(data..'/bank.json',b))
  end
end
function M.new(r,root,data)
  require('am.native').require(r) -- Reject an incomplete helper before changing project/settings.
  local required={'CF_CreatePreview','CF_PCM_Source_SetSectionInfo','JS_Window_Find','JS_File_Stat','MediaExplorerGetLastPlayedFileInfo'}
  for _,api in ipairs(required)do assert(r.APIExists(api),'Missing '..api..'. Requires REAPER 7.35+, SWS and JS_ReaScriptAPI.')end
  M.initialize(r,root,data)
  require('am.recovery').restore(r,data)
  local recovered=require('am.recovery').reveal_orphans(r)
  if recovered>0 then r.ShowConsoleMsg(('SoundPrep: %d saved preview tracks recovered, muted and made visible.\n'):format(recovered))end
  local self=setmetatable({r=r,root=root,data=data,session=U.hash(r.genGuid()),message='',last_poll=0,
    selected_id=nil,previous_id=nil,reverse_override=nil,closed=false,export_dir=data..'/exports',range=nil},M)
  local ok,err=xpcall(function()
    self.definition=assert(Model.load(data..'/bank.json'))
    self.project=r.EnumProjects(-1)
    self.bank=Bank.new(r,self.project,data,self.definition,self.session)
    self.preview=Preview.new(r,self.project,self.bank.input)
    self.explorer=Explorer.new(r);self.explorer:attach(function(saved)
      assert(U.write(data..'/recovery.json',J.encode{schema_version=1,session=self.session,explorer=saved}))
    end)
    self.explorer:toggle(1068,self.definition.settings.loop)
    self.loudness=Loudness.new(r,root,data,self.definition.settings,self.session)
    self.macro=Model.effective(self.definition,nil)
    self.explorer:set_transform(self.macro.source_transform)
    -- The selection already present at launch is state, not an audition gesture.
    -- Capture it now so a later user selection still follows autoplay normally.
    self:select_source(self.explorer:selection())
    self.drop=require('am.drop').new(r,self)
    if not self.drop then self.message='Processed waveform D&D needs native helper v0.3. Update the helper with REAPER closed, then restart.'end
    self:publish()
  end,debug.traceback)
  if not ok then self:close();error(err)end
  return self
end
function M:publish()
  local now=self.r.time_precise()
  if self.last_heartbeat and now-self.last_heartbeat<.5 then return end
  self.last_heartbeat=now
  self.r.SetExtState(M.EXT,'heartbeat',tostring(now),false)
  self.r.SetExtState(M.EXT,'session',self.session,false)
end
function M:save()
  assert(Model.save(self.data..'/bank.json',self.definition))
  self.effective_macro=nil
end
function M:effective()
  if not self.effective_macro or self.effective_id~=self.selected_id or self.effective_reverse~=self.reverse_override then
    self.effective_macro=self.edit_preview and U.copy(self.edit_preview) or Model.effective(self.definition,self.selected_id,self.reverse_override)
    if self.transform_override then
      for k,v in pairs(self.transform_override)do self.effective_macro.source_transform[k]=v end
    end
    if self.reverse_override~=nil then self.effective_macro.source_transform.reverse=self.reverse_override end
    self.effective_macro.source_transform.rate=self.effective_macro.source_transform.rate*(self.tempo_factor or 1)
    self.effective_id=self.selected_id;self.effective_reverse=self.reverse_override
  end
  return self.effective_macro -- Read-only snapshot; edits go through save().
end
function M:reflect_transform(t)
  local raw=U.copy(t);raw.rate=raw.rate/(self.tempo_factor or 1)
  self.explorer:set_transform(raw)
end
function M:analysis_spec(include_disabled)
  return Analysis.resolve(self.path or (self.identity and self.identity.path),self.source_channels or 0,self.definition.settings,self:effective().normalization,include_disabled)
end
function M:measurement()
  local spec,reason=self:analysis_spec();if reason then return end
  local fallback=not self:effective().normalization.enabled and self:analysis_spec(true)or nil
  return self.identity and self.loudness:get(self.identity,spec,fallback)
end
function M:sync_channel_waveform()
  if not self.r.AM_WaveSetChannels then return end
  local selected=Selection.get(self.definition.settings,self.source_channels)
  local identity=self.identity
  local stamp=identity and tostring(identity.size)..':'..tostring(identity.mtime)or ''
  if self.r.AM_WaveSetChannelSubset then
    local visible=selected;local labels,json,named
    if self.r.AM_WaveSetChannelNames then
      labels,json,named=require('am.channel_panel').labels(self)
      if not visible and named then
        local all={};for ch=1,#labels do all[ch]=ch end;visible={channels=all}
      end
    end
    self.r.AM_WaveSetChannelSubset(visible and self.path or '',visible and Selection.csv(visible)or '',stamp)
    if self.r.AM_WaveSetChannelNames then
      self.r.AM_WaveSetChannelNames(visible and self.path or '',stamp,visible and json or '[]')
    end
  elseif not selected or not selected.channels then
    self.r.AM_WaveSetChannels(selected and self.path or '',selected and selected.left or 0,selected and selected.right or 0,stamp)
  end
end
function M:configure_channels()
  self:sync_channel_waveform()
  local channels=self.source_channels or 0
  local selected=Selection.get(self.definition.settings,channels)
  local output=selected and Selection.output(selected)or channels
  local bypass=output>2 and (selected~=nil or not self.definition.settings.preview_downmix)
  self.bank:set_channels(selected and output or channels>=1 and channels<=128 and not self.definition.settings.preview_downmix and channels or 2,bypass)
end
function M:read_source_channels()
  self.source_channels=Preview.channels(self.r,self.path)
  self:configure_channels()
end
function M:request_analysis(force)
  if not self.identity then return end
  local spec,reason=self:analysis_spec()
  if reason then self.message=reason;return end
  local fallback=not self:effective().normalization.enabled and self:analysis_spec(true)or nil
  return self.loudness:request(self.identity,force,spec,fallback)
end
local function processing_message(status)
  return status=='unmeasured' and 'Unmeasured: playing while analysis runs. Normalization applies automatically.' or ''
end
function M:clear_source()
  self.preview:stop(true)
  self.playback_identity=nil;self.playback_analysis=nil
  if self.path then self.bank:clear_buffers()end
end
function M:select_source(path,reason)
  self:clear_source();self.paused_position=nil;self.paused_source=nil;self.last_seek=nil
  self.path=path;self.identity=path and Loudness.identity(self.r,path) or nil;self.range=nil
  self:read_source_channels()
  self.message=reason or '';self.applied_gain=nil
  if self.identity then
    self:sync_range(false)
    if self:effective().normalization.enabled or self:effective().source_peak_guard.enabled then self:request_analysis()end
  end
end
function M:gain()
  return Loudness.gain(self:effective(),self:measurement())
end
function M:play(position,immediate)
  assert(self.r.EnumProjects(-1)==self.project,'Return to the project where SoundPrep started')
  local path,e=self.explorer:selection();assert(path,e)
  local identity=assert(Loudness.identity(self.r,path))
  self.explorer:ensure_waveform(path)
  if not Loudness.same(identity,self.identity)then
    self:clear_source();self.path=path;self.identity=identity;self.range=nil;position=nil;self.paused_source=nil;self.last_seek=nil
    self:read_source_channels()
  end
  if self.source_channels==nil then self:read_source_channels()end
  if self:sync_range(false)then position=nil;self.paused_source=nil end
  -- Stop-and-display mode already loaded the waveform. Do not send native
  -- Stop here: when stopped, REAPER treats it as unloading the selected media.
  self:sync_transform()
  local macro=self:effective();local gain,status=self:gain()
  self.bank:activate(self.selected_id,macro.output_gain_db)
  self.preview:latency_track(self.bank.fx_bypassed and self.bank.input or self.bank.chosen)
  local settings=U.copy(self.definition.settings)
  settings.measure_align=not immediate and self.r.GetToggleCommandStateEx(32063,1012)==1 and
    (self.r.GetToggleCommandStateEx(32063,42171)==1 and 1 or 0) or -1
  local started,reason=self.preview:start(path,macro,gain,settings,self.range,position)
  if started==false then
    self.message=reason
    local _,mix_error=Mix.resolve(path,self.source_channels,settings.preview_downmix_mode)
    self.downmix_error=reason==mix_error and reason or nil
    return false
  end
  self.downmix_error=nil
  self.paused_position=nil;self.paused_source=nil
  self.playback_identity=U.copy(identity)
  self.playback_analysis=U.copy(self:analysis_spec())
  self.applied_gain=gain;self.applied_status=status
  if macro.normalization.enabled or macro.source_peak_guard.enabled then self:request_analysis()end
  self.message=processing_message(status)
  return true
end
function M:refresh_processing()
  local gain,status=self:gain()
  local analysis,analysis_error=self:analysis_spec()
  if status=='unmeasured' and not analysis_error and Loudness.same(self.playback_identity,self.identity) and U.finite(self.preview.gain_db)then
    local before=self.playback_analysis
    if Analysis.same(before,analysis)then
      -- A forced refresh retains the validated gain or its smooth target.
      gain=self.preview.gain_target or self.preview.gain_db
    elseif ((before and before.meter)or (analysis and analysis.meter))and
      (before and before.basis or 'source')==(analysis and analysis.basis or 'source')and
      U.equal(before and before.selection,analysis and analysis.selection)and
      (before and before.source_channels or self.source_channels)==(analysis and analysis.source_channels or self.source_channels)then
      -- A changed Zwicker target/calibration needs another solution. Keep the
      -- audible level and stop the old target ramp until that solution arrives.
      gain=self.preview.gain_db;self.preview.gain_target=nil;self.preview.gain_tick_time=nil
    end
  end
  if self.preview:reconfigure(self:effective(),gain,self.definition.settings)then
    self.applied_gain=self.preview.gain_db or gain;self.applied_status=status
    if not analysis_error then self.playback_analysis=U.copy(analysis)end
    self.message=processing_message(status)
  end
end
function M:update_normalization(now)
  local preview=self.preview
  if self.closed or self.cleaned or self.r.EnumProjects(-1)~=self.project or
    not Loudness.same(self.playback_identity,self.identity) or not preview or
    not U.path_equal(preview.path,self.path) or preview.source_channels~=self.source_channels then return false end
  local analysis,reason=self:analysis_spec();if reason then return false end
  local mode=0
  local selection=Selection.get(self.definition.settings,self.source_channels)
  if not U.equal(preview.channel_selection,selection)then return false end
  if not selection and self.source_channels>2 and self.definition.settings.preview_downmix then
    mode=Mix.resolve(self.path,self.source_channels,self.definition.settings.preview_downmix_mode)
  end
  if preview.downmix_mode~=mode or not preview:playing()then return false end
  local measurement=self:measurement()
  if Loudness.matches_measurement(measurement,self.identity,self.loudness.analyzer_key,analysis)then
    -- Zwicker results include their target and calibration in the descriptor;
    -- only a result matching the current preset can become a live gain target.
    local gain,status=Loudness.gain(self:effective(),measurement)
    local current_target=preview.gain_target or preview.gain_db
    if not U.finite(current_target)or math.abs(gain-current_target)>1e-9 then
      if not preview:fade_gain(gain)then return false end
    end
    self.playback_analysis=U.copy(analysis);self.applied_status=status
    if self.message:match('^Unmeasured:')then self.message=''end
  end
  -- Completion can arrive during a forced refresh, but absence/failure must
  -- never replace an already validated gain with an implicit unity target.
  if Analysis.same(self.playback_analysis,analysis)then
    preview:tick_gain(now or self.r.time_precise())
    self.applied_gain=preview.gain_db
  end
  return true
end
function M:resume(from_seek)
  local position=self.paused_position
  local length=self.paused_length or self.preview.source_length
  local source=self.paused_source
  if from_seek and self.last_seek and self.last_seek.path==self.path then
    source=self.last_seek.source;length=self.last_seek.length
  end
  if source and length then
    position=Time.position(source,length,self.range,self:effective().source_transform)
  end
  self:play(position)
end
function M:activate(id)
  if id then assert(Model.find(self.definition,id),'Unknown macro')end
  if id==self.selected_id then return end
  self:stash_preset()
  if self.selected_id~=id then self.previous_id=self.selected_id or self.previous_id end
  self.selected_id=id;self.reverse_override=nil;self.transform_override=nil;self.edit_preview=nil;self.effective_macro=nil
  if self.preset_drafts then self.edit_preview=U.copy(self.preset_drafts[id or 'raw']) end
  local after=self:effective()
  self.bank:activate(id,after.output_gain_db)
  self.preview:latency_track(self.bank.fx_bypassed and self.bank.input or self.bank.chosen)
  self:reflect_transform(after.source_transform)
  self:refresh_processing()
  if self.identity and (after.normalization.enabled or after.source_peak_guard.enabled)then self:request_analysis()end
end
function M:reverse()
  self.reverse_override=not self:effective().source_transform.reverse
  self:refresh_processing()
  self:stash_preset()
end
function M:set_preserve_pitch(enabled)
  assert(type(enabled)=='boolean','Preserve Pitch must be boolean')
  self.transform_override=self.transform_override or {}
  self.transform_override.preserve_pitch=enabled;self.effective_macro=nil
  self:reflect_transform(self:effective().source_transform)
  self:refresh_processing();self:stash_preset()
end
local function clear_downmix_error(self)
  if self.downmix_error and self.message==self.downmix_error then self.message=''end
  self.downmix_error=nil
end
local function set_downmix_setting(self,key,value,selection_change)
  assert(self.r.EnumProjects(-1)==self.project,'Return to the project where SoundPrep started')
  local settings=self.definition.settings
  local enabled=settings.preview_downmix
  if key=='preview_downmix'then enabled=value end
  local preference=key=='preview_downmix_mode' and value or settings.preview_downmix_mode
  local selected=key=='channel_selections' and value[tostring(self.source_channels)]or
    (key~='channel_selections' and Selection.get(settings,self.source_channels))
  if enabled and not selected and (self.source_channels or 0)>2 then
    local mode,reason=Mix.resolve(self.path,self.source_channels,preference)
    if not mode then self.message=reason;self.downmix_error=reason;return false,reason end
  end
  if U.equal(settings[key],value)then clear_downmix_error(self);return true end
  self:sync_transform()
  local source=self.preview:source_position()
  local previous=settings[key]
  settings[key]=value
  local saved,err=pcall(self.save,self)
  if not saved then settings[key]=previous;error(err)end
  clear_downmix_error(self)
  if not selection_change and (self.source_channels or 0)<=2 then return true end
  if self.identity then
    local macro=self:effective()
    if macro.normalization.enabled or macro.source_peak_guard.enabled then self:request_analysis()end
  end
  if not selection_change and (Selection.get(settings,self.source_channels)or key=='preview_downmix_mode' and not enabled)then
    if self.identity then self:refresh_processing()end
    return true
  end
  local position=source and Time.position(source,self.preview.source_length,self.range,self:effective().source_transform)
  if source then self.preview:stop(true)end
  self.bank:clear_buffers();self:configure_channels()
  if source then return self:play(position,true)end
  return true
end
function M:set_channel_selection(left,right)
  local selection=type(left)=='table' and {channels=U.copy(left)}or left and {left=left,right=right or left}or nil
  assert(not selection or Selection.valid(self.source_channels,selection),'Invalid input channel selection')
  local routes=U.copy(self.definition.settings.channel_selections or {})
  routes[tostring(self.source_channels)]=selection
  return set_downmix_setting(self,'channel_selections',routes,true)
end
function M:set_downmix(enabled)
  assert(type(enabled)=='boolean','Downmix must be boolean')
  if Selection.get(self.definition.settings,self.source_channels)then
    local settings=self.definition.settings;local previous=settings.preview_downmix
    if enabled and self.source_channels>2 then
      local mode,reason=Mix.resolve(self.path,self.source_channels,settings.preview_downmix_mode)
      if not mode then self.message=reason;return false,reason end
    end
    settings.preview_downmix=enabled
    local ok,result,reason=pcall(self.set_channel_selection,self,nil)
    if not ok then settings.preview_downmix=previous;error(result)end
    return result,reason
  end
  return set_downmix_setting(self,'preview_downmix',enabled)
end
function M:set_downmix_mode(mode)
  assert(mode=='auto' or mode=='discrete' or mode=='ambix','Invalid preview downmix mode')
  return set_downmix_setting(self,'preview_downmix_mode',mode)
end
function M:ab()
  if self.selected_id then self.previous_id=self.selected_id;self:activate(nil)
  elseif self.previous_id and Model.find(self.definition,self.previous_id)then self:activate(self.previous_id)end
end
function M:transport()
  if self.preview:playing()then self.preview:stop()else self:resume()end
end
function M:native_transport(command)
  if command~=1068 and command~=40039 and command~=40040 then self.explorer:quiesce()end
  if command==1008 or command==40027 then self:resume(command==40027)
  elseif command==1009 or command==40016 then self.preview:stop();self.paused_position=nil;self.paused_source=nil
  elseif command==1010 or command==40025 or command==40028 then
    local playing,pos=self.preview:playing()
    if playing then self.paused_position=pos;self.paused_source=self.preview:source_position();self.paused_length=self.preview.source_length;self.preview:stop()else self:resume(command==40028)end
  elseif command==40024 then self:transport()
  elseif command==40031 then self.preview:seek(0)
  elseif command==40033 or command==40034 then
    local length=self.preview.source_length or (self.last_seek and self.last_seek.length)
    if length then
      local transform=self:effective().source_transform
      local source=self.preview:source_position() or self.paused_source or (self.last_seek and self.last_seek.source) or 0
      local step=self.explorer:seek_step(length)*(command==40033 and -1 or 1)*(transform.reverse and -1 or 1)
      local a,b=Time.bounds(length,self.range);source=U.clamp(source+step,a,b)
      if self.preview:playing()then self.preview:seek_source(source)
      else self.paused_source=source;self.paused_length=length;self.paused_position=nil end
      self.last_seek={path=self.path,source=source,length=length}
    end
  elseif command==42185 or command==42186 then
    self.reverse_override=command==42185
    if self.preview:playing()then self:refresh_processing()else self:play()end
  elseif command==1068 or command==40039 or command==40040 then
    self.definition.settings.loop=self.r.GetToggleCommandStateEx(32063,1068)==1;self:save()
    if self.preview:playing()then self.preview:set('B_LOOP',self.definition.settings.loop and 1 or 0)end
  end
end
function M:analyse(force)
  assert(self.identity,'Select an audio file first')
  self:request_analysis(force)
end
function M:set_normalization(enabled,target)
  self:stash_preset()
  local edit=self:preset_draft(self.selected_id or 'raw')
  edit.normalization.enabled=enabled
  if target~=nil then edit.normalization.target_lufs=target end
  self:audition_edit(edit)
  -- Normalization changes keep the current Pitch / Rate / Reverse draft.
  if self.identity and enabled then self:request_analysis()end
  self:refresh_processing()
end
function M:sync_transform()
  local changed=self.explorer:transform_changes()
  local factor=self.explorer:tempo_factor()
  local tempo_changed=factor~=(self.tempo_factor or 1);self.tempo_factor=factor
  if not changed and not tempo_changed then return end
  self.transform_override=self.transform_override or {}
  for k,v in pairs(changed or {})do self.transform_override[k]=v end
  self.effective_macro=nil;self:refresh_processing()
  if changed then self:stash_preset()end
end
function M:preset_draft(id)
  id=id or self.selected_id or 'raw';self.preset_drafts=self.preset_drafts or {}
  if not self.preset_drafts[id]then self.preset_drafts[id]=U.copy(assert(Model.editable(self.definition,id)))end
  return self.preset_drafts[id]
end
function M:stash_preset()
  if not self.definition then return end
  if not(self.edit_preview or self.transform_override or self.reverse_override~=nil)then return end
  local id=self.selected_id or 'raw';local draft=self:preset_draft(id)
  if id~='raw'then
    local transform=U.copy(self:effective().source_transform)
    transform.rate=transform.rate/(self.tempo_factor or 1)
    draft.source_transform=transform
  end
end
function M:save_preset(id)
  id=id or self.selected_id or 'raw'
  if id==(self.selected_id or 'raw')then self:stash_preset()end
  self:apply_edit(self:preset_draft(id))
  self.message=id=='raw' and 'Raw normalization saved.' or ('Preset saved: '..Model.find(self.definition,id).name..' (FX + Pitch / Rate + all sound settings).')
end
function M:revert_preset(id)
  id=id or self.selected_id or 'raw'
  if id~='raw'then
    local m=assert(Model.find(self.definition,id));self.bank:load(self.bank.macros[id],self.data..'/'..m.fx_chain)
  end
  self.preset_drafts=self.preset_drafts or {};self.preset_drafts[id]=nil
  if id==(self.selected_id or 'raw')then
    self.edit_preview=nil;self.reverse_override=nil;self.transform_override=nil;self.effective_macro=nil
    local m=self:effective();self.bank:activate(self.selected_id,m.output_gain_db)
    self:reflect_transform(m.source_transform);self:refresh_processing()
  end
  self.message='Restored the saved preset, including FX and Pitch / Rate.'
end
function M:save_settings()
  self:save()
  self.bank:activate(self.selected_id,self:effective().output_gain_db)
end
function M:set_cache_directory(directory)
  local candidate=U.copy(self.definition);candidate.settings.cache_directory=directory
  Model.validate(candidate)
  if directory==self.definition.settings.cache_directory then return false end
  local cache=Loudness.cache_directory(self.data,candidate.settings)
  local jobs=Loudness.job_directory(self.data,candidate.settings,self.session)
  -- Check both destinations before persisting or redirecting live work.
  for _,path in ipairs{cache,jobs}do
    self.r.RecursiveCreateDirectory(path,0)
    local probe=path..'/.soundprep-write-'..U.hash(self.r.genGuid())
    local ok,err=U.write(probe,'SoundPrep cache write check')
    assert(ok,'Cannot write to cache folder: '..path..' — '..tostring(err))
    local removed,reason=os.remove(probe)
    assert(removed,'Cannot remove cache write check: '..tostring(reason))
  end
  assert(Model.save(self.data..'/bank.json',candidate))
  self.definition.settings.cache_directory=directory
  self.loudness.jobdir=jobs
  -- Running jobs retain their original files until completion. Keep valid
  -- measurements for uninterrupted playback, but retry misses in the new folder.
  for key,value in pairs(self.loudness.memory)do if value==false then self.loudness.memory[key]=nil end end
  self.message='Cache folder saved. Existing cache files stay in their previous folder.'
  return true
end
function M:choose_cache_directory()
  assert(type(self.r.JS_Dialog_BrowseForFolder)=='function','Update JS_ReaScriptAPI to choose a cache folder.')
  local result,path=self.r.JS_Dialog_BrowseForFolder('SoundPrep — Choose cache folder',
    Loudness.cache_directory(self.data,self.definition.settings))
  if result==0 then return false end
  assert(result==1 and type(path)=='string' and path~='','Could not choose a cache folder')
  return self:set_cache_directory(path)
end
function M:audition_edit(edit)
  self.preset_drafts=self.preset_drafts or {};self.preset_drafts[edit.id]=edit
  if (self.selected_id or 'raw')~=edit.id or U.equal(edit,self.edit_preview)then return end
  local candidate=U.copy(self.definition)
  if edit.id=='raw'then candidate.raw={normalization=U.copy(edit.normalization),source_peak_guard=U.copy(edit.source_peak_guard)}
  else local _,index=Model.find(candidate,edit.id);assert(index);candidate.macros[index]=U.copy(edit)end
  Model.validate(candidate)
  self.edit_preview=U.copy(edit);self.effective_macro=nil
  if edit.id~='raw'then self.transform_override=nil;self.reverse_override=nil end
  self.bank:activate(self.selected_id,edit.output_gain_db)
  self:reflect_transform(self:effective().source_transform);self:refresh_processing()
  if self.identity and (edit.normalization.enabled or edit.source_peak_guard.enabled)then self:request_analysis()end
end
function M:apply_edit(edit,quiet)
  if edit.id=='raw'then
    local candidate=U.copy(self.definition);candidate.raw={normalization=U.copy(edit.normalization),source_peak_guard=U.copy(edit.source_peak_guard)}
    assert(Model.save(self.data..'/bank.json',candidate));self.definition.raw=candidate.raw
    self.preset_drafts=self.preset_drafts or {};self.preset_drafts.raw=edit
    if not self.selected_id then self.edit_preview=nil end
    self.effective_macro=nil;if not quiet then self:refresh_processing()end;return
  end
  local m,index=Model.find(self.definition,edit.id);assert(m,'Macro no longer exists')
  local candidate=U.copy(self.definition);candidate.macros[index]=U.copy(edit);Model.validate(candidate)
  assert(edit.fx_chain==m.fx_chain,'Use Import FX to change the chain')
  -- One user action commits the complete preset. Roll the FX file back if
  -- saving the bank fails, so a failed Save cannot leave half a preset saved.
  local path=self.data..'/'..m.fx_chain;local previous=assert(U.read(path))
  assert(self.bank:save(edit))
  local saved,err=Model.save(self.data..'/bank.json',candidate)
  if not saved then
    local restored,why=U.write(path,previous)
    assert(restored,'Preset save failed; FX rollback failed: '..tostring(why))
    error(err)
  end
  self.definition.macros[index]=U.copy(edit)
  self.preset_drafts=self.preset_drafts or {};self.preset_drafts[edit.id]=edit
  if quiet then return end
  if self.selected_id==edit.id then self.edit_preview=nil;self.transform_override=nil end
  self.effective_macro=nil
  self.r.GetSetMediaTrackInfo_String(self.bank.macros[edit.id],'P_NAME','AM • '..edit.name,true)
  if self.selected_id==edit.id then self.reverse_override=nil;self.bank:activate(edit.id,edit.output_gain_db);self.explorer:set_transform(edit.source_transform);self:refresh_processing()end
end
function M:new_macro(duplicate)
  assert(#self.definition.macros<9,'The current bank already has nine macros')
  local id='macro_'..U.hash(self.r.genGuid())
  self:stash_preset()
  local original=duplicate and self:preset_draft(duplicate)
  local m=original and U.copy(original) or Model.macro(id,'New macro')
  local copy_name=original and original.name or ''
  if #copy_name>120 then
    copy_name=copy_name:sub(1,120)
    while not utf8.len(copy_name)do copy_name=copy_name:sub(1,-2)end
  end
  m.id=id;m.name=original and copy_name..' copy' or 'New macro';m.fx_chain='chains/'..id..'.RfxChain'
  local chain=original and self.bank:chain(original.id) or 'SHOW -1\nLASTSEL 0\nDOCKED 0\n'
  assert(U.write(self.data..'/'..m.fx_chain,chain));self.bank:add_macro(m)
  self.definition.macros[#self.definition.macros+1]=m
  for slot=1,9 do if not self.definition.slots[tostring(slot)]then self.definition.slots[tostring(slot)]=id;break end end
  self:save();self:activate(id);return m
end
function M:delete(id)
  local _,index=Model.find(self.definition,id);assert(index,'Unknown macro')
  if self.selected_id==id then self:activate(nil)end
  if self.previous_id==id then self.previous_id=nil end
  self.bank:remove(id);table.remove(self.definition.macros,index)
  if self.preset_drafts then self.preset_drafts[id]=nil end
  for slot,value in pairs(self.definition.slots)do if value==id then self.definition.slots[slot]=nil end end
  self:save()
end
function M:move(id,direction)
  local _,index=Model.find(self.definition,id);local other=index+direction
  if other>=1 and other<=#self.definition.macros then
    local t=self.definition.macros;t[index],t[other]=t[other],t[index];self:save()
  end
end
function M:slot(id,number)
  for k,v in pairs(self.definition.slots)do if v==id then self.definition.slots[k]=nil end end
  if number>0 then self.definition.slots[tostring(number)]=id end;self:save()
end
function M:import_chain(id,path)
  local m=assert(Model.find(self.definition,id));local text=assert(U.read(path))
  require('am.chunk').chain_body(text)
  -- Explicit editing is the only path that replaces plugin instances.
  self.preview:stop()
  local old=self.bank:chain(id);local staging=self.data..'/'..m.fx_chain..'.import'
  assert(U.write(staging,text))
  local ok,e=pcall(self.bank.load,self.bank,self.bank.macros[id],staging)
  if not ok then
    local restored=pcall(function()assert(U.write(staging,old));self.bank:load(self.bank.macros[id],staging)end)
    os.remove(staging)
    if not restored then
      self.bank.preserve=self.bank.preserve or {};self.bank.preserve[self.bank.macros[id]]=true
    end
    error(e)
  end
  os.remove(staging)
  self.bank:activate(self.selected_id,self:effective().output_gain_db)
  self.message='FX imported for audition. Save preset stores the complete sound.'
end
function M:export(open_dialog)
  assert(self.path and self.identity,'Select an audio file first')
  if (self.source_channels or Preview.channels(self.r,self.path))>2 and not Selection.get(self.definition.settings,self.source_channels)then
    self.message='Multichannel Preview is available; export supports mono/stereo sources only.';return
  end
  local macro=self:effective()
  local measurement=self:measurement()
  if macro.normalization.enabled or macro.source_peak_guard.enabled then
    assert(measurement and (measurement.status=='ready' or measurement.status=='silence'),'Wait for analysis before normalized export')
  end
  local gain=self:gain()
  local chain=self.selected_id and self.bank:chain(self.selected_id) or ''
  local snapshot=Export.snapshot(self.r,self.path,macro,chain,gain,self.identity,self.range,self.definition.settings)
  if snapshot.channel_mix and self.selected_id then
    snapshot.channel_mix.fx_channels=self.r.GetMediaTrackInfo_Value(self.bank.macros[self.selected_id],'I_NCHAN')
  end
  self.preview:stop()
  local basename=U.basename(self.path):gsub('%.[^.]+$',''):gsub('[^%w_%-\128-\255]','_')
  local name=basename..'_'..macro.id..'_'..os.date('%Y%m%d_%H%M%S')..'_'..U.hash(self.r.genGuid()):sub(1,4)
  local target=Export.render(self.r,snapshot,self.export_dir,name,open_dialog)
  self.message=open_dialog and 'Export snapshot opened in the native Render dialog.' or 'Exported: '..target
  return target
end
function M:commands(paused)
  local queue=self.r.GetExtState(M.EXT,'queue');if queue==''then return end
  self.r.DeleteExtState(M.EXT,'queue',false)
  for command in queue:gmatch('[^\n]+')do
    if paused then
      if command=='quit' then self.closed=true elseif command=='stop' then self.preview:stop()end
    elseif command:match('^slot:%d$')then
      local slot=command:sub(-1);if slot=='0'then self:activate(nil)elseif self.definition.slots[slot]then self:activate(self.definition.slots[slot])end
    elseif command=='reverse'then self:reverse()
    elseif command=='ab'then self:ab()
    elseif command=='play'then self:transport()
    elseif command=='replay'then self:play()
    elseif command=='stop'then self.preview:stop()
    elseif command=='export'then self:export(false)
    elseif command=='analyse'then self:analyse(true)
    elseif command=='edit'then self.editor_requested=true
    elseif command:match('^search:')then self.message='Search assistance is not included in this release. Use the Media Explorer search field.'
    elseif command=='quit'then self.closed=true end
  end
end
function M:render_drops()
  self.message=('Rendered %d selected drop(s)'):format(require('am.drop_render').selected(self.r))
end
function M:sync_range(replay)
  local valid,range=self.explorer:preview_range(self.path,self.identity)
  if not valid then return end -- The API can still describe the previous file.
  local changed=(range==nil)~=(self.range==nil)
  if range and self.range then changed=math.abs(range[1]-self.range[1])>1e-8 or math.abs(range[2]-self.range[2])>1e-8 end
  if changed then
    self.range=range;self.paused_position=nil;self.paused_source=nil;self.paused_length=nil;self.last_seek=nil
    -- Selecting a range is an audition gesture even when playback is stopped.
    -- Position zero is the section's start (its right edge when reversed).
    if replay and (range or self.preview:playing())then self:play(0,true)end
  end
  return changed
end
function M:sync_wave()
  local event=self.explorer:wave_event() or self.pending_wave
  self.pending_wave=nil
  if not event then return end
  local windows=require('am.platform').windows(self.r)
  if not U.path_equal(event.path,self.path,windows)then
    if U.path_equal(self.explorer:selection(),event.path,windows)then self.pending_wave=event end
    return
  end
  local length=U.path_equal(self.preview.path,self.path,windows) and self.preview.source_length
  if not length then
    local source=self.r.PCM_Source_CreateFromFile(self.path);if not source then return end
    local qn;length,qn=self.r.GetMediaSourceLength(source);self.r.PCM_Source_Destroy(source)
    if qn or length<=0 then return end
  end
  local source=U.clamp(event.fraction*length,0,length)
  local changed=self:sync_range(false)
  if changed and self.range then self:play(0,true);return end
  self.last_seek={path=self.path,source=source,length=length}
  if self.preview:playing()then
    if changed then self:play(Time.position(source,length,self.range,self:effective().source_transform),true);return end
    if self.preview.native and event.applied and select(2,self.preview:get('I_WAVE_SEEK'))==event.sequence then return end
    if self.preview:seek_source(source)then return end
    -- The audio thread can reach EOF between the first check and the seek.
  end
  if self.preview.eof_path and U.path_equal(self.preview.eof_path,self.path,windows)then
    -- The native handle is released at EOF. The one-shot next-file event may
    -- already be consumed, so retain natural completion separately from Stop.
    self:play(Time.position(source,length,self.range,self:effective().source_transform),true)
  else
    -- Explicit Stop/Pause keeps bookmark-only behavior; natural EOF can replay.
    self.paused_position=nil;self.paused_source=source;self.paused_length=length
  end
end
function M:check_project()
  if self.closed or self.cleaned then return false end
  -- Closing/replacing the last project can retain its pointer while removing
  -- every track. Check the owned input as well as the project itself.
  if not self.r.ValidatePtr(self.project,'ReaProject*') or not self.bank:valid(self.bank.input)then
    self:close();return false
  end
  return true
end
function M:tick()
  if not self:check_project()then return end
  if self.r.GetExtState(require('am.drop').EXT,'busy')=='1'then self:publish();return end
  self:publish();self.loudness:poll()
  if self.r.EnumProjects(-1)~=self.project then
    self.preview:stop();self:commands(true);self.message='Paused: return to the attached project.';return
  end
  local now=self.r.time_precise()
  if now-(self.last_live_pdc or 0)>.25 then
    self.last_live_pdc=now
    for _,t in ipairs(self.bank.tracks)do self.bank:live_pdc(t)end
  end
  if now-self.last_poll>=self.definition.settings.poll_ms/1000 then
    self.last_poll=now
    local path,reason=self.explorer:selection()
    if path~=self.path then
      self:select_source(path,reason)
      if self.identity then
        if self.definition.settings.autoplay or self.advance_path==path then
          self.advance_path=nil
          local ok,e=pcall(self.play,self);if not ok then self.message=tostring(e)end
        end
      end
    elseif path and now-(self.last_stat or 0)>.5 then
      self.last_stat=now;local identity=Loudness.identity(self.r,path)
      if not Loudness.same(identity,self.identity)then
        self:clear_source();self.identity=identity;self.paused_position=nil;self.paused_source=nil;self.paused_length=nil;self.last_seek=nil
        self:read_source_channels()
        self.message='Source changed. Replay to reload.'
      end
    end
  end
  self:sync_wave()
  self:sync_channel_waveform()
  for _=1,64 do
    local event=self.explorer:transport_event();if not event then break end
    local ok,e=pcall(self.native_transport,self,event);if not ok then self.message=tostring(e)end
  end
  self:commands()
  self:sync_transform()
  -- Native drag suspends this loop. Consume completion after any older queued
  -- controls, before range audition or EOF/next-file logic.
  if self.drop and self.drop:stop_preview()then self:sync_range(false)end
  self:sync_range(true)
  -- The preview getter records EOF before releasing the handle. Native ME's
  -- next-file action owns sorting/navigation; we do not reproduce its list.
  self.preview:playing()
  if self.preview.ended_path then
    local ended=self.preview.ended_path;self.preview.ended_path=nil
    if ended==self.path and not self.definition.settings.loop and self.explorer:window() and
        self.r.GetToggleCommandStateEx(32063,42004)==1 then
      self.explorer:command(40030)
      local next_path=self.explorer:selection()
      if next_path and next_path~=ended then self.advance_path=next_path end
    end
  end
  self:update_normalization()
  if self.drop then self.drop:tick()end
end
function M:close()
  if self.cleaned then return end;self.cleaned=true;self.closed=true
  if self.bar then pcall(self.bar.close,self.bar)end
  if self.drop then pcall(self.drop.close,self.drop)end
  if self.preview then pcall(self.preview.stop,self.preview)end
  if self.loudness then pcall(self.loudness.close,self.loudness)end
  if self.bank then
    if self.definition then
      self:stash_preset()
      for _,m in ipairs(self.definition.macros)do
        local track=self.bank.macros[m.id]
        -- REAPER has already discarded these FX on project close. Keep the
        -- saved preset; there is no remaining track to save or preserve.
        if self.bank:valid(track)then
          local ok,e=pcall(function()
            if self.bank.preserve and self.bank.preserve[track]then error('Manual FX recovery is required')end
            local draft=self.preset_drafts and self.preset_drafts[m.id]
            if draft then
              -- Closing has always saved FX. Save the matching sound parameters
              -- too, instead of silently keeping FX while dropping Pitch/Rate.
              self:apply_edit(draft,true)
            else assert(self.bank:save(m))end
          end)
          if not ok then
            self.bank.preserve=self.bank.preserve or {};self.bank.preserve[track]=true
            self.r.ShowConsoleMsg('SoundPrep: FX save failed; track preserved: '..tostring(e)..'\n')
          end
        end
      end
      if self.preset_drafts and self.preset_drafts.raw then
        local raw=self.preset_drafts.raw
        local ok,e=pcall(self.apply_edit,self,raw,true)
        if not ok then self.r.ShowConsoleMsg('SoundPrep: Raw save failed: '..tostring(e)..'\n')end
      end
    end
    pcall(self.bank.close,self.bank)
  end
  if self.explorer then
    local ok=pcall(self.explorer.restore,self.explorer)
    if ok then os.remove(self.data..'/recovery.json')end
  end
  if self.r.GetExtState(M.EXT,'session')==self.session then
    self.r.DeleteExtState(M.EXT,'heartbeat',false);self.r.DeleteExtState(M.EXT,'session',false);self.r.DeleteExtState(M.EXT,'queue',false)
  end
end
return M
