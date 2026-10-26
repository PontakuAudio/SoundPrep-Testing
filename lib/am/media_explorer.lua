local U=require('am.util')
local M={};M.__index=M
local SECTION=32063
function M.new(r)return setmetatable({r=r,controls={}},M)end
function M:window(open)
  local r=self.r
  if self.hwnd and r.JS_Window_IsWindow(self.hwnd) and r.JS_Window_IsVisible(self.hwnd)then return self.hwnd end
  self.hwnd=nil;self.controls={};self.selected=nil
  local w=r.JS_Window_Find(r.JS_Localize('Media Explorer','common'),true)
  -- REAPER may hide and reuse this HWND instead of destroying it on Close.
  if w and not r.JS_Window_IsVisible(w)then w=nil end
  if not w and open then w=r.OpenMediaExplorer('',false)end
  self.hwnd=w
  return w
end
function M:command(id)
  local w=assert(self:window(),'Open Media Explorer')
  if self.native_transport then self.r.AM_TransportSuppress(true)end
  local ok,e=pcall(self.r.JS_WindowMessage_Send,w,'WM_COMMAND',id,0,0,0)
  if self.native_transport then self.r.AM_TransportSuppress(false)end
  assert(ok,e)
end
function M:toggle(id,on)
  local state=self.r.GetToggleCommandStateEx(SECTION,id)
  assert(state>=0,'Unavailable Media Explorer option '..id)
  if (state==1)~=on then self:command(id)end
end
function M:control(id)
  local w=self:window();if not w then return end
  local c=self.controls[id]
  if not c or not self.r.JS_Window_IsWindow(c)then c=self.r.JS_Window_FindChildByID(w,id);self.controls[id]=c end
  return c
end
function M:text(id) local c=self:control(id);return c and self.r.JS_Window_GetTitle(c)end
function M:set_number(id,value)
  local c=assert(self:control(id),'Media Explorer control unavailable: '..id)
  self.r.JS_Window_SetTitle(c,tostring(value))
  self.r.JS_WindowMessage_Send(self:window(),'WM_COMMAND',id,512,0,0) -- EN_KILLFOCUS commits native edits
end
function M:transform()
  return {pitch_semitones=tonumber(self:text(1021)),rate=tonumber(self:text(1454)),
    preserve_pitch=self.r.GetToggleCommandStateEx(SECTION,40068)==1}
end
function M:tempo_factor()
  if not self:window() or self.r.GetToggleCommandStateEx(SECTION,40019)==1 then return 1 end
  local ok,_,mode,_,_,_,_,_,bpm=self.r.MediaExplorerGetLastPlayedFileInfo()
  if not ok or not U.finite(bpm) or bpm<=0 then return 1 end
  local multiplier=(mode&16)~=0 and .5 or ((mode&32)~=0 and 2 or ((mode&8)~=0 and 1 or 0))
  return multiplier>0 and self.r.Master_GetTempo()/bpm*multiplier or 1
end
function M:seek_step(length)
  local wave=self:control(1046)
  if wave and self.r.JS_Window_GetScrollInfo and self.r.JS_Window_GetClientSize then
    local ok,_,page,minimum,maximum=self.r.JS_Window_GetScrollInfo(wave,'h')
    local sized,width=self.r.JS_Window_GetClientSize(wave)
    local units=maximum-minimum
    if ok and sized and width>0 and units>0 and page>0 then return 5*length*page/(units*width)end
  end
  return .1
end
function M:set_transform(t)
  if not self:window()then return end
  self:set_number(1021,t.pitch_semitones);self:set_number(1454,t.rate)
  self:toggle(40068,t.preserve_pitch)
  self.last_transform=self:transform()
end
function M:transform_changes()
  if not self:window()then return end
  local current=self:transform();local previous=self.last_transform or {};local changed={}
  -- Ignore an incomplete edit (e.g. a lone minus sign) and values outside the
  -- supported source transform range. No project or bank writes on knob moves.
  for k,v in pairs(current)do
    local valid=k=='preserve_pitch' or (U.finite(v) and
      (k=='rate' and v>=.1 and v<=4 or k=='pitch_semitones' and v>=-24 and v<=24))
    if valid then if v~=previous[k]then changed[k]=v end;previous[k]=v end
  end
  self.last_transform=previous
  if next(changed)then return changed end
end
function M:quiesce()
  if self.owns_audio then return end
  -- Native Stop while already stopped *unloads* the waveform in REAPER 7.80.
  -- At attach/recovery (or with an older helper), a muted Play/Stop pair leaves
  -- the selected source loaded and guarantees that its EOF clock is stopped.
  self:volume(-150);self:command(1008);self:command(1009)
end
function M:attach_transport(w)
  if self.r.APIExists('AM_TransportAttach') and self.r.AM_TransportAttach(w)then
    self.native_transport=w;self.owns_audio=self.r.APIExists('AM_TransportOwnAudio')
    if self.owns_audio then self.r.AM_TransportOwnAudio(true)end
    self.wave_window=nil;self.wave_clock=nil
    self:attach_wave()
  end
