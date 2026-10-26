-- Release inactive editable-drop plug-ins, preserving their saved FX states.
-- Only Source + FX takes owned by SoundPrep are managed.
local J=require('am.json');local U=require('am.util');local C=require('am.chunk')
local M={};M.__index=M
local KEY='P_EXT:AuditionMacroSourceFX'
local function guid(r,take)return select(2,r.GetSetMediaItemTakeInfo_String(take,'GUID','',false))end
local function read(r,take)
  local text=select(2,r.GetSetMediaItemTakeInfo_String(take,KEY,'',false))
  if text==''then return end
  local ok,state=pcall(J.decode,text)
  if ok and type(state)=='table' and state.schema==1 and type(state.fx)=='table'then return state end
  error('Invalid SoundPrep source FX state')
end
local function write(r,take,state)
  assert(r.GetSetMediaItemTakeInfo_String(take,KEY,J.encode(state),true),'Cannot save source FX resource state')
end
function M.offline_chain(chain)
  local lines,indices,depth,count={},J.array{},0,0
  for line in (C.chain_body(chain)..'\n'):gmatch('([^\n]*)\n')do
    local clean=line:match('^%s*(.-)%s*$')
    local value=line
    if depth==0 then
      local bypass,offline,rest=clean:match('^BYPASS (%d+) (%d+) (.+)$')
      if bypass then
        if tonumber(offline)==0 then indices[#indices+1]=count end
        value='BYPASS '..bypass..' 1 '..rest;count=count+1
      end
    end
    lines[#lines+1]=value
    if clean:sub(1,1)=='<'then depth=depth+1 elseif clean=='>'then depth=depth-1 end
  end
  return table.concat(lines,'\n'),indices,count
end
function M.offline_item(chunk,wanted,take_guid)
  local lines,depth,chain,pending,found,current={},0,nil,nil,{},nil
  for line in (chunk:gsub('\r\n','\n')..'\n'):gmatch('([^\n]*)\n')do
    local clean=line:match('^%s*(.-)%s*$')
    if depth==1 then current=clean:match('^GUID (.+)$')or current end
    if chain and depth==chain then
      if clean:match('^BYPASS %d+ %d+ ')then pending=#lines+1
      else
        local id=clean:match('^FXID ({[^}]+})$')
        if id and wanted[id]~=nil then
          assert(pending,'Source FX is missing its offline state')
          lines[pending]=lines[pending]:gsub('^(%s*BYPASS %d+ )%d+( .*)$',
            function(before,after)return before..(wanted[id]and'1'or'0')..after end)
          found[id]=true
        end
      end
    end
    lines[#lines+1]=line
    if clean=='<TAKEFX'then
      chain=(not take_guid or current==take_guid)and depth+1 or nil;pending=nil
    end
    if clean=='>'and depth==chain then chain=nil;pending=nil end
    if clean:sub(1,1)=='<'then depth=depth+1 elseif clean=='>'then depth=depth-1 end
  end
  for id in pairs(wanted)do assert(found[id],'Cannot map source FX '..id)end
  return table.concat(lines,'\n')
end
local function apply(r,take,wanted)
  if next(wanted)==nil then return end
  -- SetOffline creates a separate undo point for each FX. A chunk transaction
  -- avoids implicit undo entries; explicit insertion/restore blocks still
  -- capture it. SWS handles plug-in states larger than the native API limit.
  local item=r.GetMediaItemTake_Item(take)
  C.write_item(r,item,M.offline_item(C.read_item(r,item),wanted,guid(r,take)))
end
function M.remember(r,take,indices,count)
  assert(r.TakeFX_GetCount(take)==count,'Cannot map stored source FX resource states')
  local state={schema=1,take=guid(r,take),fx=J.array{},count=count}
  for _,index in ipairs(indices)do state.fx[#state.fx+1]={guid=assert(r.TakeFX_GetFXGUID(take,index)),index=index}end
  if #state.fx>0 then write(r,take,state)end
end
function M.suspend(r,take)
  local state=read(r,take)or{schema=1,take=guid(r,take),fx=J.array{}}
  local known={};for _,fx in ipairs(state.fx)do known[fx.guid]=true end
  local changed,wanted=0,{}
  for i=0,r.TakeFX_GetCount(take)-1 do
    if not r.TakeFX_GetOffline(take,i)then
      local id=assert(r.TakeFX_GetFXGUID(take,i))
      if not known[id]then state.fx[#state.fx+1]={guid=id,index=i};known[id]=true end
      -- A top-level container unloads its children together. Their individual
      -- bypass/offline flags remain serialized inside the container.
      wanted[id]=true;changed=changed+1
    end
  end
  state.count=r.TakeFX_GetCount(take)
  if changed>0 then apply(r,take,wanted);write(r,take,state)end
  return changed
end
function M.restore(r,take)
  local state=read(r,take);if not state or #state.fx==0 then return 0 end
  local known={};for _,fx in ipairs(state.fx)do known[fx.guid]=true end
  local count=r.TakeFX_GetCount(take);local copy=guid(r,take)~=state.take and count==state.count
  local changed,wanted=0,{}
  for i=0,count-1 do
    local id=r.TakeFX_GetFXGUID(take,i);local owned=known[id]
    -- REAPER may regenerate FX GUIDs when duplicating/splitting an item.
    -- On an unchanged copied chain retain the original per-index ownership.
    if copy and not owned then for _,fx in ipairs(state.fx)do if fx.index==i then owned=true;break end end end
    if owned and r.TakeFX_GetOffline(take,i)then wanted[id]=false;changed=changed+1 end
  end
  apply(r,take,wanted)
  state.take=guid(r,take);state.fx=J.array{};state.count=count;write(r,take,state)
  return changed
end
local function source(r,item)
  local take=r.GetTake(item,0);if not take or r.TakeFX_GetCount(take)==0 then return end
  -- The resource marker remains authoritative after the user replaces the
  -- source audio. Do not leave our offlined FX stranded after a restart.
  if read(r,take)then return take end
  -- A saved item can lose its Rendered take while the companion is closed.
  -- Recognize its resource marker so the only surviving source is restored.
  -- Unbaked single takes have no marker and remain untouched.
  if r.CountTakes(item)<2 then return end
  local text=select(2,r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro','',false))
  local ok,plan=pcall(J.decode,text)
  if not ok or type(plan)~='table' or type(plan.original)~='string' or type(plan.snapshot)~='string'then return end
  local media=r.GetMediaItemTake_Source(take)
  if not media then return end
  while r.GetMediaSourceParent(media)do media=r.GetMediaSourceParent(media)end
  if U.path_equal(r.GetMediaSourceFileName(media,''),plan.original)then return take end
end
local function audible(r,item,take)
  -- Inspecting the inactive source's FX must not reload its plug-ins. Restore
  -- only when this take can actually play, or through the explicit action.
  return r.GetActiveTake(item)==take or r.GetMediaItemInfo_Value(item,'B_ALLTAKESPLAY')~=0
end
function M.offline_project(r,project)
  local changed=0
  for i=0,r.CountMediaItems(project)-1 do
    local item=r.GetMediaItem(project,i);local take=source(r,item)
    if take and not audible(r,item,take)then changed=changed+M.suspend(r,take)end
  end
  return changed
end
function M.restore_selected(r)
  local project=r.EnumProjects(-1);local changed=0
  r.Undo_BeginBlock2(project)
  local ok,err=xpcall(function()
    for i=0,r.CountSelectedMediaItems(project)-1 do
      local item=r.GetSelectedMediaItem(project,i)
      local editable=source(r,item)
      for n=0,r.CountTakes(item)-1 do
        local take=r.GetTake(item,n);local state=read(r,take)
        if state or take==editable then changed=changed+M.restore(r,take);r.SetActiveTake(take);break end
      end
    end
    r.UpdateArrange()
  end,debug.traceback)
  r.Undo_EndBlock2(project,'Restore SoundPrep Source + FX',-1)
  assert(ok,err);return changed
end
function M.new(r,project)return setmetatable({r=r,project=project,items={},known={},cursor=1,scan=0},M)end
function M:sync(entry,force)
  local r=self.r
  if not r.ValidatePtr2(self.project,entry.item,'MediaItem*')or not r.ValidatePtr2(self.project,entry.take,'MediaItem_Take*')then return false end
  local live=audible(r,entry.item,entry.take);local count=r.TakeFX_GetCount(entry.take)
  if force or live~=entry.live or count~=entry.count then
    if live then M.restore(r,entry.take)else M.suspend(r,entry.take)end
    entry.live=live;entry.count=count
  end
  return true
end
function M:discover(item)
  local entry=self.known[item]
  if not entry or not self.r.ValidatePtr2(self.project,entry.take,'MediaItem_Take*')then
    local take=source(self.r,item);if not take then self.known[item]=nil;return end
    entry={item=item,take=take};self.known[item]=entry;self.items[#self.items+1]=entry
  end
  self:sync(entry,true)
end
function M:tick()
  local r=self.r;if r.EnumProjects(-1)~=self.project then return end
  local changes=r.GetProjectStateChangeCount(self.project)
  if changes~=self.changes then self.scan=0;self.changes=changes end
  -- Selected takes get priority, so a user's switch need not wait for a large
  -- project's background scan. Idle frames never read their FX chunks.
  for i=0,math.min(r.CountSelectedMediaItems(self.project),32)-1 do
    local item=r.GetSelectedMediaItem(self.project,i);local entry=self.known[item]
    if entry then self:sync(entry)else self:discover(item)end
  end
  local total=r.CountMediaItems(self.project)
  for _=1,32 do
    if self.scan>=total then break end
    self:discover(r.GetMediaItem(self.project,self.scan));self.scan=self.scan+1
  end
  for _=1,math.min(#self.items,32)do
    if self.cursor>#self.items then self.cursor=1 end
    if not self:sync(self.items[self.cursor])then
      local entry=self.items[self.cursor]
      if self.known[entry.item]==entry then self.known[entry.item]=nil end
      table.remove(self.items,self.cursor)
    else self.cursor=self.cursor+1 end
  end
  self.changes=r.GetProjectStateChangeCount(self.project) -- Ignore changes made by this policy itself.
end
return M
