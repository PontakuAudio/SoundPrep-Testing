-- Run in the marked, muted test host with tests/native_drop_host.mm loaded.
-- Run via bridge.lua twice: first initializes; then select a proper native
-- test.wav subrange and run again in that same Lua test harness environment.
-- This exercises the real Cocoa/SWELL/native insertion path, not mouse synthesis.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
assert(r.APIExists('AM_TestWaveformDrop'),'Load the isolated-host fixture')
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local U=require('am.util');local Model=require('am.model')
local data=r.GetResourcePath()..'/drop-integration';r.RecursiveCreateDirectory(data,0)
if not _G.AMDropTestApp then
 r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
 if r.CountTracks(0)==0 then r.InsertTrackAtIndex(0,false)end
 r.OpenMediaExplorer('/tmp/audition-macro-dev/media-fixtures/test.wav',false)
 App.initialize(r,root,data);local bank=assert(Model.load(data..'/bank.json'))
 for _,m in ipairs(bank.macros)do m.normalization.enabled=false end
 bank.raw=Model.raw_settings();Model.save(data..'/bank.json',bank)
 _G.AMDropTestApp=App.new(r,root,data)
 _G.AMDropTestApp.definition.settings.autoplay=false
 _G.AMDropTestApp:tick();_G.AMDropTestApp.explorer:command(1008);_G.AMDropTestApp.explorer:command(1009)
 _G.AMDropTestApp:play() -- Keep the cursor compositor attached during native D&D.
 return
end
local f=assert(io.open(data..'/drop.txt','w'));f:setvbuf('no')
local function log(...)for _,v in ipairs({...})do f:write(tostring(v),'\t')end;f:write('\n')end
local app=_G.AMDropTestApp;_G.AMDropTestApp=nil
local ok,err=xpcall(function()
 assert(r.CountMediaItems(0)==0,'Start with no items in the test project')
 local ready,path,mode,a,b=r.MediaExplorerGetLastPlayedFileInfo()
 log('native_range',ready,path,mode,a,b)
 assert(ready and path=='/tmp/audition-macro-dev/media-fixtures/test.wav' and (mode&256)~=0 and a>0 and b<1,'Select a subrange in native test.wav first')
 r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
 if r.CountTracks(0)==0 then r.InsertTrackAtIndex(0,false)end
 app:tick()
 assert(app.range and math.abs(app.range[1]-a)<1e-8 and math.abs(app.range[2]-b)<1e-8,'Native selection did not follow automatically')
 local wave=app.explorer:control(1046);local arrange=r.JS_Window_FindChildByID(r.GetMainHwnd(),1000)
 if r.APIExists('AM_WaveCursorState')then
  local cursor=require('am.json').decode(r.AM_WaveCursorState());assert(cursor.attached and cursor.visible,'Exercise drop with an active cursor compositor')
 end
 local expectedTrack=r.GetTrack(0,0)
 log('range',a,b)
 for _,reverse in ipairs{false,true}do for _,handles in ipairs{true,false}do
  app:activate('heavy');app.reverse_override=reverse;app.definition.settings.insert_handles=handles
  app.drop:tick()
  assert(r.AM_TestWaveformDrop(wave,arrange,path),'Native drop rejected: '..r.GetExtState('AuditionMacro.Drop.v1','message'))
  assert(r.CountMediaItems(0)==1)
  local item=r.GetMediaItem(0,0);local take=r.GetActiveTake(item);local src=r.GetMediaItemTake_Source(take)
  assert(r.CountTakes(item)==2 and take==r.GetTake(item,1),'Waveform drop lost original take')
  assert(r.TakeFX_GetCount(take)==0 and r.TakeFX_GetCount(r.GetTake(item,0))==r.TrackFX_GetCount(app.bank.macros.heavy))
  local file=r.GetMediaSourceFileName(src,'');local offset=r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')
  local duration=r.GetMediaItemInfo_Value(item,'D_LENGTH');local full=r.GetMediaSourceLength(src)
  assert(file~=path and r.file_exists(file));assert(r.GetMediaItem_Track(item)==expectedTrack)
  assert(math.abs(duration-(b-a)/.72)<1e-8)
  assert(math.abs(offset-(handles and (reverse and 1-b or a)/.72 or 0))<1e-8)
  assert(math.abs(full-(handles and 1/.72+1 or duration))<1/48000)
  log('processed',reverse,handles,offset,duration,full,file)
  assert(r.Undo_CanUndo2(0)=='Insert SoundPrep')
  assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
  assert(r.Undo_DoRedo2(0)==1 and r.CountMediaItems(0)==1)
  assert(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(r.GetActiveTake(r.GetMediaItem(0,0))),'')==file)
  assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
 end end
 -- A list drag inserts full processed media even while the waveform has a subrange.
 app.drop:tick()
 assert(r.AM_TestWaveformDrop(app.explorer:control(1001),arrange,path))
 local source=r.GetMediaItemTake_Source(r.GetActiveTake(r.GetMediaItem(0,0)))
 while r.GetMediaSourceParent(source)do source=r.GetMediaSourceParent(source)end
 assert(r.GetMediaSourceFileName(source,'')~=path,'List drop was not processed')
 assert(math.abs(r.GetMediaItemInfo_Value(r.GetMediaItem(0,0),'D_LENGTH')-1/.72)<1e-8)
 assert(r.Undo_DoUndo2(0)==1 and r.CountMediaItems(0)==0)
 log('list drag processed as full source')
 local undoBefore=r.Undo_CanUndo2(0)
 assert(not r.AM_TestWaveformDrop(wave,arrange,'/tmp/audition-macro-dev/media-fixtures/impulse.wav'))
 assert(r.CountMediaItems(0)==0 and r.Undo_CanUndo2(0)==undoBefore)
 log('wrong source rejected without undoing earlier work')
 app.identity=U.copy(app.identity);app.identity.size=app.identity.size+1;app.drop:tick()
 assert(not r.AM_TestWaveformDrop(wave,arrange,path));assert(r.CountMediaItems(0)==0)
 log('stale source rejected')
 app.identity=require('am.loudness').identity(r,path)
 Model.find(app.definition,'heavy').normalization.enabled=true;app.effective_macro=nil;app.drop:tick()
 assert(not r.AM_TestWaveformDrop(wave,arrange,path));assert(r.CountMediaItems(0)==0)
 log('unmeasured normalization rejected')
end,debug.traceback)
if app then app:close()end
log(ok and 'PASS' or 'FAIL',err or '');f:close()