end
function M:attach_wave()
  if not self.native_transport or not self.r.APIExists('AM_WaveAttach')then return end
  local wave,clock=self:control(1046),self:control(1016)
  if wave and clock and (self.wave_window~=wave or self.wave_clock~=clock)then
    if self.r.AM_WaveAttach(self.native_transport,wave,clock)then self.wave_window=wave;self.wave_clock=clock end
  end
end
function M:wave_event()
  if not self.native_transport or not self.r.APIExists('AM_WavePoll')then return end
  local text=self.r.AM_WavePoll()
  if text~=''then return require('am.json').decode(text)end
end
function M:volume(db)
  self:fader(db<=-144 and 0 or math.floor(self.r.DB2SLIDER(db)+.5))
end
function M:fader(position)
  local c=assert(self:control(1045),'Preview volume fader unavailable')
  -- Edit text changes are deferred by REAPER and can be lost on window close.
  -- The native trackbar + HSCROLL path commits synchronously (verified in 7.80).
  self.r.JS_WindowMessage_Send(c,'0x0405',1,0,position,0) -- TBM_SETPOS
  self.r.JS_WindowMessage_Send(self:window(),'WM_HSCROLL',4,position,self.r.JS_Window_AddressFromHandle(c),0)
end
function M:attach(on_snapshot)
  self:window(true)
  self.saved={volume=self:text(997),transform=self:transform(),fader_position=self.r.JS_WindowMessage_Send(assert(self:control(1045)),'0x0400',0,0,0,0),toggles={},preserve_display=true}
  for _,id in ipairs{1011,40015,40070,42014,40068,42026,42134,42182,42348,1068,42055,42183,42091}do self.saved.toggles[tostring(id)]=self.r.GetToggleCommandStateEx(SECTION,id)end
  if on_snapshot then on_snapshot(self.saved)end
  -- Autoplay-off alone can leave "continue previous media" selected, preventing
  -- new waveform peaks. Use REAPER's stop-and-display selection mode instead.
  self:command(40015)
  self:toggle(42014,false)
  if self.saved.toggles['42182']==1 then self:toggle(42182,false)end
  if self.saved.toggles['42348']==1 then self:toggle(42348,false)end
  -- Native audio is muted while SWS auditions. Do not propagate that temporary
  -- mute into items dragged from the standard browser.
  self:toggle(42055,false);self:toggle(42183,false)
  self:volume(-150)
  self:quiesce()
  local w=self:window()
  if not w then self.native_transport=nil;return end
  self:attach_transport(w)
