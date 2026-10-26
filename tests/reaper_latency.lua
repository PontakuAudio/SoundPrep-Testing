-- Actual signal response at the silent output probe, not API-call duration.
-- Run in an owned host prepared with tools/prepare_test_host.py.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_Preview_Create'),'Load native helper v0.7')
assert(r.file_exists(r.GetResourcePath()..'/Effects/am_response_probe'),'Prepare the isolated probe first')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local Model=require('am.model');local Bank=require('am.bank');local Preview=require('am.preview')
local J=require('am.json');local U=require('am.util');local Explorer=require('am.media_explorer')
local directory=r.GetResourcePath()..'/latency-test';r.RecursiveCreateDirectory(directory,0)
local log=assert(io.open(directory..'/latency.txt','w'));log:setvbuf('no')
local original=r.EnumProjects(-1)
r.Main_OnCommand(41929,0);local project=r.EnumProjects(-1)
r.SetMediaTrackInfo_Value(r.GetMasterTrack(project),'D_VOL',0)
local definition=Model.defaults();definition.macros={};definition.settings.loop=true;definition.settings.fade_ms=0
local bank=Bank.new(r,project,directory,definition,'latency')
r.gmem_attach('AuditionMacro.ResponseTest');r.gmem_write(0,0)
assert(r.TrackFX_AddByName(bank.raw,'JS: am_response_probe',false,1)>=0)
local explorer=Explorer.new(r);explorer:attach()
local macro=Model.effective(definition,nil);macro.source_transform.preserve_pitch=false
local events=J.array{};local preview,phase,step,deadline=nil,0,0,0
local done=false
local function finish(ok,e)
  if done then return end;done=true
  if preview then preview:stop()end
  local signal=assert(io.open(directory..'/signal.csv','w'));signal:write('time,rate,peak,size,crossings\n')
  for i=0,r.gmem_read(0)-1 do
    for j=0,4 do signal:write(('%.9f'):format(r.gmem_read(1+i*5+j)),j==4 and '\n' or ',')end
  end
  signal:close();U.write(directory..'/events.json',J.encode(events))
  explorer:restore();bank:close();r.SelectProjectInstance(original)
  log:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');log:close()
end
local function tick()
  local ok,e=xpcall(function()
    local now=r.time_precise();if now<deadline then return end
    if step==0 then
      phase=phase+1;if phase>3 then finish(true);return end
      if preview then preview:stop()end
      local api=phase==1 and setmetatable({APIExists=function(key)return key~='AM_Preview_Create' and r.APIExists(key)end},{__index=r}) or r
      preview=Preview.new(api,project,bank.input)
      macro.source_transform.pitch_semitones=0;macro.source_transform.rate=1
      explorer:set_transform(macro.source_transform)
      preview:start('/tmp/audition-macro-dev/media-fixtures/latency.wav',macro,0,definition.settings)
      step=1;deadline=now+.6;return
    end
    assert(preview:playing(),'Preview stopped during response measurement')
    local field=step<=6 and 'pitch_semitones' or 'rate'
    local value=field=='rate' and (step%2==1 and .5 or 1) or (step%2==1 and 12 or 0)
    macro.source_transform[field]=value
    events[#events+1]={time=now,backend=phase==1 and 'SWS' or phase==2 and 'Native' or 'Native controls',field=field,
      value=value,hz=field=='rate' and 1000*value or 1000*2^(value/12)}
    if phase==3 then
      local control=field=='rate' and 1454 or 1021
      r.JS_Window_SetTitle(explorer:control(control),tostring(value))
      r.BR_Win32_SendMessage(explorer:window(),0x111,(512<<16)|control,0)
      assert(select(2,preview:get(field=='rate' and 'D_PLAYRATE' or 'D_PITCH'))==value,'Control waited for Lua')
    else preview:reconfigure(macro,0,definition.settings)end
    step=step+1;deadline=now+.6;if step>12 then step=0;deadline=now+.9 end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
