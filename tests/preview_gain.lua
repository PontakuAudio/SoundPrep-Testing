local Preview=require('am.preview');local Model=require('am.model');local U=require('am.util')
local now,position=0,3
local handle={};local valid=true;local writes={};local fail_write=false
local macro=Model.macro('test','Test')
local preview=setmetatable({handle=handle,path='/test.wav',source_channels=6,source_length=10,
  macro=U.copy(macro),gain_db=0,starts=1,native=false,
  r={time_precise=function()return now end},
  get_value=function(h,key)
    assert(h==handle)
    if not valid then return false end
    return true,key=='D_POSITION' and position or key=='D_LENGTH' and 10 or 0
  end,
  set_value=function(h,key,value)
    assert(h==handle)
    if fail_write then return false end
    writes[#writes+1]={key=key,value=value};return true
  end,
  stop_handle=function(h)assert(h==handle);valid=false end},Preview)
local function advance(seconds)
  now=now+seconds;preview:tick_gain(now)
end
assert(preview:fade_gain(6)and preview.gain_db==0 and #writes==0)
for _=1,10 do
  now=now+.01
  preview:fade_gain(6) -- Polling the same result must not postpone the ramp.
  preview:tick_gain(now)
end
assert(math.abs(preview.gain_db-.6)<1e-10 and preview.gain_target==6)
local before=preview.gain_db
advance(30) -- A modal drag must never release a large accumulated gain jump.
assert(math.abs(preview.gain_db-before-.15)<1e-10)
before=preview.gain_db
advance(-1)
assert(preview.gain_db==before,'A clock moving backwards changed gain')
assert(preview:fade_gain(-3))
advance(.025)
assert(math.abs(preview.gain_db-before+.15)<1e-10,'Retargeting did not start from the audible gain')
while preview.gain_target do advance(.025)end
assert(preview.gain_db==-3 and preview.handle==handle and preview.starts==1 and position==3)
local previous=0
for _,write in ipairs(writes)do
  assert(write.key=='D_VOLUME','Automatic gain wrote a transport or transform property')
  local db=20*math.log(write.value,10)
  assert(math.abs(db-previous)<=.150000001,'A gain step exceeded the click-reduction bound')
  previous=db
end

-- A normal Pitch edit must keep the in-flight normalization transition.
assert(preview:fade_gain(3));advance(.025)
local current=preview.gain_db
local edited=U.copy(macro);edited.source_transform.pitch_semitones=7
assert(preview:reconfigure(edited,3,Model.defaults().settings))
assert(preview.gain_db==current and preview.gain_target==3)
advance(.025);assert(preview.gain_db>current and preview.gain_db<3)
-- An explicit new gain equal to the current level cancels the old target.
current=preview.gain_db
assert(preview:reconfigure(edited,current,Model.defaults().settings))
assert(preview.gain_target==nil and preview.gain_db==current)
advance(1);assert(preview.gain_db==current)
assert(preview:update_gain(1)and preview.gain_db==1)

-- Reverse needs a new immutable SECTION, but must carry the audible gain.
assert(preview:fade_gain(6));advance(.025);current=preview.gain_db
local start=preview.start
preview.start=function(self,path,new_macro,gain,settings,range,at)
  assert(path=='/test.wav'and gain==current and at==7)
  self:stop();valid=true;self.handle=handle;self.gain_db=gain;self.macro=U.copy(new_macro)
  self.starts=self.starts+1;return true
end
edited.source_transform.reverse=true
assert(preview:reconfigure(edited,6,Model.defaults().settings))
assert(preview.gain_db==current and preview.gain_target==6)
preview.start=function()return false,'Source is no longer supported'end
edited.source_transform.reverse=false
local changed,reason=preview:reconfigure(edited,8,Model.defaults().settings)
assert(changed==false and reason=='Source is no longer supported')
assert(preview.gain_db==current and preview.gain_target==6,'A rejected SECTION change retargeted the old source')
preview.start=start

-- Stop, EOF and a rejected late setter never resurrect or retarget playback.
preview:stop()
assert(preview.gain_target==nil and not preview:fade_gain(8))
assert(not preview:tick_gain(now+1))
valid=true;preview.handle=handle;preview.gain_db=0
assert(preview:fade_gain(4));valid=false
advance(.025)
assert(preview.handle==nil and preview.gain_target==nil)
valid=true;preview.handle=handle
assert(preview:fade_gain(4));fail_write=true
advance(.025)
assert(preview.gain_db==0 and preview.gain_target==nil)
fail_write=false
assert(not pcall(preview.fade_gain,preview,0/0),'Non-finite gain was accepted')

-- A stream of genuinely different targets must progress instead of resetting
-- its clock forever, and must always start from the currently audible level.
for i=1,60 do
  now=now+1/60
  preview:fade_gain(6+i/10);preview:tick_gain(now)
end
assert(preview.gain_db>5.8 and preview.gain_db<6 and preview.gain_target==12)
