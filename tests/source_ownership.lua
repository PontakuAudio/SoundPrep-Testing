local Export=require('am.export');local Insert=require('am.insert')
local Model=require('am.model');local J=require('am.json')
-- REAPER's SetMediaItemTake_Source returns success; callers retain a source
-- that was never assigned. Every created PCM source must be owned or freed.
-- https://www.reaper.fm/sdk/reascript/reascripthelp.html#SetMediaItemTake_Source
local function fixture(failure)
  local created={};local old={old=true};local take={source=old};local item={};local writes=0
  local function source(kind)
    local value={kind=kind};created[#created+1]=value;return value
  end
  local r={
    PCM_Source_CreateFromFile=function()if failure~='decode'then return source('file')end end,
    PCM_Source_CreateFromType=function()if failure~='section'then return source('section')end end,
    PCM_Source_Destroy=function(value)
      assert(value and not value.destroyed and not value.assigned,'Invalid or double PCM source release')
      value.destroyed=true
    end,
    CF_PCM_Source_SetSectionInfo=function()return failure~='configure'end,
    SetMediaItemTake_Source=function(_,value)
      if failure=='assign'then return false end
      value.assigned=true;take.source=value;return true
    end,
    GetMediaSourceLength=function()return 2,false end,
    GetSetMediaTrackInfo_String=function()return true,''end,
    SetMediaTrackInfo_Value=function()end,
    GetTrackStateChunk=function()return true,'<TRACK\n>\n'end,
    SetTrackStateChunk=function()return true end,
    TrackFX_Show=function()end,TrackFX_GetCount=function()return 0 end,
    AddMediaItemToTrack=function()return item end,AddTakeToMediaItem=function()return take end,
    SetMediaItemTakeInfo_Value=function()writes=writes+1;return true end,
    SetMediaItemInfo_Value=function()writes=writes+1;return true end,
    ValidatePtr2=function()return true end,CountTakes=function()return 1 end,
    GetActiveTake=function()return take end,GetTake=function()return take end,
    GetMediaItemTake_Source=function()return old end,GetMediaSourceParent=function()end,
    GetMediaSourceFileName=function()return '/source.wav'end,
    GetSetMediaItemTakeInfo_String=function()return true,''end,
    GetItemStateChunk=function()return true,'<ITEM\n>\n'end,
    SetItemStateChunk=function()return true end,
    TakeFX_Show=function()end,TakeFX_GetCount=function()return 0 end,UpdateItemInProject=function()end,
    genGuid=function()return '{fixture}'end,
  }
  return r,created,old,take,item,function()return writes end
end
for _,mode in ipairs{'export','insert'}do
  for _,reverse in ipairs{false,true}do
    for _,failure in ipairs{'decode','section','configure','assign','success'}do
      if reverse or (failure~='section' and failure~='configure')then
        local r,created,old,take,item,writes=fixture(failure)
        local macro=Model.macro('test','Test');macro.source_transform.reverse=reverse
        local snapshot={path='/source.wav',macro=macro,chain='',source_gain_db=0,range=J.null,fade_ms=0}
        local ok,err
        if mode=='export'then ok,err=pcall(Export.populate,r,snapshot,{})
        else
          local plan={original='/source.wav',source_length=2,range=J.null,macro='Test',duration=2}
          ok,err=pcall(Insert.source,r,{},item,plan,snapshot)
        end
        local context=mode..' reverse='..tostring(reverse)..' failure='..failure
        assert(ok==(failure=='success'),context..': unexpected result '..tostring(err))
        for _,value in ipairs(created)do
          assert(value.destroyed or value.assigned,context..': unowned PCM source leaked')
          assert(not(value.destroyed and value.assigned),context..': take-owned PCM source destroyed')
        end
        if not ok then
          assert(writes()==0 and take.source==old and not old.destroyed,context..': failed transfer modified the existing take')
        else
          assert(take.source.assigned and writes()>0,context..': source was not transferred')
          assert(mode~='insert' or old.destroyed,context..': replaced source was not released')
        end
      end
    end
  end
end
