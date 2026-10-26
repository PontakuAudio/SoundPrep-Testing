-- @description SoundPrep - AB
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]actions[/\\]')
package.path=root..'/lib/?.lua;'..package.path
require('am.action').send(reaper,'ab')
