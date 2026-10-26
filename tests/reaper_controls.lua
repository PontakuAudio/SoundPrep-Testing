-- Native control round trips, live CF updates and Raw normalization in the owned host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local U=require('am.util');local Model=require('am.model');local L=require('am.loudness')
local E=require('am.media_explorer');local data=r.GetResourcePath()..'/controls-test'
r.RecursiveCreateDirectory(data,0);local f=assert(io.open(data..'/controls.txt','w'));f:setvbuf('no')
local app,frame,done=nil,0,false;local initial=E.new(r)
local function finish(ok,e)
  if done then return end;done=true
  if app then app:close()end
  local restored=initial:transform()
  if restored.pitch_semitones~=3 or restored.rate~=1.25 or restored.preserve_pitch then ok=false;e=tostring(e)..' native transform not restored'end
  if r.GetToggleCommandStateEx(32063,40070)~=1 or r.GetToggleCommandStateEx(32063,42014)~=1 then ok=false;e=tostring(e)..' native selection/reset mode not restored'end
  f:write(ok and 'PASS\n' or 'FAIL '..tostring(e)..'\n');f:close()
end
local function value(name)return select(2,app.preview:get(name))end
local ok,e=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  initial:window(true);initial:command(40070);initial:toggle(42014,true)
  initial:set_transform{pitch_semitones=3,rate=1.25,preserve_pitch=false}
  App.initialize(r,root,data);local b=assert(Model.load(data..'/bank.json'))
  b.settings.autoplay=false;b.settings.loop=true;b.raw=Model.raw_settings()
  for _,m in ipairs(b.macros)do m.normalization.enabled=false end
  Model.save(data..'/bank.json',b);app=App.new(r,root,data)
  assert(r.GetToggleCommandStateEx(32063,40015)==1 and r.GetToggleCommandStateEx(32063,1011)==0)
  r.OpenMediaExplorer('/tmp/audition-macro-dev/long.wav',false)
end,debug.traceback)
if not ok then finish(false,e);return end
local function tick()
  local ok,e=xpcall(function()
    frame=frame+1;app:tick()
    if frame==12 then
      local loaded,path=r.MediaExplorerGetLastPlayedFileInfo()
      assert(loaded and path=='/tmp/audition-macro-dev/long.wav','Stop-and-display did not load selected waveform')
      app:activate('heavy');app:play();app.preview:seek_source(6)
      local native=app.explorer:transform();assert(native.rate==.72 and native.pitch_semitones==-4)
      assert(not native.preserve_pitch and value('B_PPITCH')==0,'Preserve Pitch default must be OFF')
    elseif frame==16 then
      local ready,path=r.MediaExplorerGetLastPlayedFileInfo()
      assert(ready and path==app.path,'Starting CF audition unloaded the native waveform')
      local handle=app.preview.handle;local starts=app.preview.starts
      app:set_preserve_pitch(true)
      assert(app.explorer:transform().preserve_pitch and value('B_PPITCH')==1,'Preserve Pitch ON did not reach the live preview')
      app:activate('dark');app:activate('heavy')
      assert(app:effective().source_transform.preserve_pitch and value('B_PPITCH')==1,'Preset switch lost Preserve Pitch edit')
      app:set_preserve_pitch(false);app:save_preset()
      assert(not Model.find(assert(Model.load(data..'/bank.json')),'heavy').source_transform.preserve_pitch,'Preserve Pitch OFF was not saved')
      assert(not app.explorer:transform().preserve_pitch and value('B_PPITCH')==0)
      assert(app.preview.handle==handle and app.preview.starts==starts,'Preserve Pitch toggle restarted playback')
      app.explorer:set_number(1021,7);app.explorer:set_number(1454,.5);app.explorer:toggle(40068,false)
      if app.preview.native then
        r.BR_Win32_SendMessage(app.explorer:window(),0x111,(512<<16)|1454,0)
        assert(value('D_PITCH')==7 and value('D_PLAYRATE')==.5 and value('B_PPITCH')==0,
          'Native control response waited for Lua defer')
      end
      app:tick()
      assert(value('D_PITCH')==7 and value('D_PLAYRATE')==.5 and value('B_PPITCH')==0,'Native controls did not update CF')
      assert(app.preview.handle==handle and app.preview.starts==starts,'Native controls restarted preview')
      assert(Model.find(app.definition,'heavy').source_transform.rate==.72,'Native adjustment overwrote stored Macro')
      local edit=U.copy(Model.find(app.definition,'heavy'));edit.source_transform.pitch_semitones=9;edit.source_transform.rate=.8
      app:audition_edit(edit);assert(value('D_PITCH')==9 and value('D_PLAYRATE')==.8)
      assert(app.preview.handle==handle,'Editor slider restarted preview')
      app:revert_preset();assert(value('D_PITCH')==-4 and value('D_PLAYRATE')==.72)
      assert(r.MediaExplorerGetLastPlayedFileInfo(),'Editor changes unloaded the waveform')
      f:write('waveform loaded without play; native pitch/rate/preserve and editor sliders updated same CF instance\n')
      app:activate(nil)
      app:set_preserve_pitch(true)
      assert(app.explorer:transform().preserve_pitch and value('B_PPITCH')==1,'Raw Preserve Pitch toggle is unavailable')
      app:set_preserve_pitch(false)
      assert(not app.explorer:transform().preserve_pitch and value('B_PPITCH')==0)
      f:write('Preserve Pitch defaults OFF, toggles live for Macro and Raw, retains drafts and saves OFF without restarting playback\n')
      local measurement={status='ready',max_momentary_lufs=-24,true_peak_dbtp=-16,duration=12,channels=1,
        identity=app.identity,profile=L.PROFILE,analyzer_key=app.loudness.analyzer_key}
      app.loudness.memory[L.key(app.identity,app.loudness.analyzer_key)]=measurement
      app:set_normalization(true,-18)
      assert(math.abs(value('D_VOLUME')-U.gain(6))<1e-10 and not app:effective().fx_chain)
      app:activate('heavy');assert(not app:effective().normalization.enabled)
      app:activate(nil);assert(app:effective().normalization.enabled and app:gain()==6)
      app:save_preset('raw')
      local loaded=assert(Model.load(data..'/bank.json'));assert(loaded.raw.normalization.target_lufs==-18 and loaded.raw.normalization.enabled)
      f:write('Raw gain applied live, persisted independently, retained across A/B\n')
      -- Stop while native transport is already stopped must stop CF without
      -- clearing its waveform. Send a genuine unsuppressed SWELL notification.
      r.BR_Win32_SendMessage(app.explorer:window(),0x111,1009,0)
    elseif frame==18 then
      assert(not app.preview:playing(),'Native Stop did not stop CF')
      assert(r.MediaExplorerGetLastPlayedFileInfo(),'Native Stop unloaded the waveform')
      r.BR_Win32_SendMessage(app.explorer:window(),0x111,1008,0)
    elseif frame==20 then
      assert(app.preview:playing() and r.MediaExplorerGetLastPlayedFileInfo(),'Native Play lost CF or waveform')
      app:play();app:play();assert(r.MediaExplorerGetLastPlayedFileInfo(),'Repeated replay unloaded waveform')
      f:write('native Stop/Play and repeated CF replay retain waveform\n');finish(true)
    elseif frame>100 then error('Timed out')end
  end,debug.traceback)
  if not ok then finish(false,e)elseif not done then r.defer(tick)end
end
tick()
