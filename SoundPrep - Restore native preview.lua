-- @description Restore native Media Explorer settings after an interrupted session
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local heartbeat=tonumber(reaper.GetExtState('AuditionMacro.v1','heartbeat'))
if heartbeat and reaper.time_precise()-heartbeat<3 then require('am.action').send(reaper,'quit');return end
local ok,result=pcall(require('am.recovery').restore,reaper,root..'/data')
reaper.ShowMessageBox(ok and (result and 'Native preview settings restored. Recovered tracks are muted and visible.' or 'No recovery record found.') or tostring(result),'SoundPrep',0)
