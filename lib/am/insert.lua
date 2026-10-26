-- Rendered media is permanent project media, never an evictable preview cache.
local U=require('am.util');local J=require('am.json');local L=require('am.loudness');local C=require('am.chunk')
local Channels=require('am.render_channels')
local M={}
local function has_fx(chain)
  -- FX occupy child blocks. REAPER can retain window/editor metadata after
  -- the last FX is removed, which must not turn a gain-only drop into a render.
  return ('\n'..C.chain_body(chain)):find('\n%s*<')~=nil
end
function M.unprocessed_raw(snapshot)
  local m=snapshot.macro;local t=m.source_transform
  local mix=Channels.validate(snapshot)
  return m.id=='raw' and not m.normalization.enabled and not m.source_peak_guard.enabled and
    not t.reverse and t.pitch_semitones==0 and t.rate==1 and not t.preserve_pitch and
    m.output_gain_db==0 and snapshot.source_gain_db==0 and not has_fx(snapshot.chain) and
    (not mix or mix.mode==0)
end
-- Channel-only drops retain the original media and an editable take setting.
function M.channel_only(snapshot)
  local mix=Channels.validate(snapshot);local t=snapshot.macro.source_transform
  local has_fx=('\n'..C.chain_body(snapshot.chain)):find('\n%s*<')~=nil
  return mix and mix.mode==3 and not t.reverse and t.pitch_semitones==0 and t.rate==1 and not has_fx
end
function M.item_volume(snapshot)
  local m=snapshot.macro;local t=m.source_transform;local mix=Channels.validate(snapshot)
  -- A scalar gain needs no new media. Preserve the pre-FX gain path whenever
  -- actual FX, channel processing or source transforms require rendering.
  if t.reverse or t.pitch_semitones~=0 or t.rate~=1 or has_fx(snapshot.chain) or
    mix and mix.mode~=0 then return end
  return U.gain(snapshot.source_gain_db+m.output_gain_db)
end
function M.apply_item_volume(r,project,item,snapshot)
  assert(r.ValidatePtr2(project,item,'MediaItem*') and r.CountTakes(item)==1,'Only a new audio item is supported')
  local gain=assert(M.item_volume(snapshot),'Drop requires source processing')
  assert(L.same(snapshot.identity,L.identity(r,snapshot.path)),'Source changed during drop')
  -- Native insertion owns the source, range, position and fades. Replace its
  -- gain explicitly so Media Explorer volume cannot be applied a second time.
  r.SetMediaItemTakeInfo_Value(r.GetActiveTake(item),'D_VOL',1)
  r.SetMediaItemInfo_Value(item,'D_VOL',gain)
  if snapshot.channel_mix then Channels.widen(r,r.GetMediaItem_Track(item),snapshot)end
  r.UpdateItemInProject(item)
end
function M.layout(length,range,transform,handles)
  assert(U.finite(length) and length>0,'Invalid source duration')
  local a,b=0,length
  if range and range~=J.null then a,b=range[1],range[2]end
  assert(U.finite(a) and U.finite(b) and a>=0 and b>a and b<=length+1e-8,'Invalid waveform selection')
  local rate=transform.rate;assert(U.finite(rate) and rate>0,'Invalid rate')
  return {offset=handles and (transform.reverse and (length-b) or a)/rate or 0,
    duration=(b-a)/rate,render_range=handles and J.null or {a,b},
    source_duration=(handles and length or (b-a))/rate}
end
function M.recipe(snapshot,length,handles)
  Channels.validate(snapshot)
  local plan=M.layout(length,snapshot.range,snapshot.macro.source_transform,handles)
  local render=U.copy(snapshot);render.range=plan.render_range
  -- Arrange inserts sound like the audition. Optional export-only mastering is
  -- deliberately not applied. Full renders preserve FX tails as extra handles.
  render.macro.export.normalize_final=false;render.macro.export.true_peak_limit=false
  if not handles then render.macro.export.tail_seconds=0 end
  local identity=U.copy(render);identity.created_at=nil
  identity.render_revision=5 -- preserve JSON null when copying full-source snapshots
  identity.chain=require('am.chunk').portable(identity.chain)
  local key=J.encode(identity)
  local basename=U.basename(snapshot.path):gsub('%.[^.]+$',''):gsub('[^%w_%-\128-\255]','_'):sub(1,72)
  while not utf8.len(basename)do basename=basename:sub(1,-2)end
  if basename==''then basename='audio'end
  local stem=basename..'_'..snapshot.macro.id..'_'..U.hash(key)
  return plan,render,key,stem
