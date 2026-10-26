-- Actual signal regression: first-sample transient, PDC pre-roll, cold/warm
-- Macro switches and audible cursor. Only run in a disposable, muted host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_Preview_SetLatencyTrack'),'Load native helper v0.10.3')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local M=require('am.model');local B=require('am.bank');local P=require('am.preview')
local J=require('am.json');local U=require('am.util')
local dir=r.GetResourcePath()..'/fx-timing-test';r.RecursiveCreateDirectory(dir..'/chains',0)
local log=assert(io.open(dir..'/test.log','w'));log:setvbuf('no')
assert(U.write(r.GetResourcePath()..'/Effects/am_pdc_probe',assert(U.read(root..'/tests/audio_pdc_probe.jsfx'))))
assert(U.write(dir..'/chains/delay.RfxChain','SHOW -1\nBYPASS 0 0 0\n<JS am_pdc_probe ""\n>\nWAK 0 0\n'))
local samples={}
for i=0,95999 do samples[#samples+1]=string.pack('<i2',(i<96 or i>=48000 and i<48096) and 16000 or 0)end
local pcm=table.concat(samples)
local wav='RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,1,96000,192000,2,16)..'data'..string.pack('<I4',#pcm)..pcm
assert(U.write(dir..'/pulse.wav',wav))
local original=r.EnumProjects(-1);r.Main_OnCommand(41929,0);local project=r.EnumProjects(-1)
local master=r.GetMasterTrack(project);r.SetMediaTrackInfo_Value(master,'D_VOL',0)
assert(r.TrackFX_AddByName(master,'JS: am_response_probe',false,1)>=0)
r.gmem_attach('AuditionMacro.ResponseTest');r.gmem_write(0,0)
local definition=M.defaults();definition.macros=J.array{M.macro('delay','Delay')};definition.slots={['1']='delay'}
definition.settings.monitor_gain_db=0
local bank=B.new(r,project,dir,definition,'fx-timing');local preview=P.new(r,project,bank.input)
local phase,due,gap,done=0,r.time_precise()+.3,false,false
local events=J.array{};local phase_at,report
local function finish(ok,e)
  if done then return end;done=true
  preview:stop();bank:close();r.SelectProjectInstance(original)
  U.write(dir..'/events.json',J.encode(events))
  log:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');log:close()
end
local function tick()
  local ok,e=xpcall(function()
    local now=r.time_precise()
    if phase>0 and not gap and now-phase_at>.65 and not report then
      report=J.decode(r.AM_Preview_Diagnostics());report.phase=phase
      local delayed=phase==2 or phase==4
      assert(math.abs(report.fx_latency-(delayed and .1 or 0))<1/96000,'Wrong FX latency')
      local expected=report.device_latency+report.fx_latency
      local lead=report.render_position-report.audible_position
      assert(math.abs(lead-expected)<report.block_size/report.sample_rate+.025,'Cursor did not follow audible position: '..J.encode(report))
    end
    if now<due then return end
    if phase>0 and not gap then
      local peaks={};local previous=-1
      for i=0,r.gmem_read(0)-1 do
        local at=r.gmem_read(1+i*5);local peak=r.gmem_read(3+i*5)
        if at>=phase_at and at<now and peak>.01 then
          if at-previous>.1 then peaks[#peaks+1]={at=at-phase_at,peak=peak}
          else peaks[#peaks].peak=math.max(peaks[#peaks].peak,peak)end
          previous=at
        end
      end
      assert(#peaks==2,'Lost or duplicated transient in phase '..phase..': '..J.encode(peaks))
      assert(math.abs(peaks[2].at-peaks[1].at-.5)<.05,'Audio skipped ahead during PDC pre-roll')
      assert(math.abs(peaks[1].peak-peaks[2].peak)<.005,'First transient was faded/truncated')
      assert(peaks[1].peak>.47,'Transient was attenuated')
      -- Replay a warmed delay chain: onset must be only the plugin delay plus
      -- at most one device block and one scheduler interval (before DAC).
      local delay=(phase==2 or phase==4) and .1 or 0
      assert(peaks[1].at<delay+report.block_size/report.sample_rate+.04,'Extra preview buffering')
      report.peaks=peaks;events[#events+1]=report
      log:write('phase '..phase..' '..J.encode(report)..'\n')
      preview:stop();gap=true;due=now+.3;return
    end
    gap=false;phase=phase+1;if phase>4 then finish(true);return end
    definition.settings.keep_fx_running=phase>2
    bank:activate((phase==2 or phase==4) and 'delay' or nil)
    preview:latency_track(bank.chosen)
    assert(not bank:chain('delay'):find('PDC_OPTIONS 2',1,true),'Live PDC leaked into render chain')
    report=nil;phase_at=r.time_precise()
    preview:start(dir..'/pulse.wav',M.effective(definition,nil),0,definition.settings)
    due=phase_at+1.35
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
