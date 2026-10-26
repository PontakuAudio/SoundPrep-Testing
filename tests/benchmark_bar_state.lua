-- Synthetic Lua state construction/comparison only; no REAPER/audio workload.
-- Run from the repository root: lua tests/benchmark_bar_state.lua
package.path='./lib/?.lua;'..package.path
local Bar=require('am.bar');local Model=require('am.model');local U=require('am.util')
local Channels=require('am.channel_panel');local Settings=require('am.settings_panel');local Names=require('am.channel_names')
local project={};local definition=Model.defaults();local macro=Model.effective(definition,nil)
for i=4,9 do definition.macros[i]=Model.macro('bench'..i,'Bench '..i)end
Names.read=function()local names={};for i=1,128 do names[i]='Microphone '..i end;return names end
local calls={channels=0,settings=0}
for key,module in pairs{channels=Channels,settings=Settings}do local original=module.state;module.state=function(...)calls[key]=calls[key]+1;return original(...)end end
local app={project=project,definition=definition,source_channels=128,path='/bench.wav',identity={size=100,mtime=1},message='',loudness={},
  preview={playing=function()return false end},effective=function()return macro end,gain=function()return 0,'off'end,measurement=function()end}
local bar=Bar.new({EnumProjects=function()return project end},app)
local previous=bar:state();local samples={}
for run=1,7 do
  local start=os.clock()
  for i=1,20000 do local state=bar:state();assert(U.equal(state,previous));previous=state end
  samples[run]=(os.clock()-start)*1e6/20000
end
table.sort(samples)
print(('median_us=%.3f channels=%d settings=%d'):format(samples[4],calls.channels,calls.settings))
