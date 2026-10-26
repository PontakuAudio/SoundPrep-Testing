local U=require('am.util');local J=require('am.json');local Model=require('am.model')
local Selection=require('am.channel_selection');local Policy=require('am.analysis_policy')
local Loudness=require('am.loudness');local Channels=require('am.render_channels');local App=require('am.app')
local definition=Model.validate(Model.defaults());local settings=definition.settings
assert(next(settings.channel_selections)==nil)
settings.channel_selections['6']={left=5,right=2}
assert(Model.validate(J.decode(J.encode(definition))).settings.channel_selections['6'].left==5)
assert(Selection.get(settings,2)==nil and Selection.get(settings,6).right==2)
for _,invalid in ipairs{{left=0,right=1},{left=7,right=1},{left=1.5,right=2},{left=1},{left=1,right=2,extra=true}}do
  assert(not Selection.valid(6,invalid))
end
for _,key in ipairs{'06','129','0','6.5','bad'}do assert(not pcall(Selection.validate,{[key]={left=1,right=1}}))end
-- Selection takes precedence even over an incompatible global AmbiX decoder.
settings.preview_downmix=true;settings.preview_downmix_mode='ambix'
local spec=assert(Policy.resolve('/six.wav',6,settings))
assert(spec.revision==3 and spec.basis=='selected_channels' and Policy.valid(spec))
assert(spec.selection.left==5 and Policy.label(spec)=='L 5 / R 2')
settings.channel_selections['6'].left=3
assert(spec.selection.left==5,'Measurement descriptor aliases the live controls')
local other=assert(Policy.resolve('/six.wav',6,settings))
local identity={path='/six.wav',size=100,mtime=1}
assert(not Policy.same(spec,other) and Loudness.key(identity,'native',spec)~=Loudness.key(identity,'native',other))
for _,channels in ipairs{1,2,6,128}do
  settings.channel_selections[tostring(channels)]={left=channels,right=1}
  for _,metric in ipairs{'lufs_m_max','zwicker_max','zwicker_p95'}do
    local n=Model.macro('test','Test').normalization;n.metric=metric;n.enabled=true
    local a=assert(Policy.resolve('/audio.wav',channels,settings,n))
    assert(Policy.valid(a) and a.source_channels==channels)
    assert(Loudness.profile(a)==(metric~='lufs_m_max' and Loudness.ZWICKER_PROFILE or channels>2 and Loudness.MULTICHANNEL_PROFILE or Loudness.PROFILE))
    local changed=U.copy(a);changed.selection.right=channels+1;assert(not Policy.valid(changed))
  end
end
-- A single source mapping governs live routing, stopped bookmarks and saves.
local project={};local position=0;local playing=true;local starts,stops,clears,saves=0,0,0,0
local width,bypass
local app=setmetatable({definition=Model.defaults(),source_channels=6,path='/six.wav',project=project,
  r={EnumProjects=function()return project end},sync_transform=function()end,
  preview={source_length=10,source_position=function()return playing and position or nil end,
    stop=function(_,hard)assert(hard);playing=false;stops=stops+1 end},
  bank={set_channels=function(_,n,b)width=n;bypass=b end,clear_buffers=function()assert(not playing);clears=clears+1 end},
  save=function()saves=saves+1 end,
  play=function(_,at,immediate)assert(immediate);position=at;playing=true;starts=starts+1;return true end},App)
assert(app:set_channel_selection(5,2));assert(position==0 and width==2 and not bypass and starts==1)
assert(app:set_channel_selection(5,2));assert(starts==1 and saves==1,'Unchanged route restarted playback')
position=4;assert(app:set_channel_selection(3));assert(position==4 and starts==2)
playing=false;app.paused_source=4;app.paused_position=4
assert(app:set_channel_selection(6,1));assert(starts==2 and app.paused_source==4 and app.paused_position==4)
local previous=U.copy(app.definition.settings);local previous_clears=clears
app.save=function()error('save failed')end
assert(not pcall(app.set_channel_selection,app,2,4))
assert(U.equal(app.definition.settings,previous) and clears==previous_clears)
assert(not pcall(app.set_downmix,app,true));assert(U.equal(app.definition.settings,previous))
app.save=function()saves=saves+1 end
assert(app:set_downmix(true));assert(not Selection.get(app.definition.settings,6) and width==2 and not bypass)
assert(app:set_channel_selection(4));assert(app:set_downmix(false));assert(width==6 and bypass)
-- Per-layout choice does not leak to fewer-channel sources, nor disappear on return.
assert(app:set_channel_selection(5,6));app.source_channels=2;app:configure_channels();assert(width==2 and not bypass)
app.source_channels=6;app:configure_channels();assert(width==2 and not bypass)
local before=U.copy(app.definition.settings);project={}
assert(not pcall(app.set_channel_selection,app,1,2));assert(U.equal(before,app.definition.settings))
assert(stops==2 and starts==2)
-- Snapshots retain exact input ordering and use a distinct immutable JSFX.
local snapshot={channel_mix={revision=2,mode=3,source_channels=6,output_channels=2,fx_channels=12,selection={left=5,right=2}},
  chain='BYPASS 0 0 0\n<JS test "Macro FX"\n1\n>\nWAK 0 0\n',macro=Model.macro('test','Test')}
