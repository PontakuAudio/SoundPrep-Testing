local M={}
function M.send(r,command)
  local section='AuditionMacro.v1'
  local heartbeat=tonumber(r.GetExtState(section,'heartbeat'))
  if not heartbeat or r.time_precise()-heartbeat>3 then
    r.ShowConsoleMsg('SoundPrep: launch SoundPrep.lua first.\n');return
  end
  local queue=r.GetExtState(section,'queue')
  if #queue>2048 then queue=''end
  r.SetExtState(section,'queue',queue..command..'\n',false)
end
return M
