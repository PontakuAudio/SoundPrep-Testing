local J=require('am.json')
local U=require('am.util')
local L=require('am.loudness')
local Analysis=require('am.analysis_policy')
local M={};M.__index=M
M.EXT='AuditionMacro.Drop.v1'
function M.new(r,app)
  if not r.APIExists('AM_DropAttach')then return nil end
  if require('am.platform').windows(r)then
    assert(r.APIExists('AM_DropDiagnostics') and (J.decode(r.AM_DropDiagnostics()).revision or 0)>=3,
      'Windows file-list D&D needs Native helper v0.10.6. Close REAPER, install the new DLL, then restart.')
  end
  local id=r.AddRemoveReaScript(true,0,app.root..'/internal/Process waveform drop.lua',true)
  assert(id>0,'Cannot register waveform drop processor')
  local list_support=r.APIExists('AM_DropAttachSources')
  if not list_support then app.message='File-list drops and Raw Normalize controls need helper v0.6. Close REAPER, update the helper, then restart.'end
  return setmetatable({r=r,app=app,command=id,list_support=list_support,
    pending=require('am.drop_pending').new(r,app),analysis=require('am.drop_analysis').new(r,app),peaks=require('am.peaks').new(r,app.project),
    resources=require('am.take_fx').new(r,app.project)},M)
end
function M:stop_preview()
  local r,a=self.r,self.app
  local session=r.GetExtState(M.EXT,'preview_stop')
  if session==''then return false end
  r.DeleteExtState(M.EXT,'preview_stop',false)
  if session~=a.session then return false end
  a.preview:stop()
  a.paused_position=nil;a.paused_source=nil;a.paused_length=nil;a.last_seek=nil
  a.pending_wave=nil;a.advance_path=nil
  return true
end
function M:tick()
  local r,a=self.r,self.app
  if not a:check_project()then return end
  if r.EnumProjects(-1)~=a.project then self:detach();return end
  local track=a.selected_id and a.bank.macros[a.selected_id]
  if a.selected_id and not a.bank:valid(track)then a:close();return end
  local message=r.GetExtState(M.EXT,'message')
  if message~=''then a.message=message;r.DeleteExtState(M.EXT,'message',false)end
  local wave=a.explorer:control(1046);local list=a.explorer:control(1001)
  self.peaks:tick()
  if self.analysis then self.analysis:tick()end
  if self.pending then self.pending:tick()end
  self.resources:tick()
  if not wave then self:detach();return end
  if not self.attached or self.wave~=wave or self.list~=list or not r.JS_Window_IsWindow(self.arrange) or
      (self.tcp and not r.JS_Window_IsWindow(self.tcp))then
    local main=r.GetMainHwnd();local arrange=r.JS_Window_FindChildByID(main,1000)
    if require('am.platform').windows(r)then self.tcp=r.JS_Window_FindEx(main,nil,'REAPERTCPDisplay','')
    else self.tcp=r.JS_Window_FindEx(main,main,'REAPERTCPDisplay','')end
    if self.list_support then self.attached=arrange and list and r.AM_DropAttachSources(main,arrange,wave,list,a.project,self.command)
    else self.attached=arrange and r.AM_DropAttach(main,arrange,wave,a.project,self.command)end
    self.wave=wave;self.list=list;self.arrange=arrange;self.last_state=nil
  end
  if not self.attached then a.message='Waveform drop helper could not attach. Update the native helper and restart REAPER.';return end
  local state={project=tostring(a.project),session=a.session,path=a.path,
    defer_items=self.pending~=nil,defer_analysis=self.analysis~=nil,
    identity=a.identity,macro=a:effective(),measurement=a:measurement(),settings=a.definition.settings,
    data=a.data,analyzer_key=a.loudness.analyzer_key,track=track and r.GetTrackGUID(track),input=r.GetTrackGUID(a.bank.input),
    pdc_options=track and a.bank.pdc_options and a.bank.pdc_options[track] or false}
  state.analysis_job=U.copy(a.loudness.active)
  if state.analysis_job then state.analysis_job.last_poll=nil end
  local analysis,analysis_reason
  if a.path and a.source_channels then analysis,analysis_reason=Analysis.resolve(a.path,a.source_channels,a.definition.settings,state.macro.normalization)end
  if not analysis_reason and L.same(a.loudness.wanted,a.identity)and Analysis.same(a.loudness.wanted_analysis,analysis)then
    state.analysis_error=a.loudness.error;state.analysis_identity=U.copy(a.identity)
    state.analysis_spec=U.copy(a.loudness.wanted_analysis)
  end
  if not U.equal(state,self.last_state)then
    r.SetExtState(M.EXT,'state',J.encode(state),false);self.last_state=U.copy(state)
  end
end
function M:detach()self.r.AM_DropDetach();self.attached=false;self.last_state=nil end
function M:close()
  self:detach()
  if self.analysis then self.analysis:close()end
  self.peaks:close()
  for _,key in ipairs{'state','prepared','captured','message','busy','last_drop_seconds','queue','analysis_queue','preview_stop'}do self.r.DeleteExtState(M.EXT,key,false)end
end
return M
