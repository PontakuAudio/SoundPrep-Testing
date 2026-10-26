local U=require('am.util');local J=require('am.json');local C=require('am.chunk');local Model=require('am.model')
local I=require('am.insert');local D=require('am.drop_render');local Render=require('am.render_item')
local Channels=require('am.render_channels');local TakeFX=require('am.take_fx')
local saved={U.read,U.write,Channels.ensure,Render.stamp,TakeFX.suspend}
local files,writes={},{}
local function snapshot(count,mode,chain,gain)
  local macro=Model.macro('test','Test');macro.export.tail_seconds=0;macro.output_gain_db=gain or 0
  return {path='/source.wav',identity={path='/source.wav',size=100,mtime=10},macro=macro,chain=chain or '',
    source_gain_db=0,range=J.null,fade_ms=0,
    channel_mix={revision=1,source_channels=count,output_channels=mode==0 and count or 2,mode=mode,
      preference='auto',fx_channels=math.ceil((mode==0 and count or 2)/2)*2}}
end
local function fixture(count,width)
  local track={width=width or 2};local take={source={path='/source.wav',channels=count},values={},strings={}}
  local item={takes={take},active=take,chunk='<ITEM\nLENGTH 10\n<SOURCE WAVE\nFILE "/source.wav"\n>\n>\n',values={D_LENGTH=10}}
  local serial=0;local rendered_channels=count;local destroyed=0
  local r={
    ValidatePtr2=function()return true end,CountTakes=function()return #item.takes end,
    GetActiveTake=function()return item.active end,GetTake=function(_,index)return item.takes[index+1]end,
    GetMediaItemTake_Source=function(t)return t.source end,GetMediaSourceParent=function()end,
    GetMediaSourceFileName=function(source)return source.path end,
    GetMediaSourceLength=function()return 10,false end,GetMediaSourceSampleRate=function()return 48000 end,
    GetMediaSourceNumChannels=function(source)return source.channels end,
    PCM_Source_CreateFromFile=function(path)return {path=path,channels=path=='/source.wav'and count or rendered_channels}end,
    PCM_Source_Destroy=function(source)assert(not source.destroyed);source.destroyed=true;destroyed=destroyed+1 end,
    SetMediaItemTake_Source=function(t,source)t.source=source;return true end,
    GetItemStateChunk=function()return true,item.chunk end,SetItemStateChunk=function(_,chunk)item.chunk=chunk;return true end,
    GetSetMediaItemTakeInfo_String=function(t,key,value,set)if set then t.strings[key]=value end;return true,t.strings[key]or ''end,
    GetMediaItemTakeInfo_Value=function(t,key)return t.values[key]or 0 end,
    SetMediaItemTakeInfo_Value=function(t,key,value)
      t.values[key]=value
      if key=='I_TAKEFX_NCH'then track.width=math.max(track.width,value)end
      return true
    end,
    GetMediaItemInfo_Value=function(_,key)return item.values[key]or 0 end,
    SetMediaItemInfo_Value=function(_,key,value)item.values[key]=value;return true end,
    GetMediaItem_Track=function()return track end,
    GetMediaTrackInfo_Value=function(_,key)assert(key=='I_NCHAN');return track.width end,
    SetMediaTrackInfo_Value=function(_,key,value)assert(key=='I_NCHAN');track.width=value end,
    TakeFX_GetCount=function()local _,n=item.chunk:gsub('<JS ','');return n end,TakeFX_Show=function()end,
    UpdateItemInProject=function()end,
    genGuid=function()serial=serial+1;return '{test'..serial..'}'end,
    AddTakeToMediaItem=function()local t={values={},strings={}};item.takes[#item.takes+1]=t;return t end,
    SetActiveTake=function(t)item.active=t end,
    PCM_Source_GetSectionInfo=function()return false,0,0,false end,
    JS_File_Stat=function()return 0,100,0,10 end,
    RecursiveCreateDirectory=function()end,file_exists=function()return false end,
  }
  return r,item,take,track,function(n)rendered_channels=n end,function()return destroyed end
end
local function occurrences(text,pattern)local _,count=text:gsub(pattern,'');return count end
local ok,err=xpcall(function()
  U.read=function(path)return files[path]end
  U.write=function(path,value)files[path]=value;writes[path]=true;return true end
  Channels.ensure=function()return Channels.effect end
  Render.stamp=function()end;TakeFX.suspend=function()end
  local chain='BYPASS 0 0 0\n<JS test "Original FX"\n1\n>\nFXID {original}\nWAK 0 0\n'
  for _,mode in ipairs{0,1,2}do
    local s=snapshot(9,mode,chain,3);local r,item,take,track=fixture(9,16)
    local plan=I.live_plan(s,10,true);plan.snapshot='/snapshot.json';files[plan.snapshot]=J.encode(s)
    assert(plan.channel_mix.source_channels==9 and plan.channel_mix.output_channels==(mode==0 and 9 or 2))
    assert(plan.channel_mix~=s.channel_mix,'A plan aliases mutable snapshot metadata')
    I.source(r,{},item,plan,s)
    assert(take.source.path=='/source.wav'and take.source.channels==9,'Source + FX lost the original multichannel file')
    assert(take.values.I_TAKEFX_NCH==10 and track.width==16,'Take width is wrong or an existing wider track was shrunk')
    assert(item.chunk:find('Original FX',1,true)<item.chunk:find('Macro Output Channels / Gain',1,true))
    assert(occurrences(item.chunk,'Macro Channel Mix')==(mode==0 and 0 or 1))
    if mode>0 then assert(item.chunk:find('Macro Channel Mix',1,true)<item.chunk:find('Original FX',1,true))end
    local key=I.processing_key(r,item);take.values.I_TAKEFX_NCH=12
    assert(I.processing_key(r,item)~=key,'A changed Take FX width did not invalidate processing')
    local edited,length,handles=D.recipe(r,item,plan)
    assert(length==10 and handles and edited.channel_mix.chain_applied and edited.channel_mix.fx_channels==12)
    assert(edited.channel_mix.source_channels==9 and edited.channel_mix.output_channels==s.channel_mix.output_channels)
    assert(edited.macro.output_gain_db==0)
    local next_r,next_item=fixture(9);local next_plan=I.live_plan(edited,10,true)
    I.source(next_r,{},next_item,next_plan,edited)
    assert(occurrences(next_item.chunk,'Macro Channel Mix')==(mode==0 and 0 or 1),'Edited recipe applied the channel matrix twice')
    assert(occurrences(next_item.chunk,'Macro Output Channels / Gain')==1,'Edited recipe applied output gain twice')
  end

  -- Native mono/pair modes survive editing a Source + FX take and baking it.
  for _,pair in ipairs{{4,4},{5,6}}do
    local s=snapshot(6,1,chain,0)
    s.channel_mix={revision=3,mode=3,source_channels=6,output_channels=2,fx_channels=2,selection={left=pair[1],right=pair[2]}}
    local r,item,take=fixture(6)
    local plan=I.live_plan(s,10,true);plan.snapshot='/native.json';files[plan.snapshot]=J.encode(s)
    I.source(r,{},item,plan,s)
    assert(take.values.I_CHANMODE==Channels.take_mode(s) and take.values.I_TAKEFX_NCH==2)
    assert(not item.chunk:find('Macro Input Channels',1,true))
    take.values.D_VOL=.5
    local edited=D.recipe(r,item,plan)
    assert(edited.channel_mix.chain_applied and Channels.take_mode(edited)==take.values.I_CHANMODE)
    local nr,ni,nt=fixture(6);I.source(nr,{},ni,I.live_plan(edited,10,true),edited)
    assert(nt.values.I_CHANMODE==take.values.I_CHANMODE and not ni.chunk:find('Macro Input Channels',1,true))
    take.values.I_CHANMODE=0;assert(not pcall(D.recipe,r,item,plan),'Unexpected channel mode was silently baked')
  end

  -- Raw OFF still limits the output width, so extra internal FX pins cannot
  -- leak. Removing that stage and resetting Take FX width remains editable.
  local s=snapshot(3,0);local r,item,take,track=fixture(3)
  local plan=I.live_plan(s,10,true);plan.snapshot='/raw.json';files[plan.snapshot]=J.encode(s)
  I.source(r,{},item,plan,s);assert(track.width==4 and take.values.I_TAKEFX_NCH==4)
  assert(occurrences(item.chunk,'Macro Output Channels / Gain')==1)
  item.chunk=C.replace(item.chunk,'','TAKEFX')
  take.values.D_VOL=.5;take.values.I_TAKEFX_NCH=0
  local edited=D.recipe(r,item,plan);assert(edited.channel_mix.fx_channels==2 and edited.channel_mix.chain_applied)
  assert(edited.source_gain_db<0 and Channels.width(edited)==4)
  take.source.channels=6
  local accepted,message=pcall(D.recipe,r,item,plan)
  assert(not accepted and tostring(message):find('Multichannel source changed',1,true))
  take.source.channels=3;r.JS_File_Stat=function()return 0,101,0,11 end
  accepted,message=pcall(D.recipe,r,item,plan)
  assert(not accepted and tostring(message):find('Multichannel source changed',1,true))

  -- A narrow rendered take must not shrink an unrelated wider destination.
  s=snapshot(9,0);r,item,take,track=fixture(9)
  plan=I.live_plan(s,10,true);plan.target='/rendered.wav';I.add_rendered(r,{},item,plan)
  assert(track.width==10 and #item.takes==2 and item.active~=take)

  -- Every new multichannel render is decoded and checked before its receipt
  -- can be accepted; mismatched audio cannot become a reusable cache entry.
  for _,mode in ipairs{0,1}do
    files={};writes={};s=snapshot(3,mode);r,item,take,track=fixture(3)
    local correct=Channels.output(s);local set_count,destroyed
    r,item,take,track,set_count,destroyed=fixture(3);set_count(correct==3 and 4 or 3)
    local render=function(_,_,directory,stem)return directory..'/'..stem..'.wav'end
    local accepted,message=pcall(I.prepare,r,s,10,true,'/out',nil,render)
    assert(not accepted and tostring(message):find('Rendered channel count',1,true))
    assert(destroyed()==1 and next(writes)==nil,'Rejected render leaked its decoder or published a receipt')
    set_count(correct);local result=I.prepare(r,s,10,true,'/out',nil,render)
    assert(result.channel_mix.output_channels==correct and next(writes)~=nil)
  end
end,debug.traceback)
U.read,U.write,Channels.ensure,Render.stamp,TakeFX.suspend=table.unpack(saved)
assert(ok,err)