end
function M.cached(r,key,directory,stem)
  if not directory then return end
  local target=directory..'/'..stem..'.wav'
  local old=U.read(directory..'/'..stem..'.insert.json');local cached=old and select(2,pcall(J.decode,old))
  if type(cached)=='table' and cached.key==key and L.same(cached.identity,L.identity(r,target))then return target end
end
function M.prepare(r,snapshot,length,handles,directory,prepared_directory,render_file)
  local plan,render,key,stem=M.recipe(snapshot,length,handles)
  r.RecursiveCreateDirectory(directory,0)
  local target=directory..'/'..stem..'.wav';local receipt=directory..'/'..stem..'.insert.json'
  if not M.cached(r,key,directory,stem) then
    local prepared
    local directories=type(prepared_directory)=='table' and prepared_directory or {prepared_directory}
    for _,path in ipairs(directories)do
      prepared=M.cached(r,key,path,stem);if prepared then break end
    end
    if r.file_exists(target)then stem=stem..'_'..U.hash(r.genGuid());target=directory..'/'..stem..'.wav';receipt=directory..'/'..stem..'.insert.json'end
    if prepared then
      -- Temporary preparations are never referenced directly by a project.
      assert(U.copy_file(prepared,target))
      assert(U.copy_file(prepared:gsub('%.wav$','.macro.json'),directory..'/'..stem..'.macro.json'))
      local project=assert(U.read(prepared:gsub('%.wav$','.rpp')))
      -- Keep the reproducible FX snapshot, but never point a reopened Render
      -- dialog back into an evictable staging directory.
      project=project:gsub('([\r\n]%s*RENDER_FILE%s+)[^\r\n]*','%1""')
      assert(U.write(directory..'/'..stem..'.rpp',project))
    else target=(render_file or require('am.render_item').render)(r,render,directory,stem)end
    assert(L.same(snapshot.identity,L.identity(r,snapshot.path)),'Source changed during rendering')
    local check=assert(r.PCM_Source_CreateFromFile(target),'Rendered file cannot be decoded')
    local duration=r.GetMediaSourceLength(check);local rate=r.GetMediaSourceSampleRate(check)
    local channels=snapshot.channel_mix and r.GetMediaSourceNumChannels(check)
    r.PCM_Source_Destroy(check)
    assert(not snapshot.channel_mix or channels==Channels.output(snapshot),'Rendered channel count does not match the drop snapshot')
    assert(duration+1/(rate>0 and rate or 48000)>=plan.source_duration+render.macro.export.tail_seconds,'Render was cancelled or incomplete')
    assert(U.write(receipt,J.encode{key=key,identity=assert(L.identity(r,target))}))
  end
  plan.target=target;plan.original=snapshot.path;plan.macro=snapshot.macro.name
  plan.range=snapshot.range;plan.handles=handles;plan.source_length=length
  plan.channel_mix=U.copy(snapshot.channel_mix)
  plan.snapshot=target:gsub('%.wav$','.macro.json')
  return plan
end
function M.live_plan(snapshot,length,handles)
  Channels.validate(snapshot)
  local plan=M.layout(length,snapshot.range,snapshot.macro.source_transform,handles)
  plan.original=snapshot.path;plan.macro=snapshot.macro.name;plan.range=snapshot.range
  plan.handles=handles;plan.source_length=length;plan.pending=true
  plan.channel_mix=U.copy(snapshot.channel_mix)
  return plan
end
function M.stage(r,snapshot,length,handles,directory)
  local plan=M.live_plan(snapshot,length,handles)
  local _,_,_,stem=M.recipe(snapshot,length,handles)
  r.RecursiveCreateDirectory(directory,0)
  plan.snapshot=directory..'/'..stem..'.pending.macro.json'
  assert(U.write(plan.snapshot,J.encode(snapshot)))
  return plan
end
function M.processing_key(r,item)
  local take=assert(r.GetTake(item,0));local values={}
  for _,key in ipairs{'D_PLAYRATE','D_PITCH','B_PPITCH','D_VOL','D_PAN','I_CHANMODE','I_PITCHMODE','I_TAKEFX_NCH'}do
    values[key]=r.GetMediaItemTakeInfo_Value(take,key)
  end
  local chunk=C.read_item(r,item)
  return U.hash(C.portable(C.block(chunk,'TAKEFX') or '')..(C.block(chunk,'SOURCE') or '')..J.encode(values))
