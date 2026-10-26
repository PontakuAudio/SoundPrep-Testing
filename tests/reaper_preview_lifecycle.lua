-- Short files, transformed EOF, repeated source changes and fade disposal.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
package.path=root..'/lib/?.lua;'..package.path
local Model=require('am.model');local Preview=require('am.preview')
local directory=r.GetResourcePath()..'/preview-lifecycle';r.RecursiveCreateDirectory(directory,0)
local log=assert(io.open(directory..'/lifecycle.txt','w'));log:setvbuf('no')
local project=r.EnumProjects(-1);r.SetMediaTrackInfo_Value(r.GetMasterTrack(project),'D_VOL',0)
r.InsertTrackAtIndex(r.CountTracks(project),false);local track=r.GetTrack(project,r.CountTracks(project)-1)
r.SetMediaTrackInfo_Value(track,'I_PERFFLAGS',3)
local preview=Preview.new(r,project,track);assert(preview.native)
local settings=Model.defaults().settings;settings.loop=false;settings.preview_fade_ms=5
local macro=Model.macro('lifecycle','Lifecycle');local step,started,expected=0,nil,nil
local done=false
local function finish(ok,e)
  if done then return end;done=true;preview:stop()
  if r.ValidatePtr2(project,track,'MediaTrack*')then r.DeleteTrack(track)end
  log:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');log:close()
end
local function tick()
  local ok,e=xpcall(function()
    local now=r.time_precise()
    if started then
      local playing=preview:playing()
      if playing then assert(now-started<expected+.5,'Transformed EOF did not release the preview');return end
      assert(now-started>expected-.12,'Preview ended before the selected source duration')
      log:write(('EOF %d %.3f sec\n'):format(step,now-started));started=nil
    end
    step=step+1
    if step>4 then
      for _=1,24 do preview:start('/tmp/audition-macro-dev/media-fixtures/test.wav',macro,0,settings);preview:stop()end
      r.DeleteTrack(track);log:write('24 starts/stops followed by track deletion during retirement\n');finish(true);return
    end
    macro.source_transform.pitch_semitones=step==1 and 0 or -4
    macro.source_transform.rate=({1,.5,2,.1})[step];macro.source_transform.reverse=step%2==0
    expected=.4/macro.source_transform.rate
    preview:start('/tmp/audition-macro-dev/media-fixtures/test.wav',macro,0,settings,{.2,.6})
    started=now
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
