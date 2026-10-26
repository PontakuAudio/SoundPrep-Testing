-- Real bank persistence and one-click switching in a disposable host only.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local Bar=require('am.bar');local Editor=require('am.editor_panel');local Settings=require('am.settings_panel')
local U=require('am.util');local J=require('am.json');local C=require('am.chunk')
local result={status='RUNNING',checks=J.array{}};local app,done,phase,untilTime=nil,false,0,0
local data=host..'/preset-test';local began=r.time_precise();local frames=0
local function check(name)result.checks[#result.checks+1]=name;U.write(host..'/windows-review-progress.json',J.encode(result))end
local function finish(ok,err)
  if done then return end;done=true
  if app then app:close()end
  result.status=ok and 'PASS' or 'FAIL';result.error=err
  assert(U.write(host..'/windows-review.json',J.encode(result)))
end
r.atexit(function()finish(false,'Preset test terminated early')end)
local function run()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.OpenMediaExplorer(host.."/media 素材/test one's 音.wav",false)
  app=App.new(r,root,data);app.definition.settings.autoplay=false
  app.bar=Bar.new(r,app);app.bar:tick();app:activate('heavy')
  local draft=app:preset_draft('heavy');draft.name='Test preset';draft.source_transform.rate=.63;draft.source_transform.pitch_semitones=-7
  app:audition_edit(draft)
  local fixture=host..'/import.RfxChain';assert(U.write(fixture,'SHOW -1\nBYPASS 0 0 0\n<JS utility/volume_pan ""\n-9 0 0\n>\nWAK 0 0\n'))
  local originalFX=assert(U.read(data..'/chains/heavy.RfxChain'))
  app:import_chain('heavy',fixture)
  assert(U.read(data..'/chains/heavy.RfxChain')==originalFX,'Import saved FX before Save preset')
  local track=app.bank.macros.heavy;local loads=app.bank.loads
  for _=1,25 do app:activate('dark');app:activate('heavy')end
  assert(app:effective().name=='Test preset' and app:effective().source_transform.rate==.63)
  assert(app.bank.loads==loads and app.bank.macros.heavy==track,'Switching reloaded FX')
  assert(Model.find(assert(Model.load(data..'/bank.json')),'heavy').name=='Heavy','Draft was saved during switching')
  check('Preset switching retains live parameters and imported FX without saving or reloading plugins')
  app.tempo_factor=1.5;app.effective_macro=nil
  app:save_preset('heavy')
  local saved=Model.find(assert(Model.load(data..'/bank.json')),'heavy')
  assert(saved.name==draft.name and saved.source_transform.rate==.63 and saved.source_transform.pitch_semitones==-7,'Save preset lost Pitch/Rate or baked tempo match')
  assert(C.portable(assert(U.read(data..'/chains/heavy.RfxChain')))==C.portable(app.bank:chain('heavy')))
  local replacement=U.copy(saved);replacement.output_gain_db=-3;app:apply_edit(replacement)
  app:activate('dark');app:activate('heavy')
  assert(app:effective().output_gain_db==-3,'A previous draft replaced the newly saved preset')
  draft=app:preset_draft('heavy')
  check('Save preset stores FX and all sound parameters together, excluding tempo-match multiplier')
  app.tempo_factor=1;app.effective_macro=nil
  local storedBank=assert(U.read(data..'/bank.json'));local storedFX=assert(U.read(data..'/chains/heavy.RfxChain'))
  draft.source_transform.pitch_semitones=5;app:audition_edit(draft);r.TrackFX_SetParam(track,0,0,-3)
  local save=Model.save;Model.save=function()return nil,'Injected disk failure'end
  local ok,why=pcall(app.save_preset,app,'heavy');Model.save=save
  assert(not ok and tostring(why):find('Injected disk failure',1,true))
  assert(U.read(data..'/bank.json')==storedBank and U.read(data..'/chains/heavy.RfxChain')==storedFX,'Failed save left half a preset persisted')
  assert(app:effective().source_transform.pitch_semitones==5,'Failed save discarded live edits')
  app:revert_preset('heavy')
  assert(app:effective().source_transform.pitch_semitones==-7 and math.abs(r.TrackFX_GetParam(track,0,0)+9)<1e-6)
  check('Failed saves roll back FX and retain drafts; Revert saved restores parameters and FX together')
  local changed=app:preset_draft('heavy');changed.name='Close saves this';app:audition_edit(changed)
  local analyzer=app.loudness
  app.definition.settings.monitor_gain_db=-18;app:save_settings()
  assert(app.loudness==analyzer,'Changing monitor settings restarted loudness analysis')
  local settings=assert(Model.load(data..'/bank.json'))
  assert(settings.settings.monitor_gain_db==-18 and Model.find(settings,'heavy').name=='Test preset','App settings saved an unrelated preset draft')
  check('App settings save independently without committing a preset draft')
  app:close();app=App.new(r,root,data);app:activate('heavy')
  assert(app:effective().name=='Close saves this' and math.abs(r.TrackFX_GetParam(app.bank.macros.heavy,0,0)+9)<1e-6)
  check('Quit and reopen preserve the complete preset, including sound parameters and FX')
  app.bar=Bar.new(r,app);app.bar:tick()
  local browser=app.explorer:window();local list=app.explorer:control(1001)
  local parent=r.JS_Window_GetParent(list);local bar=r.JS_Window_FindChildByID(parent,100) -- Locate by class below.
  local _,children=r.JS_Window_ListAllChild(parent)
  for address in children:gmatch('[^,]+')do local w=r.JS_Window_HandleFromAddress(tonumber(address));if r.JS_Window_GetClassName(w)=='AuditionMacroBar'then bar=w;break end end
  assert(bar and r.JS_Window_FindChildByID(bar,200),'No direct Macro buttons')
  local button=r.JS_Window_FindChildByID(bar,201)
  r.BR_Win32_SendMessage(button,0xF5,0,0);app.bar:tick()
  assert(app.selected_id=='dark','Single button click did not select the preset')
  r.BR_Win32_SendMessage(button,0xF5,0,0);app.bar:tick()
  assert(r.BR_Win32_SendMessage(button,0xF0,0,0)==1,'Reselecting active preset cleared its highlight')
  check('Direct Macro button selects in one click and remains selected on repeated clicks')
  app:activate('heavy');Editor.open(app,0);Settings.open(app)
  local inspect=tonumber(U.read(host..'/.audition-macro-test-inspect'))or 0
  if inspect>0 then
    r.JS_Window_SetTitle(r.GetMainHwnd(),'Audition Macro UX test — disposable host')
    r.JS_Window_Show(r.GetMainHwnd(),'SHOWNA');r.JS_Window_Show(browser,'SHOWNA')
    local p=r.JS_Window_GetParent(browser);if p then r.JS_Window_Show(p,'SHOWNA')end
  end
  untilTime=r.time_precise()+math.max(1.5,inspect);phase=1
end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()-began<100,'Preset test timed out')
    if phase==0 then run()
    elseif phase==1 then
      frames=frames+1
      if frames<=21 and frames%5==1 then Editor.open(app,math.floor((frames-1)/5))end
      app.bar:tick()
      local geometry=J.decode(r.AM_BarGeometry())
      assert(geometry.editor_open and geometry.settings_open,'Native panels did not stay open')
      if frames==26 then Editor.open(app,0);check('Native Presets, Tools and App settings remain open across page changes')end
      if frames>=26 and r.time_precise()>=untilTime then finish(true)end
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
r.defer(tick)
