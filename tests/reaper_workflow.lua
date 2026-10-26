local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
assert(reaper.file_exists(reaper.GetResourcePath()..'/.audition-macro-test'),'Use the disposable test host')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local r=reaper;local U=require('am.util');local Model=require('am.model');local App=require('am.app');local Bar=require('am.bar');local Editor=require('am.editor_panel')
local data=r.GetResourcePath()..'/workflow-test';r.RecursiveCreateDirectory(data,0)
local f=assert(io.open(data..'/workflow.txt','w'));f:setvbuf('no')
local function log(...)for _,v in ipairs({...})do f:write(tostring(v),'\t')end;f:write('\n')end
local app,frame,stage,closed=nil,0,0,false
local count=r.CountTracks(0)
local original_volume,original_autoplay
local function finish(ok,err)
  if closed then return end;closed=true
  if app then app:close()end
  if r.CountTracks(0)~=count then ok=false;err=tostring(err)..' track cleanup mismatch' end
  log(ok and 'PASS' or 'FAIL',err or '');f:close()
end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  App.initialize(r,root,data)
  local b=assert(Model.load(data..'/bank.json'));b.settings.autoplay=false;Model.save(data..'/bank.json',b)
  local E=require('am.media_explorer');local ex=E.new(r);ex:window(true);ex:volume(-9)
  original_volume=ex:text(997);original_autoplay=r.GetToggleCommandStateEx(32063,1011)
  app=App.new(r,root,data);app.bar=Bar.new(r,app);Editor.open(app);app.bar:tick()
  assert(app.explorer.native_transport,'Native transport helper unavailable in test host')
  local m=app:new_macro('heavy');assert(app.selected_id==m.id);local duplicate_id=m.id
  local edit=U.copy(m);edit.name='テスト duplicate';edit.normalization.enabled=false;app:apply_edit(edit)
  app:slot(duplicate_id,9);app:move(duplicate_id,-1)
  assert(app.definition.slots['9']==duplicate_id and app.bank:chain(duplicate_id):find('<JS',1,true))
  app:activate('reverse');app:reverse();assert(not app:effective().source_transform.reverse)
  app:activate('reverse');assert(not app:effective().source_transform.reverse)
  app:revert_preset();assert(app:effective().source_transform.reverse)
  app:activate(nil);assert(not app:effective().source_transform.reverse)
  app:delete(duplicate_id);assert(not Model.find(app.definition,duplicate_id) and not app.definition.slots['9'])
  app:search('',false,false)
  r.OpenMediaExplorer('/tmp/audition-macro-dev/search-fixtures/slam.wav',false)
end,debug.traceback)
if not ok then finish(false,e);return end
local function loop()
  local ok,err=xpcall(function()
    frame=frame+1;app.bar:tick();app:tick()
    if stage==0 and frame>10 then
      app:search('slam',true,false);stage=1;frame=0
    elseif stage==1 and frame>20 then
      local list=app.explorer:control(1001);local n=r.JS_ListView_GetItemCount(list);local names={}
      if n~=2 and frame<90 then return end -- Native directory/search refresh is asynchronous.
      for i=0,n-1 do names[#names+1]=r.JS_ListView_GetItemText(list,i,0)end
      log('search_names',table.concat(names,' | '));assert(n==2,'Native OR search did not find both slam and hit')
      assert(r.GetToggleCommandStateEx(32063,42051)==0,'Enter-only search setting changed')
      app:search('',false,false)
      r.OpenMediaExplorer('/tmp/audition-macro-dev/test.wav',false)
      stage=2;frame=0
    elseif stage==2 and frame>10 then
      app:activate(nil)
      app.definition.settings.loop=true;app.explorer:toggle(1068,true)
      -- SWS calls SWELL SendMessage directly. All JS message send wrappers
      -- deliberately skip registered observers and cannot exercise this path.
      r.BR_Win32_SendMessage(app.explorer:window(),0x111,1008,0)
      stage=3;frame=0
    elseif stage==3 and frame>5 then
      log('native_play_followed',app.preview:playing());log('native_starts',app.preview.starts,'message',app.message)
      assert(app.preview:playing(),'Native Play did not reach SWS transport')
      r.BR_Win32_SendMessage(app.explorer:window(),0x111,1009,0)
      stage=4;frame=0
    elseif stage==4 and frame>5 then
      assert(not app.preview:playing(),'Native Stop did not reach SWS transport')
      require('am.action').send(r,'slot:1');require('am.action').send(r,'reverse');app:commands()
      assert(app.selected_id=='heavy' and app:effective().source_transform.reverse)
      require('am.action').send(r,'slot:0');app:commands();assert(app.selected_id==nil and not app:effective().source_transform.reverse)
      local heavy=app:preset_draft('heavy');heavy.export.normalize_final=true;heavy.export.true_peak_limit=true
      heavy.normalization.target_lufs=-14;app:activate('heavy');app:audition_edit(heavy);app.range={.1,.6}
      app.export_dir=data..'/exports';log('normalized_render',app:export(false))
      -- Closing the ME window before the companion must still restore settings.
      app.explorer:command(40069);app:close()
      local E=require('am.media_explorer');local ex=E.new(r);ex:window(true)
      log('restored_volume',ex:text(997),'original_volume',original_volume)
      assert(tonumber(ex:text(997))==tonumber(original_volume),'Native preview volume not restored')
      assert(r.GetToggleCommandStateEx(32063,1011)==original_autoplay,'Native autoplay not restored')
      finish(true)
    elseif frame>300 then error('Workflow stage timed out: '..stage)end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not closed then r.defer(loop)end
end
loop()
