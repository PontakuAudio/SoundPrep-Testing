-- @description SoundPrep - Render selected Source + FX drops
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local ok,err=xpcall(function()require('am.drop_render').selected(reaper)end,debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err):match('^[^\n]+'),'SoundPrep',0)end
