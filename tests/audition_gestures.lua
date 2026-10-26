local App=require('am.app');local Drop=require('am.drop');local U=require('am.util')
-- REAPER reports loop selections (128) as well as time selections (256).
-- Exercise the real reader: a mocked range bypassed the reported Windows bug.
do
  local mode,a,b=576,0,1
  local native={MediaExplorerGetLastPlayedFileInfo=function()return true,'/source.wav',mode,a,b end,
    PCM_Source_CreateFromFile=function()return {}end,GetMediaSourceLength=function()return 10,false end,
    PCM_Source_Destroy=function()end}
  local explorer=require('am.media_explorer').new(native)
  local starts=0
  local app=setmetatable({explorer=explorer,path='/source.wav',preview={playing=function()return false end},
    play=function(self,position,immediate)
      assert(position==0 and immediate and self.range[1]==2 and self.range[2]==7)
      starts=starts+1
    end},App)
  for _,selection in ipairs{128,256,384}do
    mode,a,b=576,0,1;app:sync_range(false)
    mode,a,b=576|selection,.2,.7;app:sync_range(true)
    assert(starts>0 and app.range and app.range[1]==2 and app.range[2]==7,'Native selection was ignored: '..mode)
    local before=starts;app:sync_range(true);assert(starts==before,'Unchanged selection replayed')
  end
  assert(starts==3)
end
local valid,range=true,nil;local playing,starts,stops=false,0,0
local ext={};local project={};local now=1
local r={GetExtState=function(section,key)return ext[section..key] or ''end,
  SetExtState=function(section,key,value)ext[section..key]=value end,
  DeleteExtState=function(section,key)ext[section..key]=nil end,
  EnumProjects=function()return project end,ValidatePtr=function()return true end,time_precise=function()return now end,
  GetToggleCommandStateEx=function()return 1 end}
local app=setmetatable({r=r,path='/source.wav',project=project,session='current',last_poll=1,last_stat=1,
  definition={settings={poll_ms=20,loop=false,autoplay=false}},
  bank={tracks={},valid=function()return true end},loudness={poll=function()end},
  explorer={preview_range=function()return valid,range and U.copy(range)end,
    wave_event=function()end,transport_event=function()end,selection=function()return '/source.wav'end,
    window=function()return {}end,command=function()error('Drop advanced to the next file')end},
  preview={playing=function()return playing end,stop=function(self)playing=false;stops=stops+1;self.ended_path=nil end},
  play=function(self,position,immediate)
    assert(position==0 and immediate,'Range audition must bypass beat/bar start alignment')
    playing=true;starts=starts+1;self:sync_range(false)
  end,
  publish=function()end,sync_transform=function()end},App)
-- Initial/no-range reads and another file's stale range do not autoplay.
app:sync_range(true);assert(starts==0)
valid=false;range={2,8};app:sync_range(true);assert(starts==0)
valid=true;app.paused_source=5;app.paused_length=10;app.last_seek={source=5}
app:sync_range(true)
assert(playing and starts==1 and not app.paused_source and not app.paused_length and not app.last_seek)
app:sync_range(true);assert(starts==1,'Unchanged range restarted audio')
range={3,7};app:sync_range(true);assert(starts==2)
playing=false;range={4,6};app:sync_range(true);assert(playing and starts==3)
playing=false;range=nil;app:sync_range(true);assert(starts==3,'Clearing a stopped range started audio')
range={1,5};app:sync_range(false);assert(starts==3,'Loading existing bounds started audio')
playing=true;range=nil;app:sync_range(true);assert(starts==4)

app.drop=setmetatable({r=r,app=app,tick=function()end},Drop)
r.SetExtState(Drop.EXT,'preview_stop','old-session');app:tick()
assert(playing and stops==0,'A stale session stopped this preview')
-- Completion takes precedence over old paused/seek/EOF state and
-- a range change reported when the modal native drop returns to Lua.
range={2,8};app.paused_source=4;app.paused_position=2
app.paused_length=10;app.last_seek={};app.advance_path='/next.wav'
app.preview.ended_path=app.path
r.SetExtState(Drop.EXT,'preview_stop',app.session)
app:tick()
assert(not playing and stops==1 and starts==4 and not app.preview.ended_path)
for _,key in ipairs{'paused_source','paused_position','paused_length','last_seek','pending_wave','advance_path'}do
  assert(app[key]==nil,'Drop retained '..key)
end
app:tick();assert(not playing and starts==4,'Range polling restarted a completed drop')
range={3,9};app:tick();assert(playing and starts==5,'A later range gesture did not play')
