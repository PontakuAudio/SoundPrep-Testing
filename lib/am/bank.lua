local U=require('am.util');local C=require('am.chunk')
local M={};M.__index=M
local OWNER='P_EXT:AuditionMacroOwner'
local function source_channels(count)
  -- REAPER's send encoding reserves 0 for stereo and 1 << 10 for mono;
  -- wider sends encode half the (even) width in the upper bits.
  return count==2 and 0 or (count//2)<<10
end
local function track_channels(self,t,count)
  self.r.SetMediaTrackInfo_Value(t,'I_NCHAN',count)
  self.r.SetMediaTrackInfo_Value(t,'C_MAINSEND_OFFS',0)
  self.r.SetMediaTrackInfo_Value(t,'C_MAINSEND_NCH',0)
end
local function pin_state(r,t)
  if not(r.TrackFX_GetIOSize and r.TrackFX_GetPinMappings)then return end
  local values,highest={},2
  for fx=0,r.TrackFX_GetCount(t)-1 do
    local kind,inputs,outputs=r.TrackFX_GetIOSize(t,fx)
    if not kind or kind<0 or not inputs or not outputs then return end
    values[#values+1]=inputs..'/'..outputs
    -- Container outer pins are in track coordinates; child pins are local to
    -- the container and must not be interpreted as track channel numbers.
    for direction=0,1 do
      for pin=0,(direction==0 and inputs or outputs)-1 do
        for bank=0,1 do
          local lo,hi=r.TrackFX_GetPinMappings(t,fx,direction,pin+bank*0x1000000)
          if type(lo)~='number' or type(hi)~='number'then return end
          for part,bits in ipairs{lo&0xffffffff,hi&0xffffffff}do
            values[#values+1]=tostring(bits)
            for bit=31,0,-1 do
              if bits&(1<<bit)~=0 then highest=math.max(highest,bank*64+(part-1)*32+bit+1);break end
            end
          end
        end
      end
    end
  end
  return table.concat(values,','),2*math.ceil(highest/2)
end
local function macro_channels(self,t,count)
  self.channel_state=self.channel_state or {}
  local before=self.channel_state[t]
  local current=self.r.GetMediaTrackInfo_Value(t,'I_NCHAN')
  local minimum=before and before.minimum or current
  local pin_minimum=before and before.pin_minimum or 2
  if before and current~=before.applied then -- Manual/plugin resize.
    minimum=current;pin_minimum=math.min(pin_minimum,current)
  end
  local pins,mapped=pin_state(self.r,t)
  if not pins then minimum=math.max(minimum,current) -- Unknown routing: never truncate it.
  elseif before and pins~=before.pins then
    -- Detect pin edits inside a width already expanded for a prior source.
    -- Unchanged default pins beyond the active width do not force expansion.
    pin_minimum=math.min(current,mapped)
  end
  local width=math.max(count,minimum,pin_minimum)
  self.channel_state[t]={minimum=minimum,pin_minimum=pin_minimum,applied=width,pins=pins}
  return width
end
local function forget_track(self,t)
  for i=#self.tracks,1,-1 do if self.tracks[i]==t then table.remove(self.tracks,i)end end
  if self.pdc_options then self.pdc_options[t]=nil end
  if self.preserve then self.preserve[t]=nil end
  if self.channel_state then self.channel_state[t]=nil end
end
function M.new(r,project,root,bank,session)
  local self=setmetatable({r=r,project=project,root=root,definition=bank,session=session,tracks={},macros={},loads=0,switches=0,channels=2},M)
  local ok,err=xpcall(function()
    self.input=self:add_track('AM • Preview input',0)
    r.SetMediaTrackInfo_Value(self.input,'B_MAINSEND',0)
    self.raw=self:add_track('AM • Raw',bank.settings.monitor_gain_db);self:send(self.raw)
    for _,m in ipairs(bank.macros)do self:add_macro(m)end
    self:activate(nil)
  end,debug.traceback)
  if not ok then self:close();error(err)end
  return self
end
function M:valid(t)
  -- ValidatePtr2 itself rejects a closed project before checking the track.
  return t and self.r.ValidatePtr(self.project,'ReaProject*') and self.r.ValidatePtr2(self.project,t,'MediaTrack*')
end
function M:add_track(name,gain_db,channels)
  local r=self.r
  assert(r.EnumProjects(-1)==self.project,'Switch back to the attached project')
  local selected={};for i=0,r.CountSelectedTracks(self.project)-1 do selected[#selected+1]=r.GetSelectedTrack(self.project,i)end
  local index=r.CountTracks(self.project)
  local depth=0
  for i=0,index-1 do depth=depth+r.GetMediaTrackInfo_Value(r.GetTrack(self.project,i),'I_FOLDERDEPTH')end
  if depth>0 then index=0 end -- Never route through an unfinished user folder.
  r.InsertTrackAtIndex(index,false)
  local t=assert(r.GetTrack(self.project,index),'Could not create preview track')
  self.tracks[#self.tracks+1]=t
  r.GetSetMediaTrackInfo_String(t,OWNER,self.session,true)
  r.GetSetMediaTrackInfo_String(t,'P_NAME',name,true)
  r.SetMediaTrackInfo_Value(t,'B_MAINSEND',0)
  r.SetMediaTrackInfo_Value(t,'B_SHOWINTCP',0);r.SetMediaTrackInfo_Value(t,'B_SHOWINMIXER',0)
  r.SetMediaTrackInfo_Value(t,'I_SOLODEFEAT',1)
  r.SetMediaTrackInfo_Value(t,'I_RECARM',0)
  r.SetMediaTrackInfo_Value(t,'I_PERFFLAGS',3) -- Owned live preview path: no media buffer / anticipative FX.
  track_channels(self,t,channels or self.channels or 2)
  -- Seed the empty track's fader state, not only its smooth target. Otherwise
  -- the first device block can still use the new track's default unity gain.
  -- Do this before loading any plugin: no FX instance is reloaded on playback.
  r.SetMediaTrackInfo_Value(t,'D_VOL',U.gain(gain_db or 0))
  assert(r.SetTrackStateChunk(t,C.read_track(r,t),false),'Cannot initialize preview gain')
  r.SetTrackSelected(t,false);for _,tr in ipairs(selected)do r.SetTrackSelected(tr,true)end
  return t
end
function M:send(t)
  local i=self.r.CreateTrackSend(self.input,t)
  assert(i>=0,'Cannot create preview route')
  local channels=self.channels or 2
  track_channels(self,t,t==self.raw and channels or macro_channels(self,t,channels))
  self.r.SetTrackSendInfo_Value(self.input,0,i,'I_SENDMODE',0)
  self.r.SetTrackSendInfo_Value(self.input,0,i,'D_VOL',1)
  self.r.SetTrackSendInfo_Value(self.input,0,i,'I_SRCCHAN',source_channels(self.channels or 2))
  self.r.SetTrackSendInfo_Value(self.input,0,i,'I_DSTCHAN',0)
end
function M:set_channels(count,bypass_fx)
  assert(U.finite(count) and count>=1 and count<=128 and count%1==0,'Preview supports 1 to 128 channels')
  bypass_fx=bypass_fx==true
  local policy_changed=bypass_fx~=(self.fx_bypassed==true)
  self.fx_bypassed=bypass_fx
  if policy_changed then self.routing_dirty=true end
  local channels=math.max(2,2*math.ceil(count/2))
  if channels==(self.channels or 2)then
    if policy_changed and self.chosen then self:activate(self.active,self.active_gain_db)end
    return channels
  end
  local owned={}
  for _,t in ipairs(self.tracks)do
    assert(self:valid(t),'A preview track was removed');owned[t]=true
  end
  -- The caller stops/clears the source before a channel transition. Configure
  -- owned tracks directly so existing FX instances and unsaved edits survive.
  for _,t in ipairs(self.tracks)do
    local width=(t==self.input or t==self.raw)and channels or macro_channels(self,t,channels)
    track_channels(self,t,width)
  end
  local r=self.r
  -- Deleting a Macro renumbers later sends. Resolve their current destinations
  -- rather than retaining stale send indices or touching unrelated routes.
  for i=0,r.GetTrackNumSends(self.input,0)-1 do
    if owned[r.GetTrackSendInfo_Value(self.input,0,i,'P_DESTTRACK')]then
      r.SetTrackSendInfo_Value(self.input,0,i,'I_SRCCHAN',source_channels(channels))
      r.SetTrackSendInfo_Value(self.input,0,i,'I_DSTCHAN',0)
    end
  end
  -- Main sends preserve the channel numbering, but actual audible channels
  -- depend on the user's Master/hardware routing. Never reconfigure those.
  self.channels=channels
  if policy_changed and self.chosen then self:activate(self.active,self.active_gain_db)end
  return channels
end
function M:load(t,path)
  local text,e=U.read(path);assert(text,e)
  self.pdc_options=self.pdc_options or {};self.pdc_options[t]=C.pdc_options(text) or false
  local chunk=C.read_track(self.r,t)
  local next_chunk=C.replace(chunk,C.fresh(text,self.r.genGuid))
  assert(self.r.SetTrackStateChunk(t,next_chunk,false),'Cannot load FX chain')
  self:live_pdc(t)
  self.routing_dirty=true -- Chunks may replace gain/bypass values too.
  -- Loading a state chunk can open the chain even with SHOW -1 (7.80/macOS).
  -- A preloaded audition bank must never leave plugin editors on screen.
  self.r.TrackFX_Show(t,0,0)
  for i=0,self.r.TrackFX_GetCount(t)-1 do self.r.TrackFX_Show(t,i,2)end
  self.loads=self.loads+1
end
function M:live_pdc(t)
  -- PDC pre-roll can consume a live preview before it reaches the output.
  -- Keep each owned chain in live mode; plugin lookahead itself still applies.
  if self:valid(t) and self.r.TrackFX_GetCount(t)>0 then
    local ok,mode=self.r.TrackFX_GetNamedConfigParm(t,0,'chain_pdc_mode')
    if not ok or mode~='2'then
      assert(self.r.TrackFX_SetNamedConfigParm(t,0,'chain_pdc_mode','2'),
        'REAPER with chain_pdc_mode support is required for live FX preview')
    end
  end
end
function M:add_macro(m)
  self.macros=self.macros or {}
  assert(not self.macros[m.id],'Duplicate runtime macro')
  -- Load at the normal stereo width before widening for the current source,
  -- so plugin-created channel requirements remain distinct from preview width.
  local t=self:add_track('AM • '..m.name,m.output_gain_db+self.definition.settings.monitor_gain_db,2)
  local ok,err=pcall(self.load,self,t,self.root..'/'..m.fx_chain)
  if not ok then self.r.DeleteTrack(t);forget_track(self,t);error(err)end
  self.macros[m.id]=t;self:send(t)
  self.r.SetMediaTrackInfo_Value(t,'D_VOL',U.gain(m.output_gain_db+self.definition.settings.monitor_gain_db))
  self.r.SetMediaTrackInfo_Value(t,'I_FXEN',not self.fx_bypassed and self.definition.settings.keep_fx_running and 1 or 0)
end
function M:activate(id,gain_db)
  assert(self:valid(self.input),'Preview tracks were removed')
  local r=self.r;local chosen=id and self.macros[id] or self.raw
  assert(self:valid(chosen),'Macro is not loaded')
  self:live_pdc(chosen)
  local keep=self.definition.settings.keep_fx_running and not self.fx_bypassed
  local gain=U.gain((id and (gain_db or 0) or 0)+self.definition.settings.monitor_gain_db)
  -- Only the departing/arriving branches change on a normal switch. FX remain
  -- instantiated. Full reconciliation is reserved for policy/chunk changes.
  local full=self.routing_dirty or self.keep_running~=keep or not self.chosen
  if full then
    for _,t in pairs(self.macros)do
      assert(self:valid(t),'A preview track was removed')
      r.SetMediaTrackInfo_Value(t,'B_MAINSEND',t==chosen and 1 or 0)
      r.SetMediaTrackInfo_Value(t,'I_FXEN',not self.fx_bypassed and (t==chosen or keep)and 1 or 0)
    end
    r.SetMediaTrackInfo_Value(self.raw,'B_MAINSEND',chosen==self.raw and 1 or 0)
    r.SetMediaTrackInfo_Value(self.raw,'D_VOL',U.gain(self.definition.settings.monitor_gain_db))
  elseif self.chosen~=chosen then
    assert(self:valid(self.chosen),'A preview track was removed')
    r.SetMediaTrackInfo_Value(self.chosen,'B_MAINSEND',0)
    r.SetMediaTrackInfo_Value(chosen,'B_MAINSEND',1)
    if not keep then
      if self.chosen~=self.raw then r.SetMediaTrackInfo_Value(self.chosen,'I_FXEN',0)end
      if chosen~=self.raw then r.SetMediaTrackInfo_Value(chosen,'I_FXEN',self.fx_bypassed and 0 or 1)end
    end
  end
  if full or self.chosen~=chosen or self.active_gain~=gain then r.SetMediaTrackInfo_Value(chosen,'D_VOL',gain)end
  if full then r.SetMediaTrackInfo_Value(self.input,'D_VOL',1)end
  self.routing_dirty=false;self.keep_running=keep;self.chosen=chosen;self.active_gain=gain
  self.active=id;self.active_gain_db=gain_db;self.switches=self.switches+1
end
function M:clear_buffers()
  local r=self.r;local routes={}
  for _,t in pairs(self.macros)do
    assert(self:valid(t),'A preview track was removed')
    routes[t]=r.GetMediaTrackInfo_Value(t,'B_MAINSEND')
  end
  for t in pairs(routes)do r.SetMediaTrackInfo_Value(t,'B_MAINSEND',0)end
  local function reset(t,fx)
    if r.TrackFX_GetOffline(t,fx)then return end
    local container,count=r.TrackFX_GetNamedConfigParm(t,fx,'container_count')
    if container then
      for i=0,assert(tonumber(count))-1 do
        local ok,child=r.TrackFX_GetNamedConfigParm(t,fx,'container_item.'..i)
        assert(ok,'Cannot inspect preview FX container');reset(t,assert(tonumber(child)))
      end
      return
    end
    local _,kind=r.TrackFX_GetNamedConfigParm(t,fx,'fx_type')
    if r.TrackFX_GetEnabled(t,fx) and (kind=='VST' or kind=='VST3' or kind=='CLAP')then
      -- REAPER flushes these formats on per-plugin bypass. I_FXEN alone
      -- suspends the chain with its old audio still buffered.
      r.TrackFX_SetEnabled(t,fx,false);r.TrackFX_SetEnabled(t,fx,true)
    else
      -- JSFX/AU and bypassed plugins need an instance reset. Offline/online
      -- retains parameters, GUID, bypass state and unsaved edits.
      r.TrackFX_SetOffline(t,fx,true);r.TrackFX_SetOffline(t,fx,false)
    end
  end
  local ok,err=xpcall(function()
    for t in pairs(routes)do
      for fx=0,r.TrackFX_GetCount(t)-1 do reset(t,fx)end
      self:live_pdc(t)
    end
  end,debug.traceback)
  for t,value in pairs(routes)do if self:valid(t)then r.SetMediaTrackInfo_Value(t,'B_MAINSEND',value)end end
  if not ok then error(err)end
end
function M:chain(id)
  local t=assert(self.macros[id],'No macro selected')
  assert(self:valid(t),'Preview track was removed')
  local chunk=C.read_track(self.r,t)
  local fx=C.block(chunk,'FXCHAIN')
  -- The live-only PDC policy must never reach renders, saved chains or takes.
  return fx and C.pdc_options(fx,self.pdc_options and self.pdc_options[t],true) or 'SHOW -1\nLASTSEL 0\nDOCKED 0\n'
end
function M:save(m)
  local path=self.root..'/'..m.fx_chain;local text=C.portable(self:chain(m.id))
  if U.read(path)==text then return true end
  return U.write(path,text)
end
function M:edit(id)
  local t=assert(self.macros[id],'Select a macro before editing FX')
  self.r.TrackFX_Show(t,0,1)
end
function M:remove(id)
  local t=self.macros[id];if not t then return end
  if self:valid(t)then self.r.DeleteTrack(t)end
  self.macros[id]=nil;forget_track(self,t)
end
function M:close()
  local warnings={}
  for i=#self.tracks,1,-1 do
    local t=self.tracks[i]
    if self:valid(t)then
      local _,owner=self.r.GetSetMediaTrackInfo_String(t,OWNER,'',false)
      if owner==self.session and self.r.CountTrackMediaItems(t)==0 and not (self.preserve and self.preserve[t]) then self.r.DeleteTrack(t)
      else
        warnings[#warnings+1]='A changed preview track was preserved'
        self.r.SetMediaTrackInfo_Value(t,'D_VOL',0)
        self.r.SetMediaTrackInfo_Value(t,'B_SHOWINTCP',1);self.r.SetMediaTrackInfo_Value(t,'B_SHOWINMIXER',1)
      end
    end
  end
  self.tracks={};self.channel_state={};return warnings
end
return M
