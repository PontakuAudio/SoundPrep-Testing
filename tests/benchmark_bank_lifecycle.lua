-- Deterministic control-layer lifecycle workload; no REAPER or audio timing.
-- Run unchanged against both revisions: lua tests/benchmark_bank_lifecycle.lua [cycles] [scans]
package.path='./lib/?.lua;'..package.path
local Bank=require('am.bank');local J=require('am.json')
local cycles=tonumber(arg[1])or 2000;local scans=tonumber(arg[2])or 1000
assert(cycles>=1 and cycles%1==0 and scans>=1 and scans%1==0,'Positive integer workload required')
local validates=0
local bank=setmetatable({project={},tracks={{valid=true},{valid=true}},macros={},pdc_options={},
  r={ValidatePtr=function()validates=validates+1;return true end,
    ValidatePtr2=function(_,t)return t.valid end,
    DeleteTrack=function(t)t.valid=false end,TrackFX_GetCount=function()return 0 end}},Bank)
collectgarbage('collect');local before=collectgarbage('count');local peak=before
local start=os.clock()
for _=1,cycles do
  local track={valid=true};bank.macros.editing=track;bank.tracks[#bank.tracks+1]=track
  bank.pdc_options[track]='PDC_OPTIONS 3';bank:remove('editing')
  peak=math.max(peak,collectgarbage('count'))
end
local editing=os.clock()-start
collectgarbage('collect');local retained=collectgarbage('count')-before
local keys=0;for _ in pairs(bank.pdc_options)do keys=keys+1 end
validates=0;local samples={};start=os.clock()
for i=1,scans do
  local tick=os.clock()
  for _,track in ipairs(bank.tracks)do bank:live_pdc(track)end
  samples[i]=os.clock()-tick
end
local scanning=os.clock()-start;table.sort(samples)
io.write(J.encode{scope='Lua control-layer mock API; not audio or DAW timing',cycles=cycles,scans=scans,
  retained_track_references=#bank.tracks,retained_pdc_keys=keys,project_validations=validates,
  editing_cpu_seconds=editing,scan_cpu_seconds=scanning,
  scan_p50_seconds=samples[math.ceil(scans*.5)],scan_p95_seconds=samples[math.ceil(scans*.95)],
  scan_p99_seconds=samples[math.ceil(scans*.99)],scan_max_seconds=samples[#samples],
  lua_retained_delta_kib=retained,lua_sampled_peak_delta_kib=peak-before})
