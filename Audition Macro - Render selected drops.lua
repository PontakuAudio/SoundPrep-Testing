-- @description Audition Macro - Render selected Source + FX drops (compatibility alias for SoundPrep)
-- Keep this file path so existing REAPER action IDs and shortcuts stay valid.
local directory=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]') or '.'
return dofile(directory..'/SoundPrep - Render selected drops.lua')
