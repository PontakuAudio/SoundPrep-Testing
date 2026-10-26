local U=require('am.util');local J=require('am.json');local E=require('am.media_explorer')
local M={}
function M.reveal_orphans(r,session)
  local project=r.EnumProjects(-1);local count=0
  for i=0,r.CountTracks(project)-1 do
    local t=r.GetTrack(project,i);local _,owner=r.GetSetMediaTrackInfo_String(t,'P_EXT:AuditionMacroOwner','',false)
    if owner~='' and (not session or owner==session)then
      r.SetMediaTrackInfo_Value(t,'D_VOL',0)
      r.SetMediaTrackInfo_Value(t,'B_SHOWINTCP',1);r.SetMediaTrackInfo_Value(t,'B_SHOWINMIXER',1)
      local _,name=r.GetTrackName(t)
      r.GetSetMediaTrackInfo_String(t,'P_NAME','AM recovered • '..name,true)
      r.GetSetMediaTrackInfo_String(t,'P_EXT:AuditionMacroOwner','',true)
      count=count+1
    end
  end
  return count
end
function M.restore(r,data)
  local text=U.read(data..'/recovery.json');if not text then return false end
  local value=J.decode(text)
  assert(value.schema_version==1 and type(value.session)=='string' and type(value.explorer)=='table','Invalid recovery record')
  local saved=value.explorer
  assert(type(saved.volume)=='string' and type(saved.toggles)=='table','Invalid recovery settings')
  for _,id in ipairs{'1011','42026','42134','42182','42348','1068'}do
    local v=saved.toggles[id];assert(v==-1 or v==0 or v==1,'Invalid recovery toggle')
  end
  if saved.fader_position~=nil then assert(type(saved.fader_position)=='number' and saved.fader_position>=0 and saved.fader_position<=1000,'Invalid recovery fader')end
  local explorer=E.new(r);explorer.saved=saved;explorer:restore()
  -- Preserve possible unsaved plugin edits for manual recovery.
  M.reveal_orphans(r,value.session)
  os.remove(data..'/recovery.json');return true
end
return M
