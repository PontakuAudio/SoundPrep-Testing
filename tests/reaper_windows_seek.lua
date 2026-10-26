-- Real decoder/preview EOF and messages to the actual Windows waveform control.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test') and r.GetOS():match('^Win'))
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app')
local app,done;local phase=0;local began=r.time_precise();local untilTime
local path=host.."/media 素材/test one's 音.wav"
local result={status='RUNNING',checks=J.array{},clicks=J.array{},version=r.GetAppVersion()}
local starts,loads,sequence,expected,handle
local function check(name)
  result.checks[#result.checks+1]=name;assert(U.write(host..'/windows-review-progress.json',J.encode(result)))
end
local function finish(ok,why)
  if done then return end;done=true
  if app then app:close()end
  result.status=ok and 'PASS' or 'FAIL';result.error=why;result.elapsed=r.time_precise()-began
  assert(U.write(host..'/windows-review.json',J.encode(result)))
end
r.atexit(function()finish(false,'Seek test stopped early')end)
local function click(fraction)
  local wave=assert(app.explorer:control(1046));local ok,width,height=r.JS_Window_GetClientSize(wave)
  assert(ok and width>20 and height>10)
  local state=J.decode(r.AM_WaveDiagnostics());sequence=state.last_seek and state.last_seek.sequence or 0
  expected=fraction*2;starts=app.preview.starts;loads=app.bank.loads
  local x,y=math.floor(width*fraction),math.floor(height/2)
  -- Post both messages before yielding: REAPER's modal mouse handler can consume
  -- button-up internally. A synchronous down followed by up can deadlock it.
  assert(r.JS_WindowMessage_Post(wave,'WM_LBUTTONDOWN',1,0,x,y))
  assert(r.JS_WindowMessage_Post(wave,'WM_LBUTTONUP',0,0,x,y))
  untilTime=r.time_precise()+3
end
local function clicked(playing)
  local state=J.decode(r.AM_WaveDiagnostics());local event=state.last_seek
  if not event or event.sequence<=sequence or not app.last_seek then
    assert(r.time_precise()<untilTime,'Native waveform click was not delivered: '..r.AM_WaveDiagnostics());return false
  end
  assert(math.abs(event.fraction*2-expected)<.02,'Click source coordinate differs from waveform position')
  assert(app.preview:playing()==playing,'Click did not preserve the intended playback state')
  if playing then
    local position=app.preview:source_position()
    assert(math.abs(position-expected)<.1,'Restart did not use clicked source position: '..tostring(position))
    assert(select(2,app.preview:get('D_MEASUREALIGN'))==-1,'EOF click waits for next bar')
  else assert(math.abs(app.paused_source-expected)<.02)end
  assert(app.bank.loads==loads,'Seek reloaded the FX chain')
  result.clicks[#result.clicks+1]={source=expected,playing=playing,applied=event.applied,delivery=event.delivery}
  return true
end
local function near_end()
  local _,position,length=app.preview:playing();assert(position and length)
  app.preview:seek(math.max(0,length-.1));untilTime=r.time_precise()+5
end
local initialized,why=xpcall(function()
  r.JS_Window_Show(r.GetMainHwnd(),'SHOW');r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  local ancestor=r.OpenMediaExplorer(path,false)
  for _=1,8 do if not ancestor then break end;r.JS_Window_Show(ancestor,'SHOW');ancestor=r.JS_Window_GetParent(ancestor)end
  app=App.new(r,root,host..'/seek-data');app.definition.settings.autoplay=false;app.definition.settings.loop=false
  app.explorer:toggle(1068,false);app.explorer:toggle(42004,false);app.explorer:command(42093)
end,debug.traceback)
if not initialized then finish(false,why);return end
local function tick()
  local ok,why=xpcall(function()
    assert(r.time_precise()-began<45,'Seek test timed out')
    if r.AM_DropContext()~=''then app:publish();return end
    app:tick()
    if phase==0 then
      if r.time_precise()-began<.6 or not U.path_equal(app.path,path)then return end
      app:play();near_end();phase=1
    elseif phase==1 then
      if app.preview:playing()then assert(r.time_precise()<untilTime,'Preview never reached EOF');return end
      assert(not app.preview.handle and app.preview.eof_path and not app.preview.ended_path)
      untilTime=r.time_precise()+.3;phase=2
    elseif phase==2 then
      if r.time_precise()<untilTime then return end
      click(.3);phase=3
    elseif phase==3 then
      if not clicked(true)then return end
      assert(app.preview.starts==starts+1,'EOF click did not create exactly one new preview')
      check('Native waveform click restarts from its position after consumed EOF and an idle gap')
      handle=app.preview.handle;click(.6);phase=4
    elseif phase==4 then
      if not clicked(true)then return end
      assert(app.preview.handle==handle and app.preview.starts==starts,'Playing click unnecessarily restarted preview')
      app:native_transport(1009);click(.2);phase=5
    elseif phase==5 then
      if not clicked(false)then return end
      assert(app.preview.starts==starts);app:resume();app:native_transport(1010);click(.7);phase=6
    elseif phase==6 then
      if not clicked(false)then return end
      assert(app.preview.starts==starts);check('Playing click keeps its handle; explicit Stop and Pause remain bookmark-only')
      app:activate('heavy');app:reverse();app:play();near_end();phase=7
    elseif phase==7 then
      if app.preview:playing()then assert(r.time_precise()<untilTime);return end
      assert(app.preview.eof_path)
      -- The click should ignore Start on bar, including during project playback.
      app.explorer:toggle(1012,true);app.explorer:toggle(42171,true)
      r.SetEditCurPos(.15,false,false);r.OnPlayButton()
      click(.55);phase=8
    elseif phase==8 then
      if not clicked(true)then return end
      assert(app.preview.starts==starts+1 and r.GetPlayStateEx(0)&1==1)
      assert(app:effective().source_transform.reverse and app:effective().source_transform.rate==.72)
      r.OnStopButton();app.explorer:toggle(1012,false)
      check('EOF click maps reverse/rate source position and starts immediately without waiting for a bar')
      app:activate(nil)
      for _,entry in ipairs{{1455,'0:00.400'},{1456,'0:01.600'}}do
        local c=assert(app.explorer:control(entry[1]));r.JS_Window_SetFocus(c);r.JS_Window_SetTitle(c,entry[2])
        r.JS_WindowMessage_Send(c,'WM_KEYDOWN',13,0,0,0);r.JS_WindowMessage_Send(c,'WM_KEYUP',13,0,0,0)
      end
      untilTime=r.time_precise()+3;phase=9
    elseif phase==9 then
      if not(app.range and math.abs(app.range[1]-.4)<.002 and math.abs(app.range[2]-1.6)<.002)then
        assert(r.time_precise()<untilTime,'Native range edit did not commit');return
      end
      near_end();phase=10
    elseif phase==10 then
      if app.preview:playing()then assert(r.time_precise()<untilTime);return end
      assert(app.preview.eof_path);click(.5);phase=11
    elseif phase==11 then
      if not clicked(true)then return end
      assert(app.preview.starts==starts+1 and app.preview.range and math.abs(app.preview.range[1]-.4)<.002)
      check('Selected-section EOF replays the clicked source position within the same range')
      near_end();phase=12
    elseif phase==12 then
      if app.preview:playing()then assert(r.time_precise()<untilTime);return end
      app:native_transport(1009);assert(not app.preview.eof_path);click(.6);phase=13
    elseif phase==13 then
      if not clicked(false)then return end
      assert(app.preview.starts==starts);check('Explicit Stop after EOF cancels click-to-replay and keeps the seek bookmark')
      finish(true)
    end
  end,debug.traceback)
  if not ok then finish(false,why)elseif not done then r.defer(tick)end
end
tick()
