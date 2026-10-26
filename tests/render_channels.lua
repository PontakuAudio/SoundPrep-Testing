local Channels=require('am.render_channels');local U=require('am.util');local Model=require('am.model')
local Insert=require('am.insert');local J=require('am.json')
local bundled=assert(U.read('resources/audition_macro_channels_v1.jsfx'))
local read,write=U.read,U.write;local files={};local writes,mkdir=0,0
local r={GetResourcePath=function()return '/fake-resource'end,genGuid=function()return '{new}'end,
  RecursiveCreateDirectory=function()mkdir=mkdir+1 end,
  GetMediaTrackInfo_Value=function(track,key)return track[key]end,
  SetMediaTrackInfo_Value=function(track,key,value)track[key]=value end}
local function snapshot(n,mode)
  return {path='/source.wav',chain='SHOW -1\nBYPASS 0 0 0\n<JS original "Macro FX"\n0\n>\n',
    macro=Model.macro('channels','Channels'),range=J.null,
    channel_mix={revision=1,source_channels=n,output_channels=mode==0 and n or 2,mode=mode,preference='auto',fx_channels=12}}
end
local function count(chain)local _,n=chain:gsub('AuditionMacro/channels_v1','');return n end
local ok,err=xpcall(function()
  U.read=function(path)
    if path:match('/resources/audition_macro_channels_v1%.jsfx$')then return bundled end
    return files[path]
  end
  U.write=function(path,value)files[path]=value;writes=writes+1;return true end
  local s=snapshot(9,0)
  assert(Channels.output(s)==9 and Channels.width(s)==12)
  assert(Channels.chain(r,s,false)==s.chain and writes==0,'Raw OFF unnecessarily installed a preprocessor')
  local raw_chain=Channels.chain(r,s,true)
  assert(count(raw_chain)==1 and raw_chain:find('0 9 0',1,true),'Raw OFF did not limit output width')
  s.channel_mix.mode=2;s.channel_mix.output_channels=2
  local chain=Channels.chain(r,s,true)
  assert(count(chain)==2 and chain:find('2 9 0',1,true)<chain:find('<JS original',1,true))
  assert(writes==1 and mkdir==1 and files['/fake-resource/Effects/AuditionMacro/channels_v1']==bundled)
  s.macro.output_gain_db=6;chain=Channels.chain(r,s,true)
  assert(count(chain)==2 and chain:find('0 2 6',1,true)>chain:find('<JS original',1,true))
  assert(writes==1,'Matching immutable processor was rewritten')
  s.chain=chain;s.channel_mix.chain_applied=true;s.macro.output_gain_db=0
  assert(Channels.chain(r,s,true)==chain,'Edited Take FX was mixed or gained twice')
  local track={I_NCHAN=16};Channels.widen(r,track,s);assert(track.I_NCHAN==16)
  s=snapshot(9,0);track.I_NCHAN=2;Channels.widen(r,track,s);assert(track.I_NCHAN==10)
  s.channel_mix.fx_channels=2;assert(Channels.width(s)==10)
  local _,_,key=Insert.recipe(s,1,true)
  s.channel_mix.mode=1;s.channel_mix.output_channels=2
  assert(select(3,Insert.recipe(s,1,true))~=key,'Channel mode reused a different rendered recipe')
  for _,change in ipairs{
    function(x)x.source_channels=129 end,function(x)x.source_channels=2 end,
    function(x)x.output_channels=9 end,function(x)x.mode=3 end,
    function(x)x.fx_channels=3 end,function(x)x.fx_channels=130 end,
    function(x)x.mode=2;x.source_channels=6 end,function(x)x.chain_applied='true'end,
  }do local invalid=U.copy(s);change(invalid.channel_mix);assert(not pcall(Channels.validate,invalid))end
  files['/fake-resource/Effects/AuditionMacro/channels_v1']='user edit'
  assert(not pcall(Channels.chain,r,s,true) and files['/fake-resource/Effects/AuditionMacro/channels_v1']=='user edit')
  s.channel_mix=nil;s.macro.output_gain_db=6
  assert(Channels.output(s)==2 and Channels.width(s)==2)
  assert(Channels.chain(r,s,true):find('<JS utility/volume_pan',1,true),'Legacy gain recipe changed')
end,debug.traceback)
U.read,U.write=read,write;assert(ok,err)
