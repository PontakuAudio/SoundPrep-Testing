local Bank=require('am.bank')
local user={valid=true,I_FOLDERDEPTH=0,I_NCHAN=12,selected=true}
local master={valid=true,I_NCHAN=2}
local project={tracks={user}}
local writes,chunks,send_reads=0,0,0
local r={EnumProjects=function()return project end,ValidatePtr=function()return true end,
  ValidatePtr2=function(_,t)return t.valid end,
  CountTracks=function()return #project.tracks end,
  GetTrack=function(_,i)return project.tracks[i+1]end,
  CountSelectedTracks=function()return 1 end,GetSelectedTrack=function()return user end,
  SetTrackSelected=function(t,value)t.selected=value end,
  GetMediaTrackInfo_Value=function(t,key)return t[key]or 0 end,
  SetMediaTrackInfo_Value=function(t,key,value)
    assert(t~=user and t~=master,'Channel configuration changed a user track or Master')
    writes=writes+1;t[key]=value;return true
  end,
  GetSetMediaTrackInfo_String=function(t,key,value,set)
    if set then t[key]=value end;return true,t[key]or ''
  end,
  InsertTrackAtIndex=function(i)table.insert(project.tracks,i+1,{valid=true,sends={}})end,
  GetTrackStateChunk=function()return true,'<TRACK\n>\n'end,
  SetTrackStateChunk=function()chunks=chunks+1;return true end,
  TrackFX_GetCount=function(t)return t.fx and 1 or 0 end,
  TrackFX_GetIOSize=function()return 0,2,2 end,
  TrackFX_GetPinMappings=function(t,_,direction,pin)
    local mapped=t.fx and t.fx.pins and t.fx.pins[direction..':'..pin]
    if mapped then return mapped[1],mapped[2]end
    return pin<2 and 1<<pin or 0,0
  end,
  TrackFX_GetNamedConfigParm=function()return true,'2'end,
  CreateTrackSend=function(src,dst)
    src.sends[#src.sends+1]={P_DESTTRACK=dst,I_SRCCHAN=0,I_DSTCHAN=0}
    return #src.sends-1
  end,
  SetTrackSendInfo_Value=function(t,category,i,key,value)
    assert(category==0);writes=writes+1;t.sends[i+1][key]=value;return true
  end,
  GetTrackNumSends=function(t,category)assert(category==0);return #t.sends end,
  GetTrackSendInfo_Value=function(t,category,i,key)
    assert(category==0);send_reads=send_reads+1;return t.sends[i+1][key]
  end,
  DeleteTrack=function(t)
    t.valid=false
    for i=#project.tracks,1,-1 do
      local track=project.tracks[i]
      if track==t then table.remove(project.tracks,i)
      elseif track.sends then
        for j=#track.sends,1,-1 do if track.sends[j].P_DESTTRACK==t then table.remove(track.sends,j)end end
      end
    end
  end}
local bank=Bank.new(r,project,'/fixture',{macros={},settings={monitor_gain_db=-6,keep_fx_running=true}},'channels')
assert(bank.channels==2 and bank.input.I_NCHAN==2 and bank.raw.I_NCHAN==2)
assert(bank.input.sends[1].I_SRCCHAN==0 and bank.input.sends[1].I_DSTCHAN==0)
assert(send_reads==0,'Default stereo initialization requires a channel route scan')
bank.load=function(self,t)t.fx={guid='fx-'..tostring(t),parameter=.73};self.loads=self.loads+1 end
local function add(id)
  bank:add_macro{id=id,name=id,fx_chain=id..'.RfxChain',output_gain_db=-3}
  return bank.macros[id]
end
local first,second=add('first'),add('second')
bank:activate('first',-3)
local retained_fx,retained_gain,retained_loads=first.fx,first.D_VOL,bank.loads
local original_chunks=chunks
local external=r.CreateTrackSend(bank.input,user)
r.SetTrackSendInfo_Value(bank.input,0,external,'I_SRCCHAN',1024+5)
r.SetTrackSendInfo_Value(bank.input,0,external,'I_DSTCHAN',1024+7)
local external_route=bank.input.sends[external+1]
local function check(count)
  local width=math.max(2,math.ceil(count/2)*2)
  assert(bank:set_channels(count)==width and bank.channels==width)
  for _,track in ipairs(bank.tracks)do
    assert(track.I_NCHAN==width and track.C_MAINSEND_OFFS==0 and track.C_MAINSEND_NCH==0,
      'Owned track or main send truncated/reordered preview channels')
  end
  for _,send in ipairs(bank.input.sends)do
    if send~=external_route then
      assert(send.I_SRCCHAN==(width==2 and 0 or (width//2)<<10) and send.I_DSTCHAN==0,
        'A branch send truncated/reordered preview channels')
    end
  end
  assert(external_route.I_SRCCHAN==1024+5 and external_route.I_DSTCHAN==1024+7,
    'A user-added send was changed')
  assert(user.I_NCHAN==12 and master.I_NCHAN==2 and user.selected)
  assert(first.fx==retained_fx and first.fx.parameter==.73 and first.D_VOL==retained_gain)
  assert(bank.loads==retained_loads and chunks==original_chunks,'Channel changes reloaded FX state')
  assert(first.B_MAINSEND==1 and second.B_MAINSEND==0 and bank.input.B_MAINSEND==0)
end
for _,count in ipairs{1,2,3,4,6,8,64,128,7,2,1}do check(count)end
writes=0;send_reads=0;bank:set_channels(2)
assert(writes==0 and send_reads==0,'Repeated channel selection rewrote stable routing')
for _,count in ipairs{0,-1,129,2.5,math.huge,0/0,'6',false}do
  assert(not pcall(bank.set_channels,bank,count),'Invalid preview channel count was accepted')
end
assert(not pcall(bank.set_channels,bank,nil))
assert(writes==0,'Invalid channel count partially changed the bank')

-- Removing an earlier branch shifts subsequent send indices; added Macros
-- must immediately inherit the active source width without reloading others.
bank:set_channels(6);bank:remove('first')
local third=add('third')
assert(third.I_NCHAN==6 and third.C_MAINSEND_NCH==0)
local third_send=bank.input.sends[#bank.input.sends]
assert(third_send.P_DESTTRACK==third and third_send.I_SRCCHAN==3<<10 and third_send.I_DSTCHAN==0)
bank:set_channels(3)
for _,send in ipairs(bank.input.sends)do
  if send~=external_route then assert(send.I_SRCCHAN==2<<10 and send.I_DSTCHAN==0)end
end
assert(second.I_NCHAN==4 and third.I_NCHAN==4 and first.I_NCHAN==6)
assert(external_route.I_SRCCHAN==1024+5 and external_route.I_DSTCHAN==1024+7)
assert(first.fx==retained_fx,'Removing a route or changing channels reset another FX instance')
writes=0;second.valid=false
assert(not pcall(bank.set_channels,bank,8) and writes==0,
  'An externally deleted branch caused a partial channel reconfiguration')
second.valid=true
assert(not bank.channel_state[first],'A deleted Macro retained channel ownership state')

-- A temporary 128ch source must not leave ordinary stereo FX processing 128
-- channels forever. A manually widened chain retains its own minimum instead.
bank:set_channels(128);bank:set_channels(2)
assert(second.I_NCHAN==2 and third.I_NCHAN==2 and bank.input.I_NCHAN==2 and bank.raw.I_NCHAN==2)
second.I_NCHAN=8;bank:set_channels(6)
assert(second.I_NCHAN==8 and third.I_NCHAN==6)
bank:set_channels(128);bank:set_channels(2)
assert(second.I_NCHAN==8 and third.I_NCHAN==2,'Source width overwrote the manually widened Macro')
second.I_NCHAN=4;bank:set_channels(6);bank:set_channels(2)
assert(second.I_NCHAN==4,'An explicit smaller Macro width was not respected')

-- FX loading can expand track channels. Capture that requirement before
-- temporarily widening a new Macro for the currently selected source.
bank:set_channels(128)
local prior_load=bank.load
bank.load=function(self,t,path)
  assert(t.I_NCHAN==2,'A new FX chain inherited source width before loading')
  prior_load(self,t,path);t.I_NCHAN=8
end
local loaded=add('loaded');bank.load=prior_load
assert(loaded.I_NCHAN==128)
bank:set_channels(2)
assert(loaded.I_NCHAN==8,'Connecting the input narrowed the loaded FX chain')
bank:set_channels(128)
bank.load=function(self,t,path)
  prior_load(self,t,path);t.fx.pins={['0:'..0x1000000]={0,-2147483648}}
end
local dormant=add('dormant');bank.load=prior_load
bank:set_channels(2)
assert(dormant.I_NCHAN==2,'Unchanged dormant default pins kept the source expanded to 128 channels')

-- Pin edits can need channels hidden inside an already-wide preview track.
-- Include both 32-bit words and the second 64-bit bank of REAPER mappings.
local fx_identity=third.fx;local chunk_count=chunks
for _,channel in ipairs{4,32,64,65,96,128}do
  bank:set_channels(128)
  local offset=channel>64 and 0x1000000 or 0
  local bit=(channel-1)%64;local masks={0,0}
  masks[bit//32+1]=bit%32==31 and -2147483648 or 1<<(bit%32)
  local direction=channel%2 -- Cover both input and output pin mappings.
  third.fx.pins={[direction..':'..offset]=masks}
  bank:set_channels(2)
  assert(third.I_NCHAN==2*math.ceil(channel/2),'Internal FX pin routing was truncated at channel '..channel)
  assert(bank.input.I_NCHAN==2 and bank.raw.I_NCHAN==2)
  for _,send in ipairs(bank.input.sends)do
    if send~=external_route then assert(send.I_SRCCHAN==0,'Internal FX width changed source send width')end
  end
  bank:set_channels(128);third.fx.pins=nil;bank:set_channels(2)
  assert(third.I_NCHAN==2,'Removing the internal routing left a source-only expansion behind')
end
assert(third.fx==fx_identity and chunks==chunk_count,'Protecting internal channels reloaded plugin state')

-- If a plugin cannot report pin mappings, retaining its current width is the
-- conservative choice; the input/raw tracks still return to stereo.
local pins=r.TrackFX_GetPinMappings;r.TrackFX_GetPinMappings=nil
bank:set_channels(128);bank:set_channels(2)
assert(third.I_NCHAN==128 and bank.input.I_NCHAN==2 and bank.raw.I_NCHAN==2)
r.TrackFX_GetPinMappings=pins
