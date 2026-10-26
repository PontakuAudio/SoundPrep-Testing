-- Offline host rendering only; not device latency or live callback CPU.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use a fresh disposable test host')
package.path=root..'/lib/?.lua;'..package.path
local J=require('am.json');local U=require('am.util');local M=require('am.model')
local E=require('am.export');local D=require('am.render_item');local L=require('am.loudness')
local report={scope='real REAPER offline render; no device latency measurement',version=r.GetAppVersion(),
  sample_rate=48000,results=J.array{}}
local ok,err=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  local path=host.."/media 素材/test one's 音.wav"
  local chain='BYPASS 0 0 0\n<JS utility/volume_pan ""\n-12 0 0\n>\nWAK 0 0\n'
  local directory=host..'/render-benchmark';r.RecursiveCreateDirectory(directory,0)
  local project=r.EnumProjects(-1)
  for iteration=1,7 do
    for case=1,3 do
      local macro=M.effective(M.defaults(),case==1 and 'heavy' or 'dark')
      macro.output_gain_db=-3;macro.source_transform.reverse=case==3
      local snapshot=E.snapshot(r,path,macro,chain,6,assert(L.identity(r,path)),case==3 and {.2,1.1} or nil,M.defaults().settings)
      D.stamp(r,snapshot)
      local started=r.time_precise()
      local output=D.render(r,snapshot,directory,'case'..case..'-'..iteration)
      local elapsed=r.time_precise()-started
      local source=assert(r.PCM_Source_CreateFromFile(output))
      assert(r.GetMediaSourceSampleRate(source)==48000,'Unexpected output rate')
      r.PCM_Source_Destroy(source)
      assert(r.EnumProjects(-1)==project and r.CountTracks(0)==0,'Renderer leaked tracks or changed project')
      report.results[#report.results+1]={iteration=iteration,case=case,seconds=elapsed}
    end
  end
end,debug.traceback)
report.status=ok and 'PASS' or 'FAIL';report.error=err
assert(U.write(host..'/render-benchmark.json',J.encode(report)))
