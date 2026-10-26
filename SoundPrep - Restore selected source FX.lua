-- @description SoundPrep - Activate selected Source + FX takes and restore their managed FX
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local ok,err=xpcall(function()require('am.take_fx').restore_selected(reaper)end,debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err):match('^[^\n]+'),'SoundPrep',0)end
