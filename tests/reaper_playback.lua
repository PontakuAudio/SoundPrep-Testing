-- Real-API regression for range repeat and drops while the timeline plays.
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use the disposable test host')
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app')
local result={status='RUNNING',checks=J.array{},loops=J.array{}}
local path=host.."/media 素材/test one's 音.wav"
local app,done;local began=r.time_precise();local phase=0;local deadline
local cases={{id=false,pp=false},{id='heavy',pp=false},{id='heavy',pp=true},{id='dark',pp=true,timeline=true}}
local caseIndex=1;local previous;local sample
local function start_case()
  local case=cases[caseIndex];app:activate(case.id or nil);app:set_preserve_pitch(case.pp)
  if case.timeline then r.SetEditCurPos(.1,false,false);r.OnPlayButton()end
  app:play(0,true);previous=nil
  sample={macro=case.id or 'raw',preserve_pitch=case.pp,wraps=0,min_peak=math.huge,
    native=r.GetToggleCommandStateEx(32063,1068),setting=app.definition.settings.loop,
    preview=select(2,app.preview:get('B_LOOP')),length=select(2,app.preview:get('D_LENGTH'))}
  result.loops[#result.loops+1]=sample
  deadline=r.time_precise()+math.max(3,sample.length*4.5)
end
local function report()assert(U.write(host..'/windows-review-progress.json',J.encode(result)))end
local function finish(ok,err)
  if done then return end;done=true;r.OnStopButton()
  if app then app:close()end
  result.status=ok and 'PASS' or 'FAIL';result.error=err
  assert(U.write(host..'/windows-review.json',J.encode(result)))
end
r.atexit(function()finish(false,'Playback test terminated early')end)
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()-began<25,'Playback test timed out')
    if not app then
      r.JS_Window_Show(r.GetMainHwnd(),'SHOW')
      r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
      local w=r.OpenMediaExplorer(path,false)
      for _=1,8 do if not w then break end;r.JS_Window_Show(w,'SHOW');w=r.JS_Window_GetParent(w)end
      app=App.new(r,root,host..'/playback-data');app.definition.settings.autoplay=false
      deadline=r.time_precise()+.5
    end
    if phase~=10 then app:tick()end
    if phase==0 and r.time_precise()>deadline and U.path_equal(app.path,path)then
      app:activate(nil);app:play();app.preview:stop()
      for _,v in ipairs{{1455,'0:00.200'},{1456,'0:00.450'}}do
        local c=assert(app.explorer:control(v[1]));r.JS_Window_SetFocus(c);r.JS_Window_SetTitle(c,v[2])
        r.JS_WindowMessage_Send(c,'WM_KEYDOWN',13,0,0,0);r.JS_WindowMessage_Send(c,'WM_KEYUP',13,0,0,0)
      end
      phase=1;deadline=r.time_precise()+2
    elseif phase==1 then
      if not(app.range and math.abs(app.range[1]-.2)<.002 and math.abs(app.range[2]-.45)<.002)then
        assert(r.time_precise()<deadline,'Range did not commit');return
      end
      app.explorer:toggle(1068,false);app.definition.settings.loop=false;app:play(0,true)
      if r.GetToggleCommandStateEx(32063,1068)~=1 then
        local button=assert(app.explorer:control(1068))
        r.JS_WindowMessage_Send(button,'WM_LBUTTONDOWN',1,0,5,5)
        r.JS_WindowMessage_Send(button,'WM_LBUTTONUP',0,0,5,5)
      end
      assert(select(2,app.preview:get('B_LOOP'))==1,'Repeat waited for Lua; a short range can reach EOF first')
      deadline=r.time_precise()+.8;phase=10;previous=nil;result.pending_tick_wraps=0
    elseif phase==10 then
      local playing,pos=app.preview:playing();assert(playing,'Repeat stopped before Lua could consume the button event')
      if previous and pos<previous-.01 then result.pending_tick_wraps=result.pending_tick_wraps+1 end;previous=pos
      if r.time_precise()<deadline then return end
      assert(result.pending_tick_wraps>=2 and r.Track_GetPeakInfo(app.bank.input,0)>.001)
      result.checks[#result.checks+1]='Repeat crosses section EOF while the Lua transport event is still pending'
      app:tick();result.actions={}
      for _,id in ipairs{1068,40039,40040}do result.actions[tostring(id)]=r.CF_GetCommandText(32063,id)end
      local button=app.explorer:control(1068)
      result.button=button and r.JS_Window_GetClassName(button) or 'missing'
      start_case();phase=2
    elseif phase==2 then
      local playing,pos=app.preview:playing()
      assert(playing,'Range playback stopped')
      if previous and pos<previous-.01 then sample.wraps=sample.wraps+1 end;previous=pos
      if sample.wraps>0 then sample.min_peak=math.min(sample.min_peak,r.Track_GetPeakInfo(app.bank.input,0))end
      if r.time_precise()<deadline then return end
      report();assert(sample.wraps>=3 and sample.min_peak>.001,'Range repeat became silent')
      caseIndex=caseIndex+1
      if cases[caseIndex]then start_case();return end
      result.checks[#result.checks+1]='Raw/Macro/Preserve Pitch range repeat';report();app.preview:stop()
      r.SetEditCurPos(.1,false,false);r.OnPlayButton();deadline=r.time_precise()+.25;phase=3
    elseif phase==3 and r.time_precise()>deadline then
      local D=require('am.render_item');local E=require('am.export');local L=require('am.loudness')
      local snapshot=E.snapshot(r,path,app:effective(),'',0,L.identity(r,path),nil,app.definition.settings)
      local before=r.GetPlayPosition2Ex(app.project)
      local directory=host..'/playback-render';r.RecursiveCreateDirectory(directory,0)
      local success,output=pcall(D.render,r,snapshot,directory,'during-playback')
      assert(not success and tostring(output):find('Render waits until playback',1,true))
      assert(r.GetPlayStateEx(app.project)&1==1,'Rejected render interrupted playback')
      r.OnStopButton();local rendered=D.render(r,snapshot,directory,'after-playback')
      assert(r.file_exists(rendered))
      result.render={rejected_while_playing=true,rendered_after_stop=true,position=before}
      result.checks[#result.checks+1]='Synchronous item renderer preserves playback by waiting for Stop'
      report();finish(true)
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
