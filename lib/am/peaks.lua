-- Build only missing drop peaks in short companion ticks. No progress window,
-- item selection changes or references to project-owned PCM sources.
local J=require('am.json');local M={};M.__index=M
local EXT='AuditionMacro.Drop.v1';local KEY='peaks'
function M.enqueue(r,project,items)
  local paths,seen={},{}
  for _,item in ipairs(items)do for i=0,r.CountTakes(item)-1 do
    local source=r.GetMediaItemTake_Source(r.GetTake(item,i))
    while r.GetMediaSourceParent(source)do source=r.GetMediaSourceParent(source)end
    local path=r.GetMediaSourceFileName(source,'')
    if path~='' and not seen[path]then paths[#paths+1]=path;seen[path]=true end
  end end
  local text=r.GetExtState(EXT,KEY);local queue=text~='' and J.decode(text)or J.array{}
  queue[#queue+1]={project=tostring(project),paths=paths}
  r.SetExtState(EXT,KEY,J.encode(queue),false)
end
function M.new(r,project)return setmetatable({r=r,project=project,queue={},seen={}},M)end
function M:tick()
  local r=self.r;local text=r.GetExtState(EXT,KEY)
  if text~=''then
    r.DeleteExtState(EXT,KEY,false)
    for _,batch in ipairs(J.decode(text))do if batch.project==tostring(self.project)then
      for _,path in ipairs(batch.paths)do if not self.seen[path]then
        self.queue[#self.queue+1]=path;self.seen[path]=true
      end end
    end end
  end
  local until_time=r.time_precise()+.004
  repeat
    if not self.source then
      local path=table.remove(self.queue,1);if not path then return end
      self.path=path;self.source=r.PCM_Source_CreateFromFile(path)
      if self.source and r.PCM_Source_BuildPeaks(self.source,0)==0 then
        r.PCM_Source_Destroy(self.source);self.source=nil;self.seen[path]=nil
      end
      if not self.source then self.seen[path]=nil end
    end
    if self.source and r.PCM_Source_BuildPeaks(self.source,1)==0 then
      r.PCM_Source_BuildPeaks(self.source,2);r.PCM_Source_Destroy(self.source)
      self.seen[self.path]=nil;self.source=nil;r.UpdateArrange()
    end
  until r.time_precise()>=until_time
end
function M:close()
  if self.source then self.r.PCM_Source_Destroy(self.source);self.source=nil end
  self.queue={};self.seen={};self.r.DeleteExtState(EXT,KEY,false)
end
return M
