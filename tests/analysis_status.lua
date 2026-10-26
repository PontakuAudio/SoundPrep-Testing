local Bar=require('am.bar');local Model=require('am.model')
local project={};local identity={path='/source.wav',size=100,mtime=1}
local other={path='/other.wav',size=100,mtime=1}
local definition=Model.defaults();definition.raw.normalization.enabled=true
local measurement
local app={project=project,definition=definition,identity=identity,message='',loudness={wanted=identity},
  preview={playing=function()return false end},search_session={view=function()return {}end},
  effective=function()return Model.effective(definition,nil)end,
  gain=function()return 0,measurement and measurement.status or 'unmeasured'end,
  measurement=function()return measurement end}
local bar=Bar.new({EnumProjects=function()return project end},app)
assert(bar:state().target==-18 and bar:state().target_label==nil)
local function status()return bar:state().status end
local pending='Drop cancelled: Analysis pending: source.wav. Wait for completion, then drag again.'
app.message=pending
assert(status()==pending,'An unresolved analysis prerequisite needs an actionable message')
app.loudness.active={identity=identity}
assert(status():find('analysing',1,true)and not status():find('Drop cancelled',1,true))
app.message='Unmeasured: playing without normalization. Analysis applies on replay.'
assert(status():find('analysing',1,true),'The initial playback notice must not hide ongoing analysis')
app.loudness.active=nil;app.loudness.error='Analysis timeout';app.message=pending
assert(status()=='Analysis failed: Analysis timeout','A pending drop notice must not hide the worker failure')
app.loudness.error=nil;app.loudness.active={identity=other,cancelled=true};app.loudness.queued=identity
assert(status():find('analysis queued',1,true))
app.loudness.active=nil;app.loudness.queued=nil
measurement={status='ready',max_momentary_lufs=-18}
for _,notice in ipairs{pending,'Drop cancelled: Analysis required: source.wav.','Drop cancelled: Analysis failed: source.wav.'}do
  app.message=notice
  assert(status():find('LUFS-M',1,true)and not status():find('Drop cancelled',1,true),'Completed analysis left a stale drop rejection')
end
measurement=nil;app.loudness.error='Unrelated source failed';app.loudness.wanted=other;app.message=''
assert(not status():find('failed',1,true),'Another source\'s analysis error leaked into the current status')
app.loudness.wanted=identity;app.message='Could not save preset'
assert(status()==app.message,'An unrelated application error must remain visible')
definition.raw.normalization.metric='zwicker_p95';app.message='';app.loudness.error=nil
measurement={status='ready',zwicker_sones=8.25}
assert(status():find('Zwicker P95 8.25 sones',1,true)and not status():find('LUFS-M',1,true))
assert(bar:state().target_label=='Norm 36.00 sones','Zwicker target must use the preset sones value, not its inactive LUFS target')
definition.raw.normalization.target_sones=12.5
assert(bar:state().target_label=='Norm 12.50 sones')
bar:dispatch('target:-18')
assert(app.editor_panel_open and app.editor_page==1 and definition.raw.normalization.target_lufs==-18)
app.editor_panel_open=false
definition.raw.normalization.enabled=false;definition.raw.source_peak_guard.enabled=true
measurement={status='ready',max_momentary_lufs=-18,true_peak_dbtp=-4}
assert(status():find('LUFS-M',1,true)and not status():find('Zwicker',1,true),'Peak-only measurement was formatted as a missing Zwicker result')
definition.raw.normalization.metric='lufs_m_max'
assert(bar:state().target_label==nil and bar:state().target==-18)

-- Closed panels must not build hidden contents or publish hidden diagnostics.
local Channels=require('am.channel_panel');local Settings=require('am.settings_panel');local U=require('am.util')
local channel_state,settings_state=Channels.state,Settings.state
local channel_calls,settings_calls=0,0
local ok,err=xpcall(function()
  Channels.state=function(a)channel_calls=channel_calls+1;return channel_state(a)end
  Settings.state=function(a)settings_calls=settings_calls+1;return settings_state(a)end
  local previous=bar:state()
  for i=1,120 do
    app.bank={loads=i,switches=i};app.preview.starts=i
    local state=bar:state();assert(U.equal(state,previous),'Hidden diagnostics changed the toolbar')
    assert(not state.channels and not state.settings and not state.editor)
  end
  assert(channel_calls==0 and settings_calls==0)
  bar:dispatch('channels');bar:dispatch('settings')
  local state=bar:state();assert(state.channels.open and state.settings.open)
  assert(state.settings.diagnostics:find('Source starts: 120',1,true))
  bar:dispatch('channels:close');bar:dispatch('settings:close')
  assert(not bar:state().channels and not bar:state().settings)
  assert(channel_calls==1 and settings_calls==1)
  definition.settings.autoplay=false;app.preview.starts=121
  bar:dispatch('settings');state=bar:state()
  assert(not state.settings.values.autoplay and state.settings.diagnostics:find('Source starts: 121',1,true))
end,debug.traceback)
Channels.state,Settings.state=channel_state,settings_state
assert(ok,err)