assert(Channels.output(snapshot)==2 and Channels.width(snapshot)==12)
local ensure=Channels.ensure
Channels.ensure=function(_,selected)return selected and Channels.selection_effect or Channels.effect end
local ok,err=xpcall(function()
  local chain=Channels.chain({genGuid=function()return '{test}'end},snapshot,true)
  assert(chain:find('3 6 0 5 2',1,true) and chain:find(Channels.selection_effect,1,true)<chain:find('Macro FX',1,true))
  snapshot.channel_mix.chain_applied=true;snapshot.chain=chain
  assert(Channels.chain({},snapshot,true)==chain,'Pending render remapped an already edited chain')
  snapshot.channel_mix.selection.left=7;assert(not pcall(Channels.validate,snapshot))
end,debug.traceback)
Channels.ensure=ensure;assert(ok,err)

local Export=require('am.export')
local destroyed=0
local api={JS_File_Stat=function()return 0,100,0,1 end,
  PCM_Source_CreateFromFile=function()return {}end,GetMediaSourceNumChannels=function()return 6 end,
  PCM_Source_Destroy=function()destroyed=destroyed+1 end}
settings.channel_selections['6']={left=6,right=2}
local exported=Export.snapshot(api,'/six.wav',Model.macro('test','Test'),'',0,identity,nil,settings)
assert(exported.channel_mix.mode==3 and exported.channel_mix.selection.left==6 and destroyed==1)
settings.channel_selections['6'].left=1
assert(exported.channel_mix.selection.left==6)
api.PCM_Source_CreateFromFile=function()return nil end
assert(not pcall(Export.snapshot,api,'/six.wav',Model.macro('test','Test'),'',0,identity,nil,settings))
-- A late measurement must never retarget a handle playing a different pair.
local owner={}
local live=setmetatable({project=owner,r={EnumProjects=function()return owner end},definition=Model.defaults(),
  identity=identity,playback_identity=U.copy(identity),path=identity.path,source_channels=6,
  preview={path=identity.path,source_channels=6,channel_selection={left=1,right=2},
    playing=function()error('Stale selected handle reached gain application')end}},App)
live.definition.settings.channel_selections={['6']={left=5,right=6}}
assert(not live:update_normalization(0))

-- New snapshots use native take modes where REAPER can represent the pair;
-- old recipes retain their immutable JSFX mapping when reopened/baked.
for _,entry in ipairs{{1,1,3},{64,64,66},{65,65,131},{128,128,194},{1,2,67},{64,65,130},{65,66,195},{127,128,257}}do
  assert(Selection.take_mode({left=entry[1],right=entry[2]})==entry[3])
end
assert(not Selection.take_mode({left=5,right=2}))
local native={channel_mix={revision=3,mode=3,source_channels=6,output_channels=2,fx_channels=2,selection={left=5,right=6}},
  chain='',macro=Model.macro('test','Test'),source_gain_db=0}
assert(Channels.take_mode(native)==71 and Channels.width(native)==2 and Channels.chain({},native,true)=='')
assert(require('am.insert').channel_only(native))
native.channel_mix.selection.right=5;assert(Channels.take_mode(native)==7)
native.channel_mix.revision=2;assert(Channels.take_mode(native)==0 and Channels.width(native)==6)
native.channel_mix.revision=3;native.channel_mix.selection.right=2
assert(Channels.take_mode(native)==0 and Channels.width(native)==6)
local synced={};app.r.AM_WaveSetChannels=function(...)synced={...}end
app.identity={size=100,mtime=2};app:sync_channel_waveform()
assert(synced[1]=='/six.wav' and synced[2]==5 and synced[3]==6 and synced[4]=='100:2')
app.source_channels=2;app:sync_channel_waveform();assert(synced[1]=='' and synced[2]==0)

-- Number buttons store an independent subset; legacy L/R recipes still work.
local subset={channels={1,3,5}}
assert(Selection.valid(6,subset)and Selection.output(subset)==3 and Selection.csv(subset)=='1,3,5')
for _,bad in ipairs{{},{1,1},{0},{7},{5,3,1},{1,2,3,4,5,6,7}}do assert(not Selection.valid(6,{channels=bad}))end
assert(Selection.valid(128,{channels={32,64,96,128}}))
assert(Selection.take_mode({channels={65}})==131 and Selection.take_mode({channels={5,6}})==71)
assert(not Selection.take_mode(subset))
local subset_settings=Model.defaults().settings;subset_settings.channel_selections={['6']=subset}
local subset_spec=Policy.resolve('/six.wav',6,subset_settings,{enabled=false,metric='lufs_m_max'})
assert(subset_spec.revision==4 and Policy.valid(subset_spec)and not Policy.same(subset_spec,spec))
local frozen=U.copy(native);frozen.channel_mix={revision=4,mode=3,source_channels=6,output_channels=3,fx_channels=4,selection=subset}
assert(Channels.output(frozen)==3 and Channels.width(frozen)==6 and Channels.take_mode(frozen)==0)
assert(require('am.insert').channel_only(frozen))
project=app.project;app.source_channels=6;app:set_channel_selection({1,3,5});assert(U.equal(Selection.get(app.definition.settings,6),subset))
assert(width==3 and bypass)
app.r.AM_WaveSetChannelSubset=function(...)synced={...}end;app:sync_channel_waveform()
assert(synced[1]=='/six.wav' and synced[2]=='1,3,5' and synced[3]=='100:2')
