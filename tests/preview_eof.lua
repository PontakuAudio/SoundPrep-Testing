local Preview=require('am.preview');local App=require('am.app');local U=require('am.util')
local preview=setmetatable({path=[[C:\素材\sound.wav]],source_length=10,handle={},
  get_value=function()return false,0 end,stop_handle=function()end},Preview)
assert(not preview:playing() and not preview.handle)
assert(preview.ended_path==preview.path and preview.eof_path==preview.path)
preview.ended_path=nil -- The app consumed its single next-file notification.
for _=1,5 do assert(not preview:playing() and preview.eof_path==preview.path and not preview.ended_path)end
local event={path='c:/素材/SOUND.wav',fraction=.4,applied=false}
local started={};local range;local reverse,rate=false,1
local app=setmetatable({r={GetOS=function()return 'Win64'end},path=event.path,preview=preview,
  explorer={wave_event=function()local e=event;event=nil;return e end,preview_range=function()return true,range end},
  effective=function()return {source_transform={rate=rate,reverse=reverse}}end,
  play=function(self,position,immediate)
    assert(immediate,'EOF click waited for a bar boundary')
    started[#started+1]=position;self.preview:stop()
  end},App)
app:sync_wave();assert(started[1]==4 and not preview.eof_path)
-- EOF can be first discovered on the click tick, before the usual end-of-tick poll.
preview.handle={};event={path=app.path,fraction=.7};app:sync_wave();assert(started[2]==7)
-- Convert the clicked source position using the current range, rate and direction.
reverse=true;rate=.5;range={2,8};app.range=U.copy(range)
preview.handle={};event={path=app.path,fraction=.3};app:sync_wave();assert(started[3]==10)
-- Stop, Pause and accepted D&D all call Preview:stop(), even after natural EOF.
for _=1,3 do
  preview.handle={};preview:playing();preview:stop()
  event={path=app.path,fraction=.5};app:sync_wave()
  assert(#started==3 and app.paused_source==5 and not preview.eof_path)
end
preview.eof_path='C:/different.wav';event={path=app.path,fraction=.5};app:sync_wave()
assert(#started==3,'Completion on another source restarted this file')
-- A new selection has priority over an old click and completion bookmark.
event={path='C:/different.wav',fraction=.5}
app.explorer.selection=function()return app.path end
app:sync_wave();assert(#started==3 and not app.pending_wave)
-- EOF on the second position read (inside seek_source) must not eat the click.
local reads=0
preview:stop();preview.handle={};preview.macro={source_transform={rate=1,reverse=false}}
preview.get_value=function(_,key)
  if key=='D_POSITION'then reads=reads+1;return reads==1,9.99 end
  return true,10
end
reverse=false;rate=1;range=nil;app.range=nil
event={path=app.path,fraction=.6};app:sync_wave()
assert(#started==4 and started[4]==6,'EOF between status check and seek swallowed the click')
