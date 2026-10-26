local Mix=require('am.channel_mix');local Model=require('am.model');local App=require('am.app')
local Preview=require('am.preview');local Bar=require('am.bar');local U=require('am.util')
local J=require('am.json');local Time=require('am.timeline')

assert(Model.defaults().settings.preview_downmix_mode=='auto')
local old=Model.defaults();old.settings.preview_downmix_mode=nil
assert(Model.validate(old).settings.preview_downmix_mode=='auto')
for _,mode in ipairs{'auto','discrete','ambix'}do
  local definition=Model.defaults();definition.settings.preview_downmix_mode=mode
  assert(Model.validate(J.decode(J.encode(definition))).settings.preview_downmix_mode==mode)
end
for _,invalid in ipairs{false,true,0,'AmbiX','fuma',{},''}do
  local definition=Model.defaults();definition.settings.preview_downmix_mode=invalid
  assert(not pcall(Model.validate,definition),'Invalid downmix mode was accepted')
end

-- Count and basename are independent evidence; neither a parent directory,
-- a substring, nor a generic Ambisonics label establishes ACN/SN3D.
for _,count in ipairs{4,9,16,25,36,49,64,81,100,121}do
  assert(Mix.valid_channels(count))
  for _,path in ipairs{'Ambix.wav','/audio/field_AMBIX.wav','C:\\audio\\field-AmbiX-01.wav',
    '/audio/(ambix).wav','ambix','ambix_01.wav','field.ambix.WAV','録音_ambix.wav'}do
    assert(Mix.detected(path,count),path)
    assert(Mix.resolve(path,count)==2 and Mix.resolve(path,count,'auto')==2)
    assert(Mix.resolve(path,count,'discrete')==1)
  end
  for _,path in ipairs{'/Ambix/field.wav','C:\\Ambix\\field.wav','/field.wav','ambixation.wav',
    'preAmbix.wav','ambix1.wav','1ambix.wav','field_Ambisonics.wav','field_B-format.wav','field_FuMa.wav','/Ambix/'}do
    assert(not Mix.detected(path,count),path)
    assert(Mix.resolve(path,count,'auto')==1 and Mix.resolve(path,count,'ambix')==2)
  end
end
for _,count in ipairs{0,1,2,3,5,6,8,15,24,128,144,256,4.5}do
  assert(not Mix.valid_channels(count)and not Mix.detected('field_Ambix.wav',count))
  assert(Mix.resolve('field_Ambix.wav',count,'auto')==1)
  local mode,reason=Mix.resolve('field.wav',count,'ambix')
  assert(mode==nil and reason:find('full 3D',1,true))
end
assert(not Mix.detected(nil,4)and not Mix.valid_channels(nil))
assert(Mix.describe('field_Ambix.wav',4,'auto')=='Auto: AmbiX')
assert(Mix.describe('field.wav',4,'auto')=='Auto: Discrete')
assert(Mix.describe('field.wav',4,'ambix')=='AmbiX')
assert(Mix.describe('field.wav',6,'ambix')=='AmbiX: unavailable')

