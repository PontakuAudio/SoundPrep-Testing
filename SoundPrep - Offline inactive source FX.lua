-- @description SoundPrep - Offline inactive Source + FX takes in this project
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local r=reaper;local project=r.EnumProjects(-1)
r.Undo_BeginBlock2(project)
local ok,err=xpcall(function()require('am.take_fx').offline_project(r,project);r.UpdateArrange()end,debug.traceback)
r.Undo_EndBlock2(project,'Offline inactive SoundPrep Source + FX',-1)
if not ok then r.ShowMessageBox(tostring(err):match('^[^\n]+'),'SoundPrep',0)end
