local P=require('am.peaks');local J=require('am.json')
local ext,now,destroyed,finalized,selected={},0,0,0,0
local calls=0;local r={GetExtState=function(_,key)return ext[key]or''end,
  SetExtState=function(_,key,value)ext[key]=value end,DeleteExtState=function(_,key)ext[key]=nil end,
  time_precise=function()return now end,PCM_Source_CreateFromFile=function(path)return{path=path,left=10}end,
  PCM_Source_BuildPeaks=function(source,mode)
    calls=calls+1;if mode==0 then return source.path=='cached'and 0 or 1 end
    if mode==2 then assert(source.left==0);finalized=finalized+1;return 0 end
    now=now+.003;source.left=math.max(0,source.left-1);return source.left
  end,PCM_Source_Destroy=function()destroyed=destroyed+1 end,UpdateArrange=function()end,
  SetMediaItemSelected=function()selected=selected+1 end}
ext.peaks=J.encode{{project='project',paths={'cached','long','long'}}}
local p=P.new(r,'project');p:tick()
assert(finalized==0 and p.source and calls<=5,'Peak work did not yield within its budget')
for _=1,10 do p:tick()end
assert(finalized==1 and destroyed==2 and selected==0 and not p.source and #p.queue==0)
ext.peaks=J.encode{{project='project',paths={'cancel'}}};p:tick();p:close()
assert(not p.source and finalized==1 and destroyed==3,'Closing finalized an incomplete peak file')
-- A long render ages the heartbeat; its explicitly owned consumer still
-- receives queued peaks instead of falling back to a blocking UI action.
ext.heartbeat='0';now=10
r.CountTakes=function()return 1 end;r.GetTake=function()return 'take'end
r.GetMediaItemTake_Source=function()return 'source'end;r.GetMediaSourceParent=function()return nil end
r.GetMediaSourceFileName=function()return 'rendered.wav'end
require('am.insert').build_missing_peaks(r,'project',{'item'},true)
assert(J.decode(ext.peaks)[1].paths[1]=='rendered.wav' and selected==0)
