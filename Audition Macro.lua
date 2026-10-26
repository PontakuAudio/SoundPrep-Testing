-- @description Audition Macro - Media Explorer companion (compatibility alias for SoundPrep)
-- @version 0.11.7
-- @author Pontaku Audio
-- Keep this file path so existing REAPER action IDs and shortcuts stay valid.
local directory=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]') or '.'
return dofile(directory..'/SoundPrep.lua')
