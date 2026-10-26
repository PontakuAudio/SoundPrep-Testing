-- Shared finalization for immediate drops and frozen drops awaiting analysis.
local U=require('am.util');local J=require('am.json');local C=require('am.chunk');local Insert=require('am.insert')
local M={};local EXT='AuditionMacro.Drop.v1'
local function track(r,guid)
  for i=0,r.CountTracks(0)-1 do local t=r.GetTrack(0,i);if r.GetTrackGUID(t)==guid then return t end end
end
function M.finish(r,project,prepared,item_ids)
  local input,volume
  local ok,err=xpcall(function()
    if prepared.entries then
      local recording=(r.GetPlayStateEx(project)&4)~=0
      if recording or prepared.auto_render==false then
        for _,entry in ipairs(prepared.entries)do
          if not Insert.channel_only(entry.snapshot)and not Insert.unprocessed_raw(entry.snapshot)and not Insert.item_volume(entry.snapshot)then
            local _,_,key,stem=Insert.recipe(entry.snapshot,entry.length,prepared.handles)
            if not Insert.cached(r,key,prepared.directory,stem)then prepared.pending=true;break end
          end
        end
      end
      assert(not prepared.pending or prepared.defer_items,'Restart SoundPrep once to enable drops during playback')
      input=assert(track(r,prepared.input),'Preview input was removed');volume=r.GetMediaTrackInfo_Value(input,'D_VOL')
      r.SetMediaTrackInfo_Value(input,'D_VOL',0);r.SetExtState(EXT,'busy','1',false)
      prepared.plans={}
      for _,entry in ipairs(prepared.entries)do
        if Insert.channel_only(entry.snapshot)then
          local plan=Insert.live_plan(entry.snapshot,entry.length,prepared.handles)
          plan.pending=nil;plan.channel_only=true
          prepared.plans[#prepared.plans+1]=plan
        elseif Insert.unprocessed_raw(entry.snapshot)then
          -- Keep REAPER's native source/range placement. Raw needs neither a
          -- rendered duplicate nor a pending recipe, even if a cache exists.
          prepared.plans[#prepared.plans+1]={original=entry.snapshot.path,raw=true}
        elseif Insert.item_volume(entry.snapshot)then
          prepared.plans[#prepared.plans+1]={original=entry.snapshot.path,item_volume=true}
        else
          prepared.plans[#prepared.plans+1]=prepared.pending and Insert.stage(r,entry.snapshot,entry.length,prepared.handles,prepared.directory) or
            Insert.prepare(r,entry.snapshot,entry.length,prepared.handles,prepared.directory,nil,require('am.render_item').render_drop)
        end
      end
    end
    assert(#item_ids==#prepared.plans,'Drop did not create one item per source')
    local wanted={};for _,id in ipairs(item_ids)do wanted[id]=true end
    local items={}
    for i=0,r.CountMediaItems(project)-1 do
      local x=r.GetMediaItem(project,i);local _,guid=r.GetSetMediaItemInfo_String(x,'GUID','',false)
      if wanted[guid]then items[#items+1]=x end
    end
    assert(#items==#item_ids,'Dropped items were not found')
    local available=U.copy(prepared.plans)
    local entries=U.copy(prepared.entries or {});local pending=J.array{};local processed={};local raw_count,volume_count,channel_count=0,0,0
    for _,item in ipairs(items)do
      local take=assert(r.GetActiveTake(item),'No audio take in dropped item')
      local source=r.GetMediaItemTake_Source(take)
      while r.GetMediaSourceParent(source)do source=r.GetMediaSourceParent(source)end
      local path=r.GetMediaSourceFileName(source,'')
      local _,original=r.GetSetMediaItemTakeInfo_String(take,'P_EXT:ORIGINAL_FILENAME','',false)
      local match
      for i,plan in ipairs(available)do if U.path_equal(plan.original,path) or U.path_equal(plan.original,original) then match=i;break end end
      assert(match,'Drop source does not match the Macro snapshot')
      local plan=table.remove(available,match)
      local entry=prepared.entries and table.remove(entries,match)
      local function release_mute()
        local id=select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))
        if prepared.analysis_mutes and prepared.analysis_mutes[id]~=nil then
          r.SetMediaItemInfo_Value(item,'B_MUTE',prepared.analysis_mutes[id]);r.UpdateItemInProject(item)
        end
      end
      if plan.channel_only then
        Insert.source(r,project,item,plan,entry.snapshot);channel_count=channel_count+1
      elseif plan.raw then raw_count=raw_count+1
      elseif plan.item_volume then
        Insert.apply_item_volume(r,project,item,entry.snapshot);volume_count=volume_count+1
      elseif prepared.pending then
        entry.handles=plan.handles
        Insert.source(r,project,item,plan,entry.snapshot)
        release_mute()
        entry.item=select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))
        entry.guard=Insert.render_guard(C.read_item(r,item));pending[#pending+1]=entry
      else Insert.replace(r,project,item,plan)end
      release_mute()
      if not plan.raw and not plan.item_volume then processed[#processed+1]=item end
    end
    Insert.build_missing_peaks(r,project,processed,prepared.defer_items)
    r.SetExtState(EXT,'message',('Inserted %d item(s): Source + FX / Rendered · %s'):format(#processed,
      prepared.handles and 'full processed handles retained' or 'range rendered; full Source + FX retained'),false)
    if #pending>0 then
      require('am.drop_pending').enqueue(r,{session=prepared.session,project=tostring(project),directory=prepared.directory,entries=pending})
      r.SetExtState(EXT,'message',prepared.auto_render==false and
        'Source + FX ready · Edit now; render selected drops when needed' or
        'Source + FX ready · Render completes after recording stops',false)
    end
    if channel_count>0 then
      local message=('Inserted %d item(s) · Selected microphones applied; original source retained'):format(channel_count)
      if #processed>channel_count then message=r.GetExtState(EXT,'message')..' · '..message end
      r.SetExtState(EXT,'message',message,false)
    end
    if volume_count>0 then
      local message=('Inserted %d item(s) · Item Volume applied; original source, no render'):format(volume_count)
      if #processed>0 then message=r.GetExtState(EXT,'message')..' · '..message end
      r.SetExtState(EXT,'message',message,false)
    end
    if raw_count>0 then
      local message=('Inserted %d Raw item(s) · Original source; no render'):format(raw_count)
      if #processed>0 or volume_count>0 then message=r.GetExtState(EXT,'message')..' · '..message end
      r.SetExtState(EXT,'message',message,false)
    end
    for _,entry in ipairs(prepared.entries or {})do
      local processing=entry.snapshot.source_processing
      if processing and processing.fx_bypassed and not Insert.unprocessed_raw(entry.snapshot)then
        r.SetExtState(EXT,'message',r.GetExtState(EXT,'message')..' · Original multichannel audio: Macro FX bypassed',false)
        break
      end
    end
  end,debug.traceback)
  if input and r.ValidatePtr(input,'MediaTrack*')then r.SetMediaTrackInfo_Value(input,'D_VOL',volume)end
  r.DeleteExtState(EXT,'busy',false)
  if not ok then error(err,0)end
end
return M
