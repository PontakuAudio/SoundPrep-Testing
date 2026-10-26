-- App settings share one controller across Cocoa and Win32.
local J=require('am.json');local U=require('am.util');local Loudness=require('am.loudness')
local M={}
local booleans={autoplay=true,loop=true,auto_render_drops=true,insert_handles=true,keep_fx_running=true}
local numbers={monitor_gain_db={-60,0},preview_fade_ms={0,50},fade_ms={0,50}}
function M.open(a)
  a.settings_panel_open=true;a.settings_panel_focus=(a.settings_panel_focus or 0)+1
end
function M.state(a)
  local s=a.definition.settings;local values={}
  for key in pairs(booleans)do values[key]=s[key]==true end
  for key in pairs(numbers)do values[key]=s[key]or 0 end
  return {open=a.settings_panel_open==true,focus=a.settings_panel_focus or 0,values=values,
    cache_available=type(a.choose_cache_directory)=='function' and type(a.set_cache_directory)=='function',
    cache_default=not s.cache_directory or s.cache_directory=='',
    cache_path=Loudness.cache_directory and Loudness.cache_directory(a.data or '',s)or (a.data or '')..'/cache',
    diagnostics=('Chain loads: %d   Switches: %d   Source starts: %d'):format((a.bank or {}).loads or 0,(a.bank or {}).switches or 0,(a.preview or {}).starts or 0),
    notice=a.settings_notice or 'Changes are saved automatically and shared across every preset.'}
end
local function live(a,key)
  local s=a.definition.settings
  if key=='loop'then
    a.explorer:toggle(1068,s.loop)
    if a.preview:playing()then a.preview:set('B_LOOP',s.loop and 1 or 0)end
  elseif key=='monitor_gain_db' or key=='keep_fx_running'then
    a.bank:activate(a.selected_id,a:effective().output_gain_db)
  end
end
function M.flush(a)
  local pending=a.settings_pending;if not pending then return end
  a.settings_pending=nil;a.settings_save_at=nil
  local ok,err=pcall(a.save_settings,a)
  if not ok then
    for key,value in pairs(pending)do a.definition.settings[key]=value end
    for key in pairs(pending)do pcall(live,a,key)end
    error(err,0)
  end
end
function M.tick(a)
  if a.settings_save_at and a.r.time_precise()>=a.settings_save_at then
    local ok,err=pcall(M.flush,a)
    if not ok then a.settings_notice='Could not save settings: '..tostring(err);a.message=a.settings_notice end
  end
end
local function dispatch(a,command)
  if command=='settings'then M.open(a);return end
  if command=='settings:close'then M.flush(a);a.settings_panel_open=false;return end
  local event=J.decode(command:sub(10));assert(type(event)=='table','Invalid settings command')
  if event.op=='set'then
    local key,value=event.key,event.value;local range=numbers[key]
    assert(booleans[key] or range,'Unknown app setting')
    assert(booleans[key] and type(value)=='boolean' or range and U.finite(value) and value>=range[1] and value<=range[2], 'Invalid setting value')
    assert(event.commit==nil or type(event.commit)=='boolean','Invalid settings commit')
    if a.definition.settings[key]~=value then
      a.settings_pending=a.settings_pending or {}
      if a.settings_pending[key]==nil then a.settings_pending[key]=a.definition.settings[key]end
      a.definition.settings[key]=value;live(a,key)
      a.settings_save_at=a.r.time_precise()+.25
    end
    if event.commit~=false then M.flush(a)end
  elseif event.op=='cache_choose' or event.op=='cache_default'then
    M.flush(a)
    assert(type(a.choose_cache_directory)=='function' and type(a.set_cache_directory)=='function','Cache folder selection is unavailable')
    if event.op=='cache_choose'then a:choose_cache_directory()else a:set_cache_directory('')end
  elseif event.op=='render_drops'then M.flush(a);a:render_drops()
  else error('Unknown settings action')end
  a.settings_notice=nil
end
function M.dispatch(a,command)
  local ok,err=pcall(dispatch,a,command)
  if not ok then a.settings_notice=tostring(err);error(err,0)end
end
return M