end
function M.source(r,project,item,plan,snapshot)
  assert(r.ValidatePtr2(project,item,'MediaItem*'),'Dropped item no longer exists')
  assert(r.CountTakes(item)==1,'Only a new audio item is supported')
  local take=assert(r.GetActiveTake(item));local old=r.GetMediaItemTake_Source(take)
  local source=old
  while r.GetMediaSourceParent(source)do source=r.GetMediaSourceParent(source)end
  local path=r.GetMediaSourceFileName(source,'')
  local _,original=r.GetSetMediaItemTakeInfo_String(take,'P_EXT:ORIGINAL_FILENAME','',false)
  assert(U.path_equal(path,plan.original) or U.path_equal(original,plan.original),'Drop source does not match the Macro snapshot')
  snapshot=snapshot or J.decode(assert(U.read(plan.snapshot),'Macro snapshot is missing'))
  local mix=Channels.validate(snapshot)
  local transform=snapshot.macro.source_transform
  -- Reconstruct from the frozen render recipe, not the current live bank or
  -- REAPER's native insert transform (which may have wrapped/cropped the file).
  local editable=assert(r.PCM_Source_CreateFromFile(plan.original),'Original media is missing')
  -- Cropping is a rendered-media policy only. The editable take always keeps
  -- the entire original, so its edges can be extended after switching takes.
  if transform.reverse then
    local section=r.PCM_Source_CreateFromType('SECTION')
    if not section then r.PCM_Source_Destroy(editable);error('Cannot create original source section')end
    local configured=r.CF_PCM_Source_SetSectionInfo(section,editable,0,plan.source_length,true)
    r.PCM_Source_Destroy(editable)
    if not configured then r.PCM_Source_Destroy(section);error('Cannot configure original take')end
    editable=section
  end
  if not r.SetMediaItemTake_Source(take,editable)then r.PCM_Source_Destroy(editable);error('Cannot assign original media')end
  if old then r.PCM_Source_Destroy(old)end
  -- The source mapping precedes Macro FX. Take volume remains the source gain;
  -- the helper appends the Macro's output gain after the copied FX chain.
  local chain=C.fresh(Channels.chain(r,snapshot,true),r.genGuid)
  local offline_indices,offline_count
  if plan.target then chain,offline_indices,offline_count=require('am.take_fx').offline_chain(chain)end
  C.write_item(r,item,C.replace(C.read_item(r,item),chain,'TAKEFX'))
  take=assert(r.GetTake(item,0))
  if mix then
    if r.TakeFX_GetCount(take)>0 then r.SetMediaItemTakeInfo_Value(take,'I_TAKEFX_NCH',Channels.width(snapshot))end
    Channels.widen(r,r.GetMediaItem_Track(item),snapshot)
    plan.channel_mix=U.copy(mix)
  end
  if offline_indices then require('am.take_fx').remember(r,take,offline_indices,offline_count)end
  -- Apply numeric properties after the FX chunk round-trip: VOLPAN text is
  -- serialized with fewer decimal places than the API's gain/offset doubles.
  local full=M.layout(plan.source_length,plan.range,transform,true)
  for k,v in pairs{D_STARTOFFS=full.offset*transform.rate,D_PLAYRATE=transform.rate,D_PITCH=transform.pitch_semitones,
    D_VOL=U.gain(snapshot.source_gain_db),D_PAN=0,I_CHANMODE=Channels.take_mode(snapshot),B_PPITCH=transform.preserve_pitch and 1 or 0,I_PITCHMODE=-1}do
    r.SetMediaItemTakeInfo_Value(take,k,v)
  end
  r.TakeFX_Show(take,0,0)
  for i=0,r.TakeFX_GetCount(take)-1 do r.TakeFX_Show(take,i,2)end
  local name=U.basename(plan.original)..' · '..plan.macro
  local suffix=plan.channel_only and require('am.channel_selection').label(mix.selection)or 'Source + FX'
  r.GetSetMediaItemTakeInfo_String(take,'P_NAME',name..' ['..suffix..']',true)
  r.SetMediaItemInfo_Value(item,'D_LENGTH',plan.duration)
  r.SetMediaItemInfo_Value(item,'D_VOL',1);r.SetMediaItemInfo_Value(item,'B_LOOPSRC',0)
  r.SetMediaItemInfo_Value(item,'B_ALLTAKESPLAY',0)
  r.UpdateItemInProject(item)
  if plan.pending then plan.processing_key=M.processing_key(r,item)end
  r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro',J.encode(plan),true)
