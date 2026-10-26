-- Isolated real Media Explorer: launch silently and retain display preferences.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use the disposable test host')
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local E=require('am.media_explorer')
local U=require('am.util');local J=require('am.json')
local report={status='RUNNING',version=r.GetAppVersion(),checks=J.array{}}
local app;local ex=E.new(r);local initial_tracks=r.CountTracks(0)
local cases={{full=false,leading=false,extension=false},{full=false,leading=true,extension=true},
  {full=true,leading=false,extension=false},{full=true,leading=false,extension=true},
  {full=false,leading=false,extension=false,closed=true}}
local n,stage,due,deadline=1,'load',0,r.time_precise()+20
local dir=host..'/startup-media';local first=dir..'/one.wav';local second=dir..'/two.wav'
local expected;local completed=false
local function snapshot()
  local result={};for _,id in ipairs{42026,42134,42091}do result[tostring(id)]=r.GetToggleCommandStateEx(32063,id)end
  return result
end
local function finish(ok,err)
  if completed then return end;completed=true
  if app then local cleaned,why=pcall(app.close,app);if not cleaned then ok=false;err=tostring(err)..' cleanup: '..tostring(why)end end
  if r.CountTracks(0)~=initial_tracks then ok=false;err=tostring(err)..' tracks not cleaned'end
  report.status=ok and 'PASS'or 'FAIL';report.error=err
  assert(U.write(host..'/startup.json',J.encode(report)))
end
local function next_stage(value,delay)
  stage=value;due=r.time_precise()+(delay or 0);deadline=r.time_precise()+15
end
local function select_row(i)
  local list=assert(ex:control(1001))
  r.JS_ListView_SetItemState(list,-1,0,3)
  r.JS_ListView_SetItemState(list,i,3,3)
end
local function begin_case()
  local case=cases[n]
  ex:toggle(42026,case.full);ex:toggle(42134,case.leading);ex:toggle(42091,case.extension)
  ex:toggle(1011,true);ex:toggle(1068,true);ex:volume(-150)
  r.OpenMediaExplorer(first,false);next_stage('ready',.25)
end
local ok,err=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.RecursiveCreateDirectory(dir..'/a',0);r.RecursiveCreateDirectory(dir..'/b',0)
  local pcm=assert(U.read('/tmp/audition-macro-dev/media-fixtures/latency.wav'))
  for _,path in ipairs{first,second,dir..'/a/same.wav',dir..'/b/same.wav'}do assert(U.write(path,pcm))end
  ex:window(true);begin_case()
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,err=xpcall(function()
    local now=r.time_precise();assert(now<deadline,'Timed out: '..stage)
    if now<due then if app then app:tick()end;return end
    if stage=='ready'then
      if not U.path_equal(ex:selection(),first)then return end
      expected=snapshot()
      local data=host..'/startup-data-'..n;App.initialize(r,root,data)
      local bank=Model.defaults();bank.settings.loop=true;bank.settings.prepare_drops=true;assert(bank.settings.autoplay)
      assert(Model.save(data..'/bank.json',bank))
      if cases[n].closed then ex:command(40069)end
      app=App.new(r,root,data)
      assert(not app.prepare and not package.loaded['am.prepare'],'Legacy setting started a speculative worker')
      if not cases[n].closed then assert(U.path_equal(app.path,first),'Startup did not capture the existing selection')end
      assert(app.preview.starts==0 and not app.preview:playing(),'Startup played the previous file')
      assert(U.equal(snapshot(),expected),'Startup changed display options')
      next_stage('idle',.7)
    elseif stage=='idle'then
      app:tick()
      assert(app.preview.starts==0 and not app.preview:playing(),'Polling replayed the startup selection')
      assert(U.equal(snapshot(),expected),'Polling changed display options')
      if cases[n].closed then
        r.OpenMediaExplorer(second,false);next_stage('changed',.2);return
      end
      -- A deliberate native Play must still reach the companion transport.
      r.BR_Win32_SendMessage(app.explorer:window(),0x111,1008,0)
      next_stage('manual',.1)
    elseif stage=='manual'then
      app:tick();assert(app.preview.starts==1 and app.preview:playing(),'Explicit Play did not start')
      app.preview:stop();r.OpenMediaExplorer(second,false);next_stage('changed',.2)
    elseif stage=='changed'then
      app:tick();if not U.path_equal(app.path,second)then return end
      assert(app.preview.starts==(cases[n].closed and 1 or 2)and app.preview:playing(),'A later selection failed to autoplay')
      assert(U.equal(snapshot(),expected),'Selection changed display preferences')
      app:close();app=nil
      assert(U.equal(snapshot(),expected),'Close changed display preferences')
      assert(r.GetToggleCommandStateEx(32063,1011)==1,'Native autoplay was not restored')
      report.checks[#report.checks+1]={case=n,closed=cases[n].closed or false,display=expected,launch_starts=0,
        manual_starts=cases[n].closed and 0 or 1,selection_starts=cases[n].closed and 1 or 2}
      n=n+1
      if cases[n]then begin_case()else
        ex:toggle(42026,false);ex:toggle(42134,false);ex:toggle(42091,false)
        ex:toggle(42019,true);ex:command(40015)
        r.OpenMediaExplorer(first,false);ex:search('same');next_stage('search_ready',.4)
      end
    elseif stage=='search_ready'then
      local list=ex:control(1001)
      if r.JS_ListView_GetItemCount(list)~=2 then return end
      expected=snapshot();select_row(0);next_stage('search_first',.2)
    elseif stage=='search_first'then
      local path=ex:selection()
      assert(path==dir..'/a/same.wav'or path==dir..'/b/same.wav','Hidden-path search failed: '..tostring(path))
      assert(U.equal(snapshot(),expected),'Search resolution changed display preferences')
      report.search_first=path:sub(#dir+2)
      select_row(1);next_stage('search_second',.2)
    elseif stage=='search_second'then
      local path=ex:selection()
      assert(path==dir..'/a/same.wav'or path==dir..'/b/same.wav','Second search path unresolved')
      assert(path:sub(#dir+2)~=report.search_first,'Same-name search reused the first path')
      assert(U.equal(snapshot(),expected),'Second search changed display preferences')
      report.search_second=path:sub(#dir+2)
      local data=host..'/startup-search';App.initialize(r,root,data)
      app=App.new(r,root,data);assert(app.path==path)
      assert(app.preview.starts==0 and U.equal(snapshot(),expected),'Search startup changed display or played')
      next_stage('search_idle',.5)
    elseif stage=='search_idle'then
      app:tick();assert(app.preview.starts==0,'Search polling restarted audio')
      ex:toggle(42134,true);ex:toggle(42091,true);expected=snapshot()
      app:close();app=nil
      assert(U.equal(snapshot(),expected),'Close undid a display edit made while attached')
      report.checks[#report.checks+1]='Recursive search resolves duplicate hidden filenames and keeps later display edits'
      finish(true)
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not completed then r.defer(tick)end
end
r.defer(tick)
