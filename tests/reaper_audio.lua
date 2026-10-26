-- Integration checks for source gain placement and an actively limiting export.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
assert(reaper.file_exists(reaper.GetResourcePath()..'/.audition-macro-test'),'Use the disposable test host')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local r=reaper;local U=require('am.util');local Model=require('am.model');local J=require('am.json')
local Bank=require('am.bank');local Preview=require('am.preview');local Export=require('am.export');local L=require('am.loudness')
local data=r.GetResourcePath()..'/audio-test';r.RecursiveCreateDirectory(data..'/chains',0)
local f=assert(io.open(data..'/audio.txt','w'));f:setvbuf('no')
local function log(...)for _,v in ipairs({...})do f:write(tostring(v),'\t')end;f:write('\n')end
local bank,preview,frames,peak=nil,nil,0,0
local function finish(ok,e)
  if preview then preview:stop()end;if bank then bank:close()end
  log(ok and 'PASS' or 'FAIL',e or '');f:close()
end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  local b=Model.defaults();local m=Model.macro('saturation','Saturation test')
  b.macros=J.array{m};b.slots={['1']=m.id};b.settings.loop=true
  assert(U.write(data..'/'..m.fx_chain,'SHOW -1\nBYPASS 0 0 0\n<JS loser/Saturation ""\n100\n>\nWAK 0 0\n'))
  bank=Bank.new(r,r.EnumProjects(-1),data,b,'audio-test')
  bank:activate('saturation',0)
  preview=Preview.new(r,r.EnumProjects(-1),bank.input)
  preview:start('/tmp/audition-macro-dev/test.wav',m,18,b.settings)
end,debug.traceback)
if not ok then finish(false,e);return end
local function loop()
  local ok,e=xpcall(function()
    frames=frames+1
    peak=math.max(peak,r.Track_GetPeakInfo(bank.macros.saturation,0))
    if frames==40 then
      log('preview_peak_after_monitor',peak)
      -- Pre-FX gain drives this saturation close to 1.0, then monitor is -6 dB.
      -- Applying D_VOLUME after FX instead would produce about 0.775.
      assert(peak>.45 and peak<.56,'Preview source gain is not where export expects it')
      preview:stop()
      local m=Model.macro('peak_test','Peak test');m.export.tail_seconds=0
      m.normalization.target_lufs=-6;m.export.normalize_final=true;m.export.true_peak_limit=true
      local path='/tmp/audition-macro-dev/impulse.wav'
      local snapshot=Export.snapshot(r,path,m,'',0,assert(L.identity(r,path)),nil,bank.definition.settings)
      local target=Export.render(r,snapshot,data..'/exports','peak_'..os.date('%H%M%S'),false)
      local source=assert(r.PCM_Source_CreateFromFile(target))
      local tp=-1-U.db(r.CalculateNormalization(source,3,-1,0,0))
      r.PCM_Source_Destroy(source);log('limited_export_true_peak',tp,'file',target)
      assert(tp<=-.9 and tp>=-1.3,'True peak limiter did not meet its ceiling')
    end
  end,debug.traceback)
  if not ok then finish(false,e)elseif frames>=40 then finish(true)else r.defer(loop)end
end
loop()
