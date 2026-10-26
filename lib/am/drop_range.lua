local U=require('am.util');local J=require('am.json')
local M={}
function M.read(r,ctx,path,length)
  if ctx.origin=='list' then return end
  local p=ctx.preview
  local ready,file,mode,a,b
  if p and p~=J.null then
    ready,file,mode,a,b=true,p.path,p.mode,p.start,p['end']
  else ready,file,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()end
  assert(ready and U.path_equal(file,path),'Load this file in the native waveform before dragging')
  assert(U.finite(a) and U.finite(b) and a>=0 and b<=1 and b>=a,'Invalid Media Explorer selection')
  if (mode&384)~=0 and b>a then return {a*length,b*length}end
end
return M
