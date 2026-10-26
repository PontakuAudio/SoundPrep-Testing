-- Historical worker integration fixture; run from its pre-v0.10.16 revision.
-- Current D&D coverage: reaper_direct.lua and reaper_drop_edit.lua.
-- Owned REAPER only. Exercises cold-drop batch rendering in the isolated worker,
-- then cached reuse without launching a worker or opening parent project tabs.
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local E=require('am.export');local I=require('am.insert');local M=require('am.model');local L=require('am.loudness');local D=require('am.drop_render')
local f=assert(io.open(r.GetResourcePath()..'/drop-worker.txt','w'));f:setvbuf('no')
local ok,err=xpcall(function()
 local project=r.EnumProjects(-1);local tabs=0;while r.EnumProjects(tabs)do tabs=tabs+1 end
 local dir=r.GetResourcePath()..'/cold-drop-'..U.hash(r.genGuid());r.RecursiveCreateDirectory(dir,0)
 local file='/tmp/audition-macro-dev/test.wav';local macro=M.macro('cold','Cold drop');macro.export.tail_seconds=0
 macro.source_transform.reverse=true;macro.source_transform.rate=.5
 local snapshot=E.snapshot(r,file,macro,'',0,L.identity(r,file),{.2,.7},{fade_ms=0})
 local state={data=dir,settings={python='',insert_handles=false},prepared={}}
 local started=r.time_precise()
 local paths,staging=D.prepare(r,root,state,{{snapshot=snapshot,length=1}},dir..'/media')
 f:write('cold worker seconds ',tostring(r.time_precise()-started),'\n')
 assert(r.EnumProjects(-1)==project and not r.EnumProjects(tabs),'Parent project tabs changed')
 local render=E.render;E.render=function()error('Parent renderer must not run')end
 local success,plan=pcall(I.prepare,r,snapshot,1,false,dir..'/media',paths);E.render=render;assert(success,plan)
 assert(math.abs(plan.duration-1)<1e-9 and plan.offset==0 and r.file_exists(plan.target))
 D.cleanup(r,staging)
 local proxy=setmetatable({ExecProcess=function()error('Warm drop must not launch a worker')end},{__index=r})
 local _,unused=D.prepare(proxy,root,state,{{snapshot=snapshot,length=1}},dir..'/media');assert(not unused)
 assert(r.EnumProjects(-1)==project and not r.EnumProjects(tabs),'Warm drop changed parent project')
 f:write('cold/cached render, reverse/rate/crop, no parent tabs or foreground renderer: PASS\n')
end,debug.traceback)
f:write(ok and 'PASS\n' or 'FAIL '..tostring(err)..'\n');f:close()
