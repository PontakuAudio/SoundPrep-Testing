-- Freeze accepted native items while analysis runs; live selection changes
-- must neither cancel their work nor replace their normalization recipe.
local U=require('am.util');local J=require('am.json');local L=require('am.loudness')
local C=require('am.chunk');local I=require('am.insert');local Direct=require('am.render_item')
local M={};M.__index=M
local EXT='AuditionMacro.Drop.v1';local TAG='P_EXT:SoundPrepAnalysis'
local function items_by_id(r,project)
  local items={}
  for i=0,r.CountMediaItems(project)-1 do
    local item=r.GetMediaItem(project,i);items[select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))]=item
  end
  return items
end
function M.enqueue(r,project,prepared,ids)
  assert(#ids==#prepared.entries,'Drop did not create one item per source')
  local found=items_by_id(r,project);local items=J.array{}
  local token=prepared.session..':'..prepared.transaction
  for _,id in ipairs(ids)do
    local item=assert(found[id],'Dropped item was not found')
    assert(r.CountTakes(item)==1,'Only a new audio item is supported')
    local take=assert(r.GetActiveTake(item))
    items[#items+1]={id=id,mute=r.GetMediaItemInfo_Value(item,'B_MUTE'),
      name=select(2,r.GetSetMediaItemTakeInfo_String(take,'P_NAME','',false))}
  end
  for _,value in ipairs(items)do
    local item=found[value.id]
    r.SetMediaItemInfo_Value(item,'B_MUTE',1)
    r.GetSetMediaItemInfo_String(item,TAG,token,true)
    r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(item),'P_NAME',value.name..' [SoundPrep: analysing]',true)
    value.guard=I.render_guard(C.read_item(r,item))
    r.UpdateItemInProject(item)
  end
  local text=r.GetExtState(EXT,'analysis_queue');local queue=text~='' and J.decode(text)or J.array{}
  queue[#queue+1]={prepared=prepared,items=items,token=token}
  r.SetExtState(EXT,'analysis_queue',J.encode(queue),false)
  r.SetExtState(EXT,'message','Drop queued · Analysing; inserted items stay muted until ready',false)
end
function M.new(r,app)return setmetatable({r=r,app=app,jobs={}},M)end
function M:collect()
  local r,a=self.r,self.app;local text=r.GetExtState(EXT,'analysis_queue')
  if text==''then return end
  r.DeleteExtState(EXT,'analysis_queue',false)
  for _,batch in ipairs(J.decode(text))do
    if batch.prepared.session==a.session and batch.prepared.project==tostring(a.project)then self.jobs[#self.jobs+1]=batch end
  end
end
function M:validate(batch)
  local r,a=self.r,self.app;local found=items_by_id(r,a.project)
  for _,value in ipairs(batch.items)do
    local item=found[value.id]
    if not(item and r.CountTakes(item)==1 and I.render_guard(C.read_item(r,item))==value.guard)then
      return nil,'Dropped items were edited, removed or undone'
    end
  end
  for _,entry in ipairs(batch.prepared.entries)do
    local snapshot=entry.snapshot;local current=U.copy(snapshot);Direct.stamp(r,current)
    assert(U.equal(current.item_render,snapshot.item_render),'Project render settings changed')
    assert(L.same(snapshot.identity,L.identity(r,snapshot.path)),'Dropped source changed during analysis')
  end
  return found
end
function M:resolve(batch)
  local r,a=self.r,self.app;local p=batch.prepared
  if batch.worker then batch.worker:poll()end
  -- Re-read the cache: the companion may consume and delete its worker result
  -- before this tick. Do not retain a negative cache across those completions.
  local cache=setmetatable({data=p.data,settings=p.settings,analyzer_key=p.analyzer_key,memory={},keys={}},L)
  for _,entry in ipairs(p.entries)do
    if entry.analysis_pending then
      local s=entry.snapshot
      local measurement=cache:get(s.identity,s.analysis)
      if not measurement then
        local status,detail
        measurement,status,detail=L.completed_result(p.analysis_job,s.identity,p.analyzer_key,s.analysis)
        if status=='error'then error(detail,0)end
        local active=a.loudness and a.loudness.active
        if not measurement and status=='pending' and active and active.job_id==p.analysis_job.job_id and not active.cancelled then
          assert(r.time_precise()-(p.analysis_job.started or 0)<p.settings.analysis_timeout_seconds+20,'Analysis did not respond')
          return false
        end
      end
      if not measurement then
        if not batch.worker then
          batch.worker=L.new(r,a.root,p.data,p.settings,p.session..'-drop-'..p.transaction)
          batch.worker.analyzer_key=p.analyzer_key
        end
        assert(not batch.worker.error,batch.worker.error)
        measurement=batch.worker:request(s.identity,false,s.analysis)
        assert(not batch.worker.error,batch.worker.error)
      end
      if not measurement then return false end
      s.source_gain_db=L.gain(s.macro,measurement);entry.analysis_pending=nil
    end
  end
  p.analysis_pending=nil
  return true
end
function M:complete(batch,found)
  local r,a=self.r,self.app;local chunks,ids={},J.array{}
  local render_queue=r.GetExtState(EXT,'queue')
  for _,value in ipairs(batch.items)do
    chunks[value.id]=C.read_item(r,found[value.id]);ids[#ids+1]=value.id
  end
  r.Undo_BeginBlock2(a.project)
  local ok,err=xpcall(function()
    for _,value in ipairs(batch.items)do
      local item=found[value.id]
      r.GetSetMediaItemInfo_String(item,TAG,'',true)
      r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(item),'P_NAME',value.name,true)
    end
    local prepared=U.copy(batch.prepared);prepared.analysis_mutes={}
    for _,value in ipairs(batch.items)do prepared.analysis_mutes[value.id]=value.mute end
    -- A completion arriving later must not stop playback to render. Keep the
    -- processed source live and let the existing render queue finish at Stop.
    if r.GetPlayStateEx(a.project)~=0 then prepared.auto_render=false end
    require('am.drop_transaction').finish(r,a.project,prepared,ids)
  end,debug.traceback)
  if not ok then
    for id,chunk in pairs(chunks)do C.write_item(r,found[id],chunk)end
    if render_queue==''then r.DeleteExtState(EXT,'queue',false)else r.SetExtState(EXT,'queue',render_queue,false)end
  end
  r.Undo_EndBlock2(a.project,ok and 'Finish SoundPrep analysis' or 'SoundPrep analysis failed',-1)
  assert(ok,err)
  a.message=r.GetExtState(EXT,'message');r.DeleteExtState(EXT,'message',false)
end
function M:fail(batch,reason,quiet)
  local r,a=self.r,self.app
  if batch.worker then batch.worker:close()end
  -- Do not restore chunks over user edits or undo. Unprocessed items stay
  -- visibly muted; a failed analysis never turns into an unnormalized drop.
  if r.ValidatePtr(a.project,'ReaProject*')then
    local found=items_by_id(r,a.project)
    for _,value in ipairs(batch.items)do
      local item=found[value.id]
      if item and r.GetActiveTake(item) and select(2,r.GetSetMediaItemInfo_String(item,TAG,'',false))==batch.token and
        select(2,r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(item),'P_NAME','',false))==value.name..' [SoundPrep: analysing]'then
        r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(item),'P_NAME',value.name..' [SoundPrep: analysis incomplete]',true)
        r.UpdateItemInProject(item)
      end
    end
  end
  a.message='Drop analysis stopped: '..tostring(reason):match('^[^\n]+')..' · Unprocessed items remain muted; delete them and drag again.'
  if not quiet then r.ShowConsoleMsg('SoundPrep: '..a.message..'\n')end
end
function M:tick()
  self:collect()
  local r,a=self.r,self.app
  if #self.jobs==0 or r.EnumProjects(-1)~=a.project then return end
  local now=r.time_precise();if self.last_poll and now-self.last_poll<.05 then return end;self.last_poll=now
  local batch=self.jobs[1]
  local ok,done=xpcall(function()
    local found,reason=self:validate(batch)
    if not found then self:fail(batch,reason,true);return true end
    if not self:resolve(batch)then return false end
    self:complete(batch,found);return true
  end,debug.traceback)
  if not ok then self:fail(batch,done)end
  if not ok or done then
    if batch.worker then batch.worker:close()end
    table.remove(self.jobs,1)
  end
end
function M:close()
  self:collect()
  for _,batch in ipairs(self.jobs)do self:fail(batch,'SoundPrep closed before analysis completed')end
  self.jobs={}
end
return M
