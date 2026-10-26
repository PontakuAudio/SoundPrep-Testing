local App=require('am.app');local Preview=require('am.preview');local Model=require('am.model')
local U=require('am.util');local J=require('am.json');local Time=require('am.timeline')

-- Old banks migrate conservatively; serialized explicit choices survive.
assert(Model.defaults().settings.preview_downmix==false)
for _,enabled in ipairs{false,true}do
  local definition=Model.defaults();definition.settings.preview_downmix=enabled
  assert(Model.validate(J.decode(J.encode(definition))).settings.preview_downmix==enabled)
end
local legacy=Model.defaults();legacy.settings.preview_downmix=nil
assert(Model.validate(legacy).settings.preview_downmix==false)
for _,invalid in ipairs{'true',0,1,{}}do
  local definition=Model.defaults();definition.settings.preview_downmix=invalid
  assert(not pcall(Model.validate,definition),'Invalid downmix setting was accepted')
end

local function toggle_fixture(channels,playing,rate,reverse,range,position)
  local project={}
  local state={playing=playing,position=position or .75,live_rate=rate,starts=0,stops=0,clears=0,
    saves=0,syncs=0,widths={},order={},project=project}
  local app=setmetatable({definition=Model.defaults(),path='/six.wav',source_channels=channels,project=project,
    r={EnumProjects=function(index)assert(index==-1);return state.project end},
    range=range,transform_override={rate=rate,reverse=reverse,preserve_pitch=true,pitch_semitones=4}},App)
  local preview=setmetatable({native=true,handle=playing and {}or nil,source_length=10,range=range,
    macro=U.copy(app:effective()),get_value=function(_,key)
      return true,key=='D_PLAYRATE' and state.live_rate or key=='D_LENGTH' and 10 or state.position
    end,set_value=function(_,key,value)
      assert(key=='D_FADEOUTLEN' and value==0);state.order[#state.order+1]='hard';return true
    end,stop_handle=function()
      state.playing=false;state.stops=state.stops+1;state.order[#state.order+1]='stop'
    end},Preview)
  app.preview=preview
  app.sync_transform=function(self)
    state.syncs=state.syncs+1
    self.transform_override.rate=state.live_rate;self.effective_macro=nil
  end
  app.bank={clear_buffers=function()
    assert(not state.playing,'Old-channel audio was still playing when FX buffers were cleared')
    state.clears=state.clears+1;state.order[#state.order+1]='clear'
  end,set_channels=function(_,count)
    state.widths[#state.widths+1]=count;state.order[#state.order+1]='channels'
  end}
  app.save=function(self)
    state.saves=state.saves+1;state.saved=J.encode(self.definition);self.effective_macro=nil
  end
  app.play=function(self,at,immediate)
    assert(immediate,'A downmix toggle waited for beat/bar alignment')
    assert(state.clears>0 and state.widths[#state.widths]==(self.definition.settings.preview_downmix and 2 or channels))
    state.starts=state.starts+1;state.position=at;state.playing=true;state.order[#state.order+1]='play'
    state.live_rate=self:effective().source_transform.rate
    preview.handle={};preview.macro=U.copy(self:effective())
  end
  return app,state
end

-- Project changes must fail before either settings or audio are touched.
do
  local app,state=toggle_fixture(6,true,.5,true,{2,8})
  local handle,macro,range=app.preview.handle,app.preview.macro,app.range
  state.project={}
  local ok,err=pcall(app.set_downmix,app,true)
  assert(not ok and tostring(err):find('Return to the project',1,true))
  assert(not app.definition.settings.preview_downmix and state.syncs==0 and state.saves==0)
  assert(app.preview.handle==handle and app.preview.macro==macro and app.range==range and state.playing)
  assert(state.starts==0 and state.stops==0 and state.clears==0 and #state.widths==0 and #state.order==0)
end

-- A failed settings write restores the previous choice before stopping the
-- live handle or changing the bank, for either toggle direction.
for _,previous in ipairs{false,true}do
  local app,state=toggle_fixture(8,true,2,false,{2,8})
  app.definition.settings.preview_downmix=previous
  local handle,macro,range,position=app.preview.handle,app.preview.macro,app.range,state.position
  app.save=function(self)
    assert(self.definition.settings.preview_downmix~=previous)
    state.saves=state.saves+1;error('fixture save failure')
  end
  local ok,err=pcall(app.set_downmix,app,not previous)
  assert(not ok and tostring(err):find('fixture save failure',1,true))
  assert(app.definition.settings.preview_downmix==previous and state.saves==1 and state.syncs==1)
  assert(app.preview.handle==handle and app.preview.macro==macro and app.range==range and state.playing)
  assert(state.position==position and state.starts==0 and state.stops==0 and state.clears==0)
  assert(#state.widths==0 and #state.order==0,'A failed save changed the live channel routing')
end

-- Original-source coordinates survive both directions, including position 0,
-- range-relative playback, reverse, and a live rate not yet reflected in Lua.
for _,rate in ipairs{.5,1,2}do
  for _,reverse in ipairs{false,true}do
    for _,bounds in ipairs{false,{2,8}}do
      for _,position in ipairs{0,.75}do
        local range=bounds or nil
        local app,state=toggle_fixture(6,true,rate,reverse,range,position)
        state.live_rate=rate*1.5
        local source=Time.source(position,10,range,{rate=state.live_rate,reverse=reverse})
        for _,enabled in ipairs{true,false}do
          state.order={};app:set_downmix(enabled)
          local expected=Time.position(source,10,range,app:effective().source_transform)
          assert(math.abs(state.position-expected)<1e-10,'Toggle moved the original-source bookmark')
          assert(table.concat(state.order,',')=='hard,stop,clear,channels,play')
          assert(Model.validate(J.decode(state.saved)).settings.preview_downmix==enabled)
          assert(app.range==range and app:effective().source_transform.reverse==reverse)
        end
        assert(state.starts==2 and state.stops==2 and state.clears==2 and state.saves==2)
        app:set_downmix(false);assert(state.saves==2 and state.starts==2,'Unchanged choice restarted audio')
        assert(not pcall(app.set_downmix,app,'true'))
      end
    end
  end
end

-- Toggle settings while stopped or paused without starting playback or losing
-- the stored source coordinate used by a later Resume.
for _,paused in ipairs{false,true}do
  local app,state=toggle_fixture(3,false,.5,true,{2,8})
  if paused then app.paused_source=5;app.paused_position=6;app.paused_length=10 end
  app.last_seek={path=app.path,source=4,length=10};local seek=app.last_seek
  for _,enabled in ipairs{true,false}do app:set_downmix(enabled)end
  assert(state.starts==0 and state.stops==0 and state.clears==2 and state.saves==2)
  assert(app.last_seek==seek and app.paused_source==(paused and 5 or nil))
  assert(app.paused_position==(paused and 6 or nil) and app.paused_length==(paused and 10 or nil))
end
for _,channels in ipairs{0,1,2}do
  local app,state=toggle_fixture(channels,true,1,false)
  app:set_downmix(true)
  assert(state.saves==1 and state.starts==0 and state.stops==0 and state.clears==0 and #state.widths==0,
    'Mono/stereo or empty selection restarted for a downmix setting change')
end

-- The same source uses separate analysis bases when its audition mapping
-- changes; both preview gain and explicit Analyse pass that frozen descriptor.
local requests,reads=0,0
local analysis=setmetatable({definition=Model.defaults(),identity={path='/multi.wav'},source_channels=6,
  loudness={get=function(_,identity,spec)
    reads=reads+1;assert(identity.path=='/multi.wav' and spec.source_channels==6)
    return {status='ready',max_momentary_lufs=-40,true_peak_dbtp=-10}
  end,request=function(_,identity,force,spec)
    requests=requests+1;assert(force and identity.path=='/multi.wav' and spec.source_channels==6)
    assert(spec.basis==(requests<=2 and 'loudest_channel' or 'downmix_discrete'))
  end}},App)
analysis.definition.raw.normalization.enabled=true
analysis.definition.raw.source_peak_guard.enabled=true
for _,enabled in ipairs{false,true}do
  analysis.definition.settings.preview_downmix=enabled
  local gain,status=analysis:gain();assert(gain==9 and status=='source peak capped')
  assert(analysis:measurement());analysis:request_analysis(true);analysis:analyse(true)
end
assert(requests==4 and reads==4)

-- Selection polling exposes source channels with autoplay disabled, and
-- returns routing to mono/stereo when selecting a narrower source or nothing.
local project={};local selected='/three.wav';local now=1;local widths={}
local sources,destroys,starts,clears=0,0,0,0
local source_channels={['/three.wav']=3,['/mono.wav']=1,['/eight.wav']=8}
local app=setmetatable({project=project,last_poll=0,definition=Model.defaults(),
  r={EnumProjects=function()return project end,ValidatePtr=function()return true end,
    GetExtState=function()return ''end,time_precise=function()return now end,
    JS_File_Stat=function()return 0,100,0,1 end,
    PCM_Source_CreateFromFile=function(path)sources=sources+1;return {channels=source_channels[path]}end,
    GetMediaSourceNumChannels=function(source)return source.channels end,
    PCM_Source_Destroy=function()destroys=destroys+1 end},
  bank={tracks={},valid=function()return true end,clear_buffers=function()clears=clears+1 end,
    set_channels=function(_,count)widths[#widths+1]=count end},
  preview={stop=function(_,hard)assert(hard)end,playing=function()return false end},
  loudness={poll=function()end,cancel_active=function()end},
  explorer={selection=function()return selected end,transport_event=function()end},
  publish=function()end,sync_range=function()return false end,sync_wave=function()end,sync_transform=function()end,
  commands=function()end,play=function()starts=starts+1 end},App)
app.definition.settings.autoplay=false
for _,case in ipairs{{'/three.wav',3,3},{'/mono.wav',1,1},{'/eight.wav',8,8},{false,0,2}}do
  selected=case[1]or nil;now=now+1;app:tick()
  assert(app.source_channels==case[2] and widths[#widths]==case[3] and starts==0)
end
assert(sources==3 and destroys==3 and clears==3,'Selection probing leaked PCM sources or old-channel buffers')
app.definition.settings.preview_downmix=true;selected='/eight.wav';now=now+1;app:tick()
assert(app.source_channels==8 and widths[#widths]==2 and starts==0)
assert(sources==4 and destroys==4)