end
function M.add_rendered(r,project,item,plan)
  assert(r.ValidatePtr2(project,item,'MediaItem*') and r.CountTakes(item)==1,'Source take changed before rendering')
  local take=assert(r.GetTake(item,0));local name=U.basename(plan.original)..' · '..plan.macro
  local rendered=assert(r.PCM_Source_CreateFromFile(plan.target),'Processed media is missing')
  local baked=r.AddTakeToMediaItem(item)
  if not baked then r.PCM_Source_Destroy(rendered);error('Cannot add rendered take')end
  if not r.SetMediaItemTake_Source(baked,rendered)then r.PCM_Source_Destroy(rendered);error('Cannot assign processed media')end
  if plan.channel_mix then Channels.widen(r,r.GetMediaItem_Track(item),plan)end
  for k,v in pairs{D_STARTOFFS=plan.offset,D_PLAYRATE=1,D_PITCH=0,D_VOL=1,D_PAN=0,I_CHANMODE=0,B_PPITCH=1}do
    r.SetMediaItemTakeInfo_Value(baked,k,v)
  end
  r.GetSetMediaItemTakeInfo_String(take,'P_EXT:AuditionMacro',J.encode(plan),true)
  r.GetSetMediaItemTakeInfo_String(baked,'P_NAME',name..' [Rendered]',true)
  r.GetSetMediaItemTakeInfo_String(baked,'P_EXT:AuditionMacro',J.encode(plan),true)
  r.SetActiveTake(baked)
  require('am.take_fx').suspend(r,take)
  r.UpdateItemInProject(item)
end
function M.replace(r,project,item,plan)
  M.source(r,project,item,plan)
  M.add_rendered(r,project,item,plan)
end
function M.render_guard(chunk)
  local lines,depth={},0
  for line in (chunk:gsub('\r\n','\n')..'\n'):gmatch('([^\n]*)\n')do
    local clean=line:match('^%s*(.-)%s*$')
    if not(depth==1 and (clean:match('^POSITION%s') or clean:match('^SEL%s')))then lines[#lines+1]=line end
    if clean:sub(1,1)=='<'then depth=depth+1 elseif clean=='>'then depth=depth-1 end
  end
  return table.concat(lines,'\n')
end
function M.build_missing_peaks(r,project,items,defer_peaks)
  if #items==0 then return end
  local heartbeat=r.GetExtState and tonumber(r.GetExtState('AuditionMacro.v1','heartbeat'))
  if r.PCM_Source_BuildPeaks and (defer_peaks or heartbeat and r.time_precise()-heartbeat<3)then
    require('am.peaks').enqueue(r,project,items);r.UpdateArrange();return
  end
  -- Assigning a PCM_source and repainting an item do not schedule its peaks.
  -- Use REAPER's own peak builder once per drop, after every take is assigned.
  -- Scope the action to this batch and preserve the native drop selection.
  local selected={};local wanted={}
  for _,item in ipairs(items)do
    assert(r.ValidatePtr2(project,item,'MediaItem*'),'Dropped item no longer exists')
    wanted[item]=true
  end
  local same=r.CountSelectedMediaItems(project)==#items
  for i=0,r.CountSelectedMediaItems(project)-1 do
    local item=r.GetSelectedMediaItem(project,i);selected[#selected+1]=item
    if not wanted[item]then same=false end
  end
  if not same then
    for _,item in ipairs(selected)do r.SetMediaItemSelected(item,false)end
    for _,item in ipairs(items)do r.SetMediaItemSelected(item,true)end
  end
  local ok,err=xpcall(function()
    if not(r.AM_QuietItemAction and r.AM_QuietItemAction(40245,project))then
      r.Main_OnCommandEx(40245,0,project) -- Peaks: Build any missing peaks for selected items
    end
  end,debug.traceback)
  if not same then
    for _,item in ipairs(items)do if r.ValidatePtr2(project,item,'MediaItem*')then r.SetMediaItemSelected(item,false)end end
    for _,item in ipairs(selected)do if r.ValidatePtr2(project,item,'MediaItem*')then r.SetMediaItemSelected(item,true)end end
  end
  r.UpdateArrange()
  if not ok then error(err)end
end
return M
