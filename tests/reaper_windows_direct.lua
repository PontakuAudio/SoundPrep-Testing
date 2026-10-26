-- OS-specific bootstrap only; all acceptance cases live in reaper_direct_suite.lua.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local suite=dofile(root..'/tests/reaper_direct_suite.lua')
suite.run(reaper,root,{report='windows-review',driver='Dummy Audio',observe_progress=true})
