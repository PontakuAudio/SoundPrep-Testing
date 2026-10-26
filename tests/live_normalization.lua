local App=require('am.app');local Preview=require('am.preview');local Model=require('am.model')
local L=require('am.loudness');local A=require('am.analysis_policy');local U=require('am.util');local J=require('am.json')
local function fixture(channels,enabled,path)
  channels=channels or 2;path=path or '/source.wav'
  local project={};local state={now=0,project=project,live=true,writes={},starts=0,stops=0,fade_calls=0,position=2}
  local identity={path=path,size=100,mtime=10}
  local r={EnumProjects=function()return state.project end,time_precise=function()return state.now end,
    JS_File_Stat=function()return 0,identity.size,0,identity.mtime end}
  local definition=Model.defaults();definition.raw.normalization.enabled=true;definition.raw.normalization.target_lufs=-18
  definition.settings.preview_downmix=enabled or false
  local app=setmetatable({r=r,project=project,identity=U.copy(identity),path=path,source_channels=channels,
    definition=definition,message='Unmeasured: playing while analysis runs. Normalization applies automatically.',
    loudness={analyzer_key='test'},measurement=function()return state.measurement end,
    sync_range=function()return false end,sync_transform=function()end,
    explorer={selection=function()return app and app.path or path end,ensure_waveform=function()end},
    bank={activate=function()end,input={},chosen={}}},App)
  -- Lua initializers cannot capture the local being declared.
  app.explorer.selection=function()return app.path end
  local preview=setmetatable({r=r,project=project,handle={},path=path,source_channels=channels,source_length=10,
    downmix_mode=channels>2 and enabled and(path:find('ambix',1,true)and 2 or 1)or 0,
    gain_db=0,macro=U.copy(app:effective()),native=false,
    get_value=function(_,key)
      if not state.live then return false,0 end
      return true,key=='D_POSITION'and state.position or key=='D_LENGTH'and 10 or 0
    end,
    set_value=function(handle,key,value)
      if state.fail_set then state.live=false;return false end
      state.writes[#state.writes+1]={handle=handle,key=key,value=value};return true
    end,
    stop_handle=function()state.live=false;state.stops=state.stops+1 end},Preview)
  app.preview=preview
  app.playback_identity=U.copy(identity);app.playback_analysis=U.copy(app:analysis_spec())
  preview.fade_gain=function(self,db)state.fade_calls=state.fade_calls+1;return Preview.fade_gain(self,db)end
  app.request_analysis=function()end
  local function measurement(status,peak)
    local spec=app:analysis_spec()
    return {identity=U.copy(app.identity),analysis=U.copy(spec),profile=L.profile(spec),analyzer_key='test',
      status=status or 'ready',channels=channels,duration=10,max_momentary_lufs=status=='silence'and J.null or -24,
      true_peak_dbtp=peak or -12}
  end
  local function advance(seconds)
    state.now=state.now+(seconds or .02);return app:update_normalization(state.now)
  end
  return app,state,measurement,advance
end
local function volume_writes(state)
  local count=0;for _,entry in ipairs(state.writes)do if entry.key=='D_VOLUME'then count=count+1 end end;return count
end

-- Zwicker completion uses its calibrated solver target, and target edits hold
-- the current audible level while invalidating an obsolete ongoing ramp.
do
  local app,state,result,advance=fixture(4,false,'/field_ambix.wav')
  app.definition.raw.normalization.metric='zwicker_max';app.effective_macro=nil
  app.playback_analysis=U.copy(app:analysis_spec())
  local function zwicker(gain)
    local value=result();value.zwicker_sones=2.5;value.normalization_gain_db=gain;value.gain_status='ready';return value
  end
  state.measurement=zwicker(9);advance();advance()
  assert(app.preview.gain_target==9 and app.preview.gain_db>0 and state.starts==0)
  local old=state.measurement;local before=app.preview.gain_db;local writes=volume_writes(state)
  app.definition.raw.normalization.target_sones=16;app.effective_macro=nil;app:refresh_processing()
  assert(app.preview.gain_db==before and not app.preview.gain_target and volume_writes(state)==writes)
  for _=1,5 do advance()end
  assert(app.preview.gain_db==before,'A stale Zwicker target continued changing the current audio')
  state.measurement=zwicker(-3);advance();assert(app.preview.gain_target==-3)
  for _=1,100 do advance()end
  assert(app.preview.gain_db==-3 and state.starts==0 and state.stops==0)
  state.measurement=old;advance();assert(app.preview.gain_db==-3 and not app.preview.gain_target)
end

-- High-crest sources must never ramp toward an unsafe loudness target, even
-- with the original default guard=false, a saved bank, or a cached restart.
for _,metric in ipairs{'lufs_m_max','zwicker_max','zwicker_p95'}do
  local app,state,result,advance=fixture()
  app.definition.raw.normalization.metric=metric;app.effective_macro=nil
  app.playback_analysis=U.copy(app:analysis_spec())
  assert(not app:effective().source_peak_guard.enabled)
  state.measurement=result(nil,-2)
  state.measurement.max_momentary_lufs=-40
  state.measurement.zwicker_sones=.1;state.measurement.normalization_gain_db=24;state.measurement.gain_status='ready'
  advance();assert(app.preview.gain_target==1 and app.applied_status=='source peak capped')
  for _=1,80 do
    advance();assert(app.preview.gain_db<=1,'Live normalization ramp exceeded the source ceiling')
  end
  assert(app.preview.gain_db==1 and not app.preview.gain_target)
  assert(app:gain()==1,'Cached normalization returned an unsafe restart gain')
  assert(state.starts==0 and state.stops==0)
end
-- A delayed completion changes only gain on the existing source handle.
do
  local app,state,result,advance=fixture();local handle=app.preview.handle
  advance();assert(volume_writes(state)==0 and not app.preview.gain_target)
  state.measurement=result();advance()
  assert(app.preview.gain_target==6 and app.preview.gain_db==0 and volume_writes(state)==0)
  assert(app.message==''and app.applied_status=='ready')
  for _=1,80 do
    local before=app.preview.gain_db;advance()
    assert(app.preview.gain_db>=before and app.preview.gain_db-before<=.1500001)
    assert(app.applied_gain==app.preview.gain_db and app.preview.handle==handle and state.position==2)
  end
  assert(app.preview.gain_db==6 and not app.preview.gain_target and state.fade_calls==1)
  local writes=volume_writes(state);advance();advance()
  assert(volume_writes(state)==writes and state.starts==0 and state.stops==0,'Completion restarted or repeatedly reconfigured playback')
end

-- Apply the latest preset target, including all multichannel analysis bases.
for _,case in ipairs{{2,false,'/stereo.wav'},{6,false,'/six.wav'},{6,true,'/six.wav'},
  {4,false,'/field_ambix.wav'},{4,true,'/field_ambix.wav'}}do
  local app,state,result,advance=fixture(table.unpack(case))
  app.definition.raw.normalization.target_lufs=-21;app.effective_macro=nil
  state.measurement=result();advance()
  assert(app.preview.gain_target==3,'Completion used parameters captured before the latest edit')
  assert(A.same(app.playback_analysis,state.measurement.analysis))
end

-- Silent AmbiX W still carries finite peaks from the other original channels.
do
  local app,state,result,advance=fixture(4,false,'/field_ambix.wav')
  app.definition.raw.source_peak_guard.enabled=true;app.effective_macro=nil
  state.measurement=result('silence',3);advance();advance()
  assert(app.preview.gain_target==-4 and app.preview.gain_db<0 and app.applied_status=='source peak capped')
end

-- The current playback identity, actual decoder mode, source count and project
-- must all match before a ready measurement can affect the native handle.
for _,change in ipairs{
  function(a)a.identity.mtime=11 end,
  function(a)a.playback_identity.mtime=9 end,
  function(a)a.path='/another.wav'end,
  function(a)a.preview.path='/another.wav'end,
  function(a)a.source_channels=9 end,
  function(a)a.preview.source_channels=9 end,
  function(a)a.preview.downmix_mode=1 end,
  function(_,s)s.project={}end,
  function(a)a.closed=true end,
  function(a)a.cleaned=true end,
  function(_,s)s.live=false end,
}do
  local app,state,result,advance=fixture(4,false,'/field_ambix.wav')
  state.measurement=result();change(app,state)
  assert(advance()==false and volume_writes(state)==0 and state.fade_calls==0)
end
for _,change in ipairs{
  function(v)v.identity.mtime=9 end,function(v)v.profile=L.PROFILE end,
  function(v)v.analyzer_key='other'end,function(v)v.analysis.basis='downmix_ambix'end,
  function(v)v.status='error'end,function(v)v.channels=2 end,
}do
  local app,state,result,advance=fixture(4,false,'/field_ambix.wav')
  state.measurement=result();change(state.measurement);advance()
  assert(not app.preview.gain_target and volume_writes(state)==0,'A stale/invalid measurement changed source gain')
end

-- A force refresh temporarily removes a good cache entry. Preserve both an
-- ongoing target and a completed gain while pitch/rate edits are made.
do
  local app,state,result,advance=fixture();state.measurement=result();advance()
  for _=1,5 do advance()end
  state.measurement=nil;local before=app.preview.gain_db
  app.transform_override={pitch_semitones=7};app.effective_macro=nil
  local writes=volume_writes(state);app:refresh_processing()
  assert(app.preview.gain_target==6 and app.preview.gain_db==before and volume_writes(state)==writes,
    'A pitch edit reset an ongoing normalization transition during force refresh')
  state.loudness_error='Worker timeout';app.loudness.error=state.loudness_error
  app.message='Could not save preset'
  for _=1,80 do advance()end
  assert(app.preview.gain_db==6 and not app.preview.gain_target and app.message=='Could not save preset')
  app:refresh_processing();assert(app.preview.gain_db==6,'Force refresh reverted normalized audio to unity')
  state.measurement=result();app.message='Could not save preset';advance()
  assert(app.message=='Could not save preset','Automatic normalization hid an unrelated application error')
end

-- Changing the OFF interpretation may legitimately choose another reference
-- without replacing the source handle. Its old policy cannot keep ramping.
do
  local app,state,result,advance=fixture(4,false,'/field_ambix.wav')
  state.measurement=result();advance();advance();local before=app.preview.gain_db
  app.definition.settings.preview_downmix_mode='discrete';state.measurement=nil
  advance();assert(app.preview.gain_db==before,'A previous analysis policy continued applying gain')
  app:refresh_processing()
  assert(app.preview.gain_db==0 and not app.preview.gain_target and app.playback_analysis.basis=='loudest_channel')
  state.measurement=result();advance();assert(app.preview.gain_target==6,'The new OFF reference was blocked by playback-start policy')
end

-- Disable normalization explicitly, then ignore completion. Stop/Pause/EOF
-- never start playback; their cached result will be used by a later Play.
do
  local app,state,result,advance=fixture();state.measurement=result();advance();advance()
  app.definition.raw.normalization.enabled=false;app.effective_macro=nil;app:refresh_processing()
  assert(app.preview.gain_db==0 and not app.preview.gain_target)
  advance();assert(not app.preview.gain_target and app.applied_status=='off')
end
for _,ending in ipairs{'stop','pause','eof'}do
  local app,state,result,advance=fixture();state.measurement=result();advance();advance()
  if ending=='eof'then state.live=false
  else app.paused_source=ending=='pause'and 4 or nil;app.preview:stop()end
  local writes=volume_writes(state);advance();advance()
  assert(not app.preview.handle and not app.preview.gain_target and volume_writes(state)==writes and state.starts==0)
  if ending=='pause'then assert(app.paused_source==4)end
end
do
  local app,state,result,advance=fixture();state.measurement=result();advance();state.fail_set=true
  advance();assert(not app.preview.gain_target and volume_writes(state)==0,'An EOF setter failure left a stale transition')
end

-- The successful App play path owns the frozen identity used by later ticks.
do
  local app,state,result=fixture();state.measurement=result()
  app.playback_identity=nil;app.playback_analysis=nil
  app.preview.start=function(self,path,macro,gain)
    state.starts=state.starts+1;self.path=path;self.gain_db=gain;return true
  end
  assert(app:play(0,true))
  assert(L.same(app.playback_identity,app.identity)and app.playback_identity~=app.identity and app.applied_gain==6)
  app.identity.mtime=11;assert(app.playback_identity.mtime==10,'Playback identity aliases the mutable current source')
end
