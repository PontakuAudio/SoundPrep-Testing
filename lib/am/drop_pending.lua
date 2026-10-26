-- Recording/manual drops retain Source + FX. Recording batches finish after
-- transport stops; ordinary automatic playback drops render during insertion.
local U=require('am.util');local J=require('am.json');local I=require('am.insert')
local C=require('am.chunk');local L=require('am.loudness');local Direct=require('am.render_item')
local M={};M.__index=M;local EXT='AuditionMacro.Drop.v1'
function M.new(r,app)return setmetatable({r=r,app=app,jobs={}},M)end
function M.enqueue(r,batch)
  local text=r.GetExtState(EXT,'queue');local queue=text~='' and J.decode(text) or J.array{}
  queue[#queue+1]=batch;r.SetExtState(EXT,'queue',J.encode(queue),false)
end
function M:complete(batch)
  local r,a=self.r,self.app;local found,valid={},{}
  for i=0,r.CountMediaItems(a.project)-1 do
    local item=r.GetMediaItem(a.project,i);found[select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))]=item
  end
  for _,entry in ipairs(batch.entries)do
    local item=found[entry.item]
    local current=U.copy(entry.snapshot);Direct.stamp(r,current)
    if item and r.CountTakes(item)==1 and I.render_guard(C.read_item(r,item))==entry.guard and
      U.equal(current.item_render,entry.snapshot.item_render) and L.same(entry.snapshot.identity,L.identity(r,entry.snapshot.path))then
      valid[#valid+1]={item=item,entry=entry,chunk=C.read_item(r,item)}
    end
  end
  if #valid==0 then a.message='Pending render skipped: items or render context changed';return end
  r.SetExtState(EXT,'busy','1',false);r.Undo_BeginBlock2(a.project)
  local ok,err=xpcall(function()
    local items={}
    for _,value in ipairs(valid)do
      local e=value.entry;local plan=I.prepare(r,e.snapshot,e.length,e.handles,batch.directory,nil,Direct.render)
      I.add_rendered(r,a.project,value.item,plan);items[#items+1]=value.item
    end
    I.build_missing_peaks(r,a.project,items,true)
  end,debug.traceback)
  if not ok then for _,value in ipairs(valid)do C.write_item(r,value.item,value.chunk)end end
  r.Undo_EndBlock2(a.project,ok and 'Finish SoundPrep render' or 'SoundPrep render failed',-1)
  r.DeleteExtState(EXT,'busy',false)
  a.message=ok and ('Rendered %d item(s); %d edited/removed item(s) skipped'):format(#valid,#batch.entries-#valid) or
    ('Source + FX retained: '..tostring(err):match('^[^\n]+'))
end
function M:tick()
  local r,a=self.r,self.app;local text=r.GetExtState(EXT,'queue')
  if text~=''then
    r.DeleteExtState(EXT,'queue',false)
    for _,batch in ipairs(J.decode(text))do
      if batch.session==a.session and batch.project==tostring(a.project)then self.jobs[#self.jobs+1]=batch end
    end
  end
  if not a.definition.settings.auto_render_drops or #self.jobs==0 or r.EnumProjects(-1)~=a.project or r.GetPlayStateEx(a.project)~=0 then return end
  self:complete(table.remove(self.jobs,1))
end
return M