local function fixture(playing,enabled)
  local project={}
  local state={project=project,starts=0,stops=0,saves=0,clears=0,syncs=0,position=.75,live_rate=.75,widths={}}
  local app=setmetatable({project=project,path='/field_Ambix.wav',source_channels=4,range={2,8},message='',
    definition=Model.defaults(),transform_override={rate=.5,reverse=true,preserve_pitch=true,pitch_semitones=7},
    r={EnumProjects=function()return state.project end},loudness={},search_session={view=function()return {}end}},App)
  app.definition.settings.preview_downmix=enabled
  local preview=setmetatable({native=true,source_length=10,handle=playing and {}or nil,range=app.range,
    macro=U.copy(app:effective()),get_value=function(_,key)
      return true,key=='D_PLAYRATE' and state.live_rate or key=='D_LENGTH' and 10 or state.position
    end,set_value=function(_,key,value)assert(key=='D_FADEOUTLEN' and value==0);return true end,
    stop_handle=function()state.stops=state.stops+1 end},Preview)
  app.preview=preview
  app.sync_transform=function(self)
    state.syncs=state.syncs+1;self.transform_override.rate=state.live_rate;self.effective_macro=nil
  end
  app.save=function(self)state.saves=state.saves+1;state.saved=J.encode(self.definition);self.effective_macro=nil end
  app.bank={clear_buffers=function()assert(not preview.handle);state.clears=state.clears+1 end,
    set_channels=function(_,count)state.widths[#state.widths+1]=count end}
  app.play=function(self,at,immediate)
    assert(immediate);state.starts=state.starts+1;state.position=at
    state.mode=self.definition.settings.preview_downmix and Mix.resolve(self.path,self.source_channels,self.definition.settings.preview_downmix_mode)or 0
    preview.handle={};preview.macro=U.copy(self:effective());return true
  end
  return app,state
end

-- Mode changes retain source coordinates after a live native rate change,
-- including reverse/range; manual selection can override a filename guess.
do
  local app,state=fixture(true,true)
  local source=Time.source(state.position,10,app.range,{rate=state.live_rate,reverse=true})
  for _,mode in ipairs{'discrete','ambix','auto'}do
    assert(app:set_downmix_mode(mode))
    assert(state.mode==(mode=='discrete' and 1 or 2))
    assert(math.abs(Time.source(state.position,10,app.range,app:effective().source_transform)-source)<1e-10)
    assert(Model.validate(J.decode(state.saved)).settings.preview_downmix_mode==mode)
  end
  assert(state.starts==3 and state.stops==3 and state.clears==3 and state.saves==3)
  app:set_downmix_mode('auto');assert(state.starts==3 and state.saves==3)
  assert(not pcall(app.set_downmix_mode,app,'fuma'))
end

-- OFF changes only the saved preference, even when a preview is playing;
-- stopped/paused settings preserve bookmarks and never start the source.
for _,playing in ipairs{false,true}do
  local app,state=fixture(playing,false);app.source_channels=6
  app.paused_source=5;app.paused_position=6;app.paused_length=10
  app.last_seek={path=app.path,source=4,length=10};local seek=app.last_seek
  assert(app:set_downmix_mode('ambix'))
  assert(state.starts==0 and state.stops==0 and state.clears==0 and state.saves==1 and #state.widths==0)
  assert(app.last_seek==seek and app.paused_source==5 and app.paused_position==6 and app.paused_length==10)
  local ok,reason=app:set_downmix(true)
  assert(ok==false and reason:find('full 3D',1,true)and app.message==reason)
  assert(not app.definition.settings.preview_downmix and state.saves==1 and state.syncs==1)
end
for _,mode in ipairs{'discrete','ambix'}do
  local app,state=fixture(false,true)
  app.paused_source=5;app.paused_position=6;app.paused_length=10
  assert(app:set_downmix_mode(mode))
  assert(state.starts==0 and state.stops==0 and state.clears==1 and state.saves==1)
  assert(app.paused_source==5 and app.paused_position==6 and app.paused_length==10)
end

-- Reject impossible manual AmbiX before saving, stopping, or routing. OFF
-- remains a valid escape after the selected source becomes incompatible.
do
  local app,state=fixture(true,true);app.source_channels=6
  local handle=app.preview.handle
  local ok,reason=app:set_downmix_mode('ambix')
  assert(ok==false and reason:find('full 3D',1,true)and app.definition.settings.preview_downmix_mode=='auto')
  assert(app.preview.handle==handle and state.saves==0 and state.starts==0 and state.stops==0 and state.syncs==0)
  app.definition.settings.preview_downmix_mode='ambix'
  assert(app:set_downmix(false)and not app.definition.settings.preview_downmix and state.mode==0)
end

-- A rejected choice should stop being an error after a successful correction,
-- even while stopped or when returning to the already-selected Auto mode.
-- Notices written by another operation must remain intact.
for _,correction in ipairs{'discrete','auto','off'}do
  local app,state=fixture(false,true);app.source_channels=6
  local ok,reason=app:set_downmix_mode('ambix')
  assert(ok==false and app.message==reason)
  if correction=='off'then assert(app:set_downmix(false))
  else assert(app:set_downmix_mode(correction))end
  assert(app.message==''and app.downmix_error==nil and state.starts==0)
  assert(not Bar.new(app.r,app):state().status:find(reason,1,true))
end
do
  local app=fixture(false,true);app.source_channels=6
  assert(app:set_downmix_mode('ambix')==false)
  local notice='Multichannel preview: source normalization and peak guard are unavailable.'
  app.message=notice
  assert(app:set_downmix_mode('discrete'))
  assert(app.message==notice and app.downmix_error==nil)
end
do
  local app=fixture(false,true);app.source_channels=6
  local ok,reason=app:set_downmix_mode('ambix');assert(ok==false)
  app.save=function()error('fixture save failure')end
  assert(not pcall(app.set_downmix_mode,app,'discrete'))
  assert(app.message==reason and app.downmix_error==reason and app.definition.settings.preview_downmix_mode=='auto')
end

for _,old_mode in ipairs{'auto','discrete','ambix'}do
  local app,state=fixture(true,true);app.definition.settings.preview_downmix_mode=old_mode
  local handle=app.preview.handle;local replacement=old_mode=='discrete' and 'ambix' or 'discrete'
  app.save=function()state.saves=state.saves+1;error('fixture save failure')end
  local ok,reason=pcall(app.set_downmix_mode,app,replacement)
  assert(not ok and tostring(reason):find('fixture save failure',1,true))
  assert(app.definition.settings.preview_downmix_mode==old_mode and app.preview.handle==handle)
  assert(state.starts==0 and state.stops==0 and state.clears==0 and #state.widths==0)
end
do
  local app,state=fixture(true,true);state.project={}
  assert(not pcall(app.set_downmix_mode,app,'ambix'))
  assert(app.definition.settings.preview_downmix_mode=='auto' and state.saves==0 and state.syncs==0 and state.stops==0)
end

-- The native bar always identifies the audible stereo mode, including when
-- another notice replaces its normal status text.
do
  local app=fixture(false,true);local bar=Bar.new(app.r,app)
  app.message='Multichannel preview: source normalization and peak guard are unavailable.'
  local status=bar:state().status
  assert(status:find(app.message,1,true)and status:find('4ch → 2ch',1,true)and status:find('Auto: AmbiX (W/Y M/S)',1,true))
  app.path='/field.wav';status=bar:state().status
  assert(status:find('Auto: Discrete',1,true)and not status:find('W/Y',1,true))
  app.definition.settings.preview_downmix_mode='ambix';status=bar:state().status
  assert(status:find('AmbiX (W/Y M/S)',1,true)and not status:find('Auto:',1,true))
  app.definition.settings.preview_downmix=false;status=bar:state().status
  assert(status:find('4ch',1,true)and not status:find('→ 2ch',1,true)and not status:find('W/Y',1,true))
end