end
function M:restore()
  if not self.saved then return end
  local owned=self.owns_audio
  if self.native_transport then self.r.AM_TransportDetach();self.native_transport=nil end
  self.wave_window=nil;self.wave_clock=nil
  self.owns_audio=nil
  local was_closed=not self:window()
  local focus=self.r.JS_Window_GetFocus()
  if self:window(true)then
    if not owned then self:quiesce()end
    if self.saved.fader_position then self:fader(self.saved.fader_position)
    elseif self.saved.volume then self:volume(tonumber(self.saved.volume) or -150)end
    if self.saved.transform then self:set_transform(self.saved.transform)end
    local restore={1011,42014,40068,42182,42348,1068,42055,42183}
    -- Older sessions forced these options on. Recover those snapshots, but
    -- leave display preferences (including edits made while attached) alone.
    if not self.saved.preserve_display then
      for _,id in ipairs{42091,42026,42134}do restore[#restore+1]=id end
    end
    for _,id in ipairs(restore)do
      local value=self.saved.toggles[tostring(id)]
      if value and value>=0 then self:toggle(id,value==1)end
    end
    if self.saved.toggles['40015']==1 then self:command(40015)
    elseif self.saved.toggles['40070']==1 then self:command(40070)end
    if was_closed then self:command(40069)end
    if focus and self.r.JS_Window_IsWindow(focus)then self.r.JS_Window_SetFocus(focus)end
  end
  self.saved=nil
end
function M:transport_event()
  if not self.r.APIExists('AM_TransportAttach')then return end
  local w=self:window()
  if not w then
    if self.native_transport then self.r.AM_TransportDetach()end
    self.native_transport=nil;self.owns_audio=nil;self.wave_window=nil;self.wave_clock=nil;return
  end
  if w and w~=self.native_transport then
    self:attach_transport(w)
  end
  self:attach_wave()
  local command=self.r.AM_TransportPoll()
  if command~=0 then return command end
end
function M:capture_range(path)
  -- Native preview remains muted. Starting it briefly refreshes the standard
  -- API's *last played* record, so another file's selection is never reused.
  self:volume(-150);self:command(1008)
  local ok,file,mode,a,b=self.r.MediaExplorerGetLastPlayedFileInfo()
  self:command(1009)
  assert(ok and U.path_equal(file,path),'Native preview did not resolve the same file')
  assert((mode&384)~=0 and b>a,'Select a time range in the Media Explorer waveform first')
  local source=assert(self.r.PCM_Source_CreateFromFile(path))
  local length=self.r.GetMediaSourceLength(source);self.r.PCM_Source_Destroy(source)
  return {a*length,b*length}
end
function M:ensure_waveform(path)
  local ok,file=self.r.MediaExplorerGetLastPlayedFileInfo()
  if not ok or not U.path_equal(file,path) then
    self:volume(-150);self:command(1008);self:command(1009)
  end
end
function M:preview_range(path,identity)
  if not path then return false end
  local ok,file,mode,a,b=self.r.MediaExplorerGetLastPlayedFileInfo()
  if not ok or not U.path_equal(file,path) then return false end
  -- REAPER exposes loop selection (128) and time selection (256) separately.
  if (mode&384)==0 or b<=a then return true,nil end
  local key=path..':'..tostring(identity and identity.mtime)..':'..tostring(identity and identity.size)
  if self.range_key~=key then
    local source=self.r.PCM_Source_CreateFromFile(path);if not source then return false end
    local length,qn=self.r.GetMediaSourceLength(source);self.r.PCM_Source_Destroy(source)
    if qn or length<=0 then return false end
    self.range_key=key;self.range_length=length
  end
  return true,{a*self.range_length,b*self.range_length}
end
local function selected_index(r,list)
  local n,indices=r.JS_ListView_ListAllSelItems(list)
  if n<1 then return end
  local focused=r.JS_ListView_GetFocusedItem(list)
  local index=tonumber(indices:match('^[^,]+'))
  for v in indices:gmatch('[^,]+')do if tonumber(v)==focused then index=focused;break end end
  return index
end
function M:full_selection_name(list)
  local saved={}
  for _,id in ipairs{42091,42026,42134}do saved[id]=self.r.GetToggleCommandStateEx(SECTION,id)end
  -- REAPER exposes the displayed row, not a selected-file API. Resolve hidden
  -- extensions/database paths synchronously, restoring the view before yielding.
  -- Never use the last-played record: it can belong to a different same-name file.
  local ok,name=pcall(function()
    self:toggle(42026,true);self:toggle(42091,true)
    local index=selected_index(self.r,list)
    return index and self.r.JS_ListView_GetItemText(list,index,0)
  end)
  local restore_error
  for _,id in ipairs{42091,42026,42134}do
    if saved[id]>=0 then
      local restored,err=pcall(self.toggle,self,id,saved[id]==1)
      if not restored then restore_error=restore_error or err end
    end
  end
  assert(not restore_error,restore_error);assert(ok,name)
  return name
end
function M:selection()
  local list=self:control(1001);if not list then return nil,'Media Explorer is closed' end
  local index=selected_index(self.r,list)
  if not index then return nil,'Select a file in Media Explorer' end
  local name=self.r.JS_ListView_GetItemText(list,index,0)
  local kind=self.r.JS_ListView_GetItemText(list,index,3)
  if name=='' or kind:find('<',1,true)then return nil,'Select an audio file' end
  local directory=self:text(1002) or ''
  local search=self:text(1015) or ''
  local old=self.selected
  if old and old.index==index and old.name==name and old.kind==kind and old.directory==directory and old.search==search then return old.path end
  local resolved=name
  if self.r.GetToggleCommandStateEx(SECTION,42091)==0 or
      (self.r.GetToggleCommandStateEx(SECTION,42026)~=1 and (search~='' or not self.r.file_exists(directory..'/'..name)))then
    resolved=self:full_selection_name(list)
  end
  if not resolved or resolved==''then return nil,'Select a file in Media Explorer' end
  local absolute=resolved:match('^[/\\]')or resolved:match('^%a:[/\\]')
  local path=absolute and resolved or directory..'/'..resolved
  if not self.r.file_exists(path)then return nil,'Cannot resolve the selected file path' end
  self.selected={index=index,name=name,kind=kind,directory=directory,search=search,path=path}
  return path
end
function M:focus_list()
  local list=self:control(1001);if list then self.r.JS_Window_SetFocus(list)end
end
function M:search_text()
  local w=assert(self:window(),'Open Media Explorer')
  if self.r.APIExists('AM_SearchRead')then
    local value=require('am.json').decode(self.r.AM_SearchRead(w))
    assert(value.text,'Cannot read the native search field');return value.text,value.composing
  end
  error('Search assistance requires the updated native helper. Restart REAPER after updating it.')
end
function M:search(query,expected)
  local c=assert(self:control(1015),'Open Media Explorer')
  local focus=self.r.JS_Window_GetFocus()
  if self.r.APIExists('AM_SearchWrite')then
    expected=expected or self:search_text()
    assert(self.r.AM_SearchWrite(self:window(),expected,query),'Search changed or input-method composition is active')
  else
    assert(expected==nil or self:text(1015)==expected,'Native search changed')
    self.r.JS_Window_SetTitle(c,query)
  end
  self.r.JS_WindowMessage_Send(self:window(),'WM_COMMAND',1015,5,0,0)
  -- On SWELL the combo notification alone is insufficient. Refresh search while
  -- preserving the user's Enter-only setting (same native action used by Thesaurus).
  self:command(42051);self:command(42051)
  if focus and self.r.JS_Window_IsWindow(focus)then self.r.JS_Window_SetFocus(focus)end
end
return M
