-- Physical drag integration probe. Run only with run_windows_integration.py --drag-test.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test') and r.GetOS():match('^Win'))
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app')
local app,done,last=false,false,'';local start=r.time_precise();local ready=false
local path=host.."/media 素材/test one's 音.wav"
local function finish(ok,err)
  if done then return end;done=true
  local result={status=ok and 'PASS' or 'FAIL',error=err,diagnostics=J.decode(r.AM_DropDiagnostics()),
    last_drop_seconds=tonumber(r.GetExtState('AuditionMacro.Drop.v1','last_drop_seconds'))}
  if app then app:close()end
  assert(U.write(host..'/windows-review.json',J.encode(result)))
end
r.atexit(function()finish(false,'Drag test stopped')end)
local ok,err=xpcall(function()
  r.JS_Window_Show(r.GetMainHwnd(),'SHOW')
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.InsertTrackAtIndex(0,false)
  r.GetSetMediaTrackInfo_String(r.GetTrack(0,0),'P_NAME','Physical drag target',true)
  local explorer=r.OpenMediaExplorer(path,false);local ancestor=explorer
  for _=1,8 do if not ancestor then break end;r.JS_Window_Show(ancestor,'SHOW');ancestor=r.JS_Window_GetParent(ancestor)end
  app=App.new(r,root,host..'/drag-data');app.definition.settings.autoplay=false
  app.bar=require('am.bar').new(r,app);app:activate('heavy')
  r.TrackList_AdjustWindows(false);r.UpdateArrange()
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()-start<600,'No verified physical drop before timeout')
    app:tick();app.bar:tick()
    if not ready and app.path then app:play();app.preview:stop();ready=true end
    local items=J.array{}
    for i=0,r.CountMediaItems(0)-1 do
      local item=r.GetMediaItem(0,i);local take=r.GetActiveTake(item)
      items[#items+1]={takes=r.CountTakes(item),fx=r.TakeFX_GetCount(r.GetTake(item,0)),
        rendered=take==r.GetTake(item,1),path=r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')}
    end
    local progress={status=ready and 'READY' or 'STARTING',message=app.message,items=items,
      diagnostics=J.decode(r.AM_DropDiagnostics()),
      last_drop_seconds=tonumber(r.GetExtState('AuditionMacro.Drop.v1','last_drop_seconds'))}
    local encoded=J.encode(progress)
    if encoded~=last then assert(U.write(host..'/windows-review-progress.json',encoded));last=encoded end
    if r.file_exists(host..'/.finish-drag-test')then
      assert(#items>=2,'Test at least two physical insertions before finishing')
      for _,item in ipairs(items)do assert(item.takes==2 and item.rendered and item.fx>0,'Drop was not rendered with editable Source FX')end
      finish(true)
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
