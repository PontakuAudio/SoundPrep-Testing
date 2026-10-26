-- Isolated real-decoder, audio-routing, Downmix and native-bar regression.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test'),'Use the disposable test host')
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local Preview=require('am.preview')
local Explorer=require('am.media_explorer');local Bar=require('am.bar');local U=require('am.util');local J=require('am.json')
local report={status='RUNNING',version=r.GetAppVersion(),checks=J.array{},audio=J.array{},transformed_audio=J.array{},ambix_audio=J.array{},transitions=J.array{},selected_audio=J.array{}}
report.audio_device_info_available,report.audio_sample_rate=r.GetAudioDeviceInfo('SRATE')
local dir=host..'/channel-fixtures';r.RecursiveCreateDirectory(dir,0)
local channels={1,3,4,6,8,2};local paths={};local app,track
local ambix_fixtures={
  {name='W_center_AMBIX',samples={4000,0,0,0}},
  {name='Y_positive_ambix',samples={0,3000,0,0}},
  {name='Y_negative_AmBiX',samples={0,-3000,0,0}},
  {name='ZX_ignored_ambix',samples={0,0,5000,-6000}},
  {name='higher_ignored_ambix',samples={0,0,0,0,2500,-3000,3500,-4000,4500}},
  {name='all_components_aMbIx',samples={4000,2000,3000,4000,5000,6000,7000,8000,9000},roundtrip=true},
  {name='B_format',samples={4000,2000,3000,4000},auto_mode=1,overrides=true},
}
local function check(text)report.checks[#report.checks+1]=text end
local function finish(ok,err)
  if app then local closed,why=pcall(app.close,app);if not closed then ok=false;err=tostring(err)..' cleanup: '..tostring(why)end end
  if track and r.ValidatePtr2(0,track,'MediaTrack*')then r.DeleteTrack(track)end
  report.status=ok and 'PASS' or 'FAIL';report.error=err
  assert(U.write(host..'/preview-channels.json',J.encode(report)))
end
local ok,err=xpcall(function()
  require('am.native').require(r)
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  for _,n in ipairs(channels)do
    local frame={};for c=1,n do frame[c]=string.pack('<i2',1000*c)end
    local pcm=string.rep(table.concat(frame),48000*3);paths[n]=dir..'/'..n..'ch.wav'
    local wav='RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,n,48000,48000*n*2,n*2,16)..'data'..string.pack('<I4',#pcm)..pcm
    assert(U.write(paths[n],wav))
  end
  for _,fixture in ipairs(ambix_fixtures)do
    local n=#fixture.samples;local frame={}
    for c,value in ipairs(fixture.samples)do frame[c]=string.pack('<i2',value)end
    local pcm=string.rep(table.concat(frame),48000*3)
    fixture.path=dir..'/'..fixture.name..'.wav'
    local wav='RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,n,48000,48000*n*2,n*2,16)..'data'..string.pack('<I4',#pcm)..pcm
    assert(U.write(fixture.path,wav))
  end
  -- Eight explicit pins let the probe observe every source channel before the
  -- project Master, whose routing and volume remain untouched by the feature.
  local probe={'desc:Audition Macro channel probe','options:gmem=AM_CHANNEL_PROBE'}
  for c=1,8 do probe[#probe+1]='in_pin:Channel '..c end
  for c=1,8 do probe[#probe+1]='out_pin:Channel '..c end
  probe[#probe+1]='@init\nepoch=-1;ext_nodenorm=1;\n@block\nepoch!=gmem[0]?(epoch=gmem[0];i=0;loop(8,gmem[16+i]=0;gmem[32+i]=0;i+=1;);gmem[2]=0;gmem[3]=0;);gmem[1]=num_ch;gmem[2]+=1;\n@sample\ngmem[3]+=1;i=0;loop(8,gmem[16+i]=max(gmem[16+i],abs(spl(i)));gmem[32+i]=spl(i);i+=1;);'
  assert(U.write(host..'/Effects/am_channel_probe',table.concat(probe,'\n')))
  local project=r.EnumProjects(-1)
  r.InsertTrackAtIndex(r.CountTracks(project),false);track=r.GetTrack(project,r.CountTracks(project)-1)
  r.SetMediaTrackInfo_Value(track,'I_PERFFLAGS',3)
  local settings=Model.defaults().settings;settings.loop=true;settings.preview_fade_ms=0
  for _,n in ipairs(channels)do
    for _,mix in ipairs{false,true}do
      settings.preview_downmix=mix;r.SetMediaTrackInfo_Value(track,'I_NCHAN',mix and 2 or math.max(2,2*math.ceil(n/2)))
      local preview=Preview.new(r,project,track)
      for _,transformed in ipairs{false,true}do
        local macro=Model.macro('channels','Channels')
        if transformed then macro.source_transform={reverse=true,pitch_semitones=7,rate=.5,preserve_pitch=true}end
        assert(preview:start(paths[n],macro,0,settings,transformed and {.2,.8}or nil))
        assert(preview:playing()and select(2,preview:get('I_SOURCECHANNELS'))==n)
        assert(select(2,preview:get('I_CHANNELS'))==(mix and 2 or math.max(2,n)))
        preview:stop(true)
      end
    end
  end
  r.DeleteTrack(track);track=nil
  check('Real decoders: 1/2/3/4/6/8ch, Downmix ON/OFF, Raw and Reverse/Pitch/Rate/range')
  local data=host..'/channel-app';App.initialize(r,root,data)
  local definition=Model.defaults();definition.settings.autoplay=true;definition.settings.loop=true;definition.settings.monitor_gain_db=0
  for _,m in ipairs(definition.macros)do m.normalization.enabled=false;m.source_peak_guard.enabled=false end
  assert(Model.save(data..'/bank.json',definition))
  r.OpenMediaExplorer(paths[1],false)
end,debug.traceback)
if not ok then finish(false,err);return end

local explorer=Explorer.new(r);local stage,index,deadline='init',1,r.time_precise()+10
local original_fader,master_channels,epoch,due=0,0,0,0
local probe_send
local sized=false
local measuring=false
local measure_start_blocks=0
local transformed_range_reader
local wide_macro,wide_guid
local ambix_index=0
local select_ambix
local input_index=1
local input_cases={{5,2},{2,5},{4,4},{6,3,transformed=true}}
local function snapshot(label)
  report.transitions[#report.transitions+1]={label=label,playing=app.preview:playing(),starts=app.preview.starts,
    paused=app.paused_source,position=app.preview:source_position(),downmix=app.definition.settings.preview_downmix,
    message=app.message,diagnostics=J.decode(r.AM_Preview_Diagnostics())}
end
local function select_file()
  local path=paths[channels[index]]
  r.OpenMediaExplorer(path,false)
  -- Launch now keeps the already-selected first fixture stopped.
  if path==app.path then app:play()end
  stage='selected';deadline=r.time_precise()+10
end
local function measure(next_stage)
  local width=app.bank.channels
  r.SetTrackSendInfo_Value(app.bank.raw,0,probe_send,'I_SRCCHAN',width==2 and 0 or (width//2)<<10)
  -- Exclude decoder resampler startup overshoot from steady-state DC levels.
  measuring=false;due=r.time_precise()+.15;stage=next_stage;deadline=r.time_precise()+5
end
local function measured(now)
  if now<due then return false end
  if not measuring then
    epoch=epoch+1;r.gmem_write(0,epoch);measuring=true;due=now+.15
    measure_start_blocks=J.decode(r.AM_Preview_Diagnostics()).blocks or 0
    return false
  end
  return r.gmem_read(2)>=4
end
local function advance()
  if transformed_range_reader then
    app.preview:stop(true)
    app:set_downmix(false)
    app.transform_override=nil;app.reverse_override=nil;app.effective_macro=nil
    app:reflect_transform(app:effective().source_transform)
    app.explorer.preview_range=transformed_range_reader;transformed_range_reader=nil
  end
  index=index+1
  if index<=#channels then select_file();return end
  select_ambix();return
end
local function finish_suite()
  app:close();r.DeleteTrack(track);track=nil;assert(r.CountTracks(0)==0)
  assert(r.JS_WindowMessage_Send(explorer:control(1045),'0x0400',0,0,0,0)==original_fader)
  local saved=assert(Model.load(host..'/channel-app/bank.json'));assert(saved.settings.preview_downmix==false and saved.settings.preview_downmix_mode=='auto')
  check('Mono/stereo regressions, persisted preference, unchanged Master, restored fader and no leaked tracks')
  stage='done';finish(true)
end
select_ambix=function()
  app.preview:stop(true)
  assert(app:set_downmix_mode('auto'))
  ambix_index=ambix_index+1
  if ambix_index>#ambix_fixtures then
    assert(app:set_downmix(false));r.OpenMediaExplorer(paths[6],false)
    stage='input_selected';deadline=r.time_precise()+10;return
  end
  assert(app:set_downmix(true))
  r.OpenMediaExplorer(ambix_fixtures[ambix_index].path,false)
  stage='ambix_selected';deadline=r.time_precise()+10
end
local function transform_audio()
  assert(not app.selected_id and not app.definition.settings.preview_downmix)
  transformed_range_reader=app.explorer.preview_range
  app.explorer.preview_range=function()return true,{.2,.8}end
  app.transform_override={pitch_semitones=7,rate=.5,preserve_pitch=true,reverse=true}
  app.reverse_override=nil;app.effective_macro=nil
  app:reflect_transform(app:effective().source_transform)
  app.preview:stop(true)
  assert(app:play(0,true))
  measure('transformed_off')
end
local function tick()
  local ok,err=xpcall(function()
    local now=r.time_precise();assert(now<deadline,'Timed out: '..stage)
    if stage=='init'then
      if not explorer:control(1045)or not explorer:control(1001)then return end
      if r.GetToggleCommandStateEx(32063,40008)==1 then explorer:command(40008);return end
      if not sized then
        assert(r.JS_Window_SetPosition(explorer:window(),120,120,1060,620));sized=true;return
      end
      original_fader=r.JS_WindowMessage_Send(explorer:control(1045),'0x0400',0,0,0,0)
      app=App.new(r,root,host..'/channel-app');app.bar=Bar.new(r,app)
      master_channels=r.GetMediaTrackInfo_Value(r.GetMasterTrack(0),'I_NCHAN')
      wide_macro=app.bank.macros[app.definition.macros[1].id]
      wide_guid=r.TrackFX_GetFXGUID(wide_macro,0)
      r.SetMediaTrackInfo_Value(wide_macro,'I_NCHAN',8)
      app.bank:set_channels(128);assert(r.GetMediaTrackInfo_Value(wide_macro,'I_NCHAN')==128)
      app.bank:set_channels(2);assert(r.GetMediaTrackInfo_Value(wide_macro,'I_NCHAN')==8)
      assert(r.TrackFX_GetFXGUID(wide_macro,0)==wide_guid)
      check('Real Macro routing: manual 8ch survives 128ch source expansion and stereo reduction without replacing FX')
      -- Keep the observer at eight channels throughout. JSFX spl variables
      -- beyond num_ch retain stale values when a track shrinks from 4 to 2;
      -- those variables are not audio outputs and must not be measured.
      r.InsertTrackAtIndex(r.CountTracks(0),false);track=r.GetTrack(0,r.CountTracks(0)-1)
      r.SetMediaTrackInfo_Value(track,'I_NCHAN',8)
      r.SetMediaTrackInfo_Value(track,'B_MAINSEND',1)
      r.SetMediaTrackInfo_Value(track,'I_PERFFLAGS',3)
      probe_send=r.CreateTrackSend(app.bank.raw,track)
      assert(probe_send>=0)
      r.SetTrackSendInfo_Value(app.bank.raw,0,probe_send,'I_SENDMODE',0)
      r.SetTrackSendInfo_Value(app.bank.raw,0,probe_send,'D_VOL',1)
      r.SetTrackSendInfo_Value(app.bank.raw,0,probe_send,'I_DSTCHAN',0)
      assert(r.TrackFX_AddByName(track,'JS: am_channel_probe',false,1)>=0,'Cannot load channel probe')
      r.gmem_attach('AM_CHANNEL_PROBE');r.Audio_Init();select_file();return
    end
    local n=channels[index]
    if stage=='selected'and not U.path_equal(app.explorer:selection(),paths[n])then return end
    app.last_poll=0;app:tick();app.bar:tick()
    assert(r.GetMediaTrackInfo_Value(r.GetMasterTrack(0),'I_NCHAN')==master_channels,'Preview changed the Master width')
    assert(r.GetMediaTrackInfo_Value(wide_macro,'I_NCHAN')>=8 and r.TrackFX_GetFXGUID(wide_macro,0)==wide_guid,
      'Downmix truncated Macro internal channels or replaced FX')
    if stage=='input_selected'then
      if not U.path_equal(app.path,paths[6])or not app.preview:playing()then return end
      assert(app:set_channel_selection(5,2));measure('input_audio')
      app.bar:dispatch('channels');assert(app.channel_panel_open and not app.editor_requested)
      app.bar:tick();assert(J.decode(r.AM_BarGeometry()).microphones_open)
      return
    end
    if stage=='input_audio'then
      if not measured(now)then return end
      local case=input_cases[input_index];local peaks=J.array{}
      assert(app.bank.channels==2 and not app.bank.fx_bypassed)
      assert(select(2,app.preview:get('I_SELECTED_LEFT'))==case[1]and select(2,app.preview:get('I_SELECTED_RIGHT'))==case[2])
      assert(app:analysis_spec().basis=='selected_channels')
      assert(app.bar:state().status:find(require('am.channel_selection').label({left=case[1],right=case[2]}),1,true))
      for channel=1,8 do
        local peak=r.gmem_read(15+channel);peaks[#peaks+1]=peak
        if case.transformed and channel<=2 then assert(U.finite(peak)and peak>1e-6)
        else
          local expected=channel<=2 and case[channel]*1000/32768 or 0
          assert(math.abs(peak-expected)<1e-5,('Selected input mismatch: output %d expected %f got %f'):format(channel,expected,peak))
        end
      end
      report.selected_audio[#report.selected_audio+1]={left=case[1],right=case[2],transformed=case.transformed or false,peaks=peaks}
      input_index=input_index+1
      local next_case=input_cases[input_index]
      if next_case then
        if next_case.transformed then
          app.transform_override={pitch_semitones=7,rate=.5,preserve_pitch=true,reverse=true}
          app.effective_macro=nil;app:reflect_transform(app:effective().source_transform)
        end
        local before=app.preview:source_position()
        assert(app:set_channel_selection(next_case[1],next_case[2]))
        assert(math.abs(app.preview:source_position()-before)<.08,'Selected inputs lost source position')
        measure('input_audio');return
      end
      local starts=app.preview.starts
      app:native_transport(1010);local paused=app.paused_source;assert(paused)
      assert(app:set_channel_selection(3));assert(not app.preview:playing()and app.preview.starts==starts and app.paused_source==paused)
      app:native_transport(1008);assert(app.preview:playing()and select(2,app.preview:get('I_SELECTED_LEFT'))==3)
      app.preview:stop(true);assert(app:set_channel_selection(5,2));assert(not app.preview:playing())
      app.bar:dispatch('channels:close');app.bar:tick()
      check('Selected inputs: nonadjacent pairs, swapped L/R, centered mono, live transforms, UI, pause/stop and source bookmarks')
      finish_suite();return
    end
    if stage=='ambix_selected'then
      local fixture=ambix_fixtures[ambix_index]
      local loaded,file=r.MediaExplorerGetLastPlayedFileInfo()
      if not loaded or not U.path_equal(file,fixture.path)or not U.path_equal(app.explorer:selection(),fixture.path)then return end
      assert(app.source_channels==#fixture.samples and app.preview:playing())
      assert(app.definition.settings.preview_downmix_mode=='auto')
      assert(select(2,app.preview:get('I_DOWNMIX_MODE'))==(fixture.auto_mode or 2),'Incorrect automatic AmbiX filename detection')
      measure('ambix_auto');return
    end
    if stage=='ambix_auto'or stage=='ambix_restored'or stage=='ambix_manual'or stage=='ambix_discrete'or stage=='ambix_auto_restored'then
      if not measured(now)then return end
      local fixture=ambix_fixtures[ambix_index];local count=#fixture.samples
      local mode=stage=='ambix_manual'and 2 or stage=='ambix_discrete'and 1 or fixture.auto_mode or 2
      local diagnostics=J.decode(r.AM_Preview_Diagnostics())
      assert(r.gmem_read(1)==8 and r.gmem_read(3)>0,'AmbiX observer received no audio frames')
      assert(app.preview:playing()and app.bank.channels==2 and r.GetMediaTrackInfo_Value(app.bank.raw,'I_NCHAN')==2)
      assert(select(2,app.preview:get('I_SOURCECHANNELS'))==count and select(2,app.preview:get('I_CHANNELS'))==2)
      assert(select(2,app.preview:get('I_DOWNMIX_MODE'))==mode)
      assert(diagnostics.active and diagnostics.downmix_mode==mode and diagnostics.blocks>measure_start_blocks and diagnostics.sample_rate>0,'No live AmbiX audio callbacks were measured')
      local peaks,signed_samples=J.array{},J.array{}
      for c=1,8 do
        local expected=0
        if c<=2 then
          if mode==2 then expected=(fixture.samples[1]+(c==1 and 1 or -1)*fixture.samples[2])/(2*32768)
          else
            local members=0
            for source=c,count,2 do expected=expected+fixture.samples[source]/32768;members=members+1 end
            expected=expected/members
          end
        end
        local peak,sample=r.gmem_read(15+c),r.gmem_read(31+c)
        peaks[#peaks+1]=peak;signed_samples[#signed_samples+1]=sample
        assert(U.finite(peak)and U.finite(sample))
        assert(math.abs(sample-expected)<1e-5,('Signed AmbiX mismatch %s mode=%d channel=%d expected=%f actual=%f'):format(fixture.name,mode,c,expected,sample))
        assert(math.abs(peak-math.abs(expected))<1e-5,('AmbiX peak mismatch %s mode=%d channel=%d expected=%f actual=%f'):format(fixture.name,mode,c,math.abs(expected),peak))
      end
      report.ambix_audio[#report.ambix_audio+1]={fixture=fixture.name,source_channels=count,setting=app.definition.settings.preview_downmix_mode,
        downmix_mode=mode,stage=stage,peaks=peaks,signed_samples=signed_samples,measurement_blocks=diagnostics.blocks-measure_start_blocks,probe_blocks=r.gmem_read(2)}
      if stage=='ambix_auto'and fixture.roundtrip then
        local before=app.preview:source_position();assert(app:set_downmix(false))
        assert(app.preview:playing()and app.bank.channels==10 and select(2,app.preview:get('I_SOURCECHANNELS'))==9)
        assert(select(2,app.preview:get('I_CHANNELS'))==9 and select(2,app.preview:get('I_DOWNMIX_MODE'))==0)
        assert(math.abs(app.preview:source_position()-before)<.08,'AmbiX OFF lost source position')
        before=app.preview:source_position();assert(app:set_downmix(true))
        assert(math.abs(app.preview:source_position()-before)<.08,'AmbiX ON lost source position')
        measure('ambix_restored');return
      end
      if stage=='ambix_auto'and fixture.overrides then
        assert(app:set_downmix_mode('ambix'));measure('ambix_manual');return
      elseif stage=='ambix_manual'then
        assert(app:set_downmix_mode('discrete'));measure('ambix_discrete');return
      elseif stage=='ambix_discrete'then
        assert(app:set_downmix_mode('auto'));measure('ambix_auto_restored');return
      end
      check(fixture.name..': real signed stereo output matches '..(mode==2 and '0.5(W + Y), 0.5(W - Y)'or 'discrete parity averages')..' with live callbacks')
      select_ambix();return
    end
    if stage=='selected'then
      local loaded,file=r.MediaExplorerGetLastPlayedFileInfo()
      if not loaded or not U.path_equal(file,paths[n])then return end
      assert(app.source_channels==n and app.preview:playing())
      assert(J.decode(r.AM_BarGeometry()).downmix_visible==(n>2),'Downmix visibility did not follow source: '..r.AM_BarGeometry())
      assert(not app.definition.settings.preview_downmix)
      measure('off');return
    end
    if stage=='off'or stage=='on'then
      if not measured(now)then return end
      assert(r.gmem_read(1)==8,'Observer did not receive eight valid channels')
      local mixed=stage=='on';local peaks=J.array{}
      local width=mixed and 2 or math.max(2,2*math.ceil(n/2))
      assert(app.bank.channels==width and r.GetMediaTrackInfo_Value(app.bank.raw,'I_NCHAN')==width)
      for c=1,8 do
        local expected=c<=n and c*1000/32768 or 0
        if n==1 and c==2 then expected=1000/32768 end
        if mixed then
          expected=0
          if c<=2 then local count=0;for source=c,n,2 do expected=expected+source*1000/32768;count=count+1 end;expected=expected/count end
        end
        local peak=r.gmem_read(15+c);peaks[#peaks+1]=peak
        assert(math.abs(peak-expected)<1e-5,('Audio mismatch %dch mix=%s channel=%d expected=%f actual=%f'):format(n,tostring(mixed),c,expected,peak))
      end
      report.audio[#report.audio+1]={source_channels=n,downmix=mixed,track_channels=width,peaks=peaks}
      if not mixed and n>2 then
        snapshot('before downmix');local before=app.preview:source_position();app.bar:dispatch('downmix');snapshot('after dispatch');app.bar:tick();snapshot('after bar tick')
        local after=app.preview:source_position();assert(math.abs(after-before)<.08,'Downmix lost source position')
        assert(J.decode(r.AM_BarGeometry()).downmix)
        measure('on');return
      end
      if mixed then
        local starts=app.preview.starts
        assert(app.preview:playing(),'Preview ended before Pause')
        app:native_transport(1010);local paused=app.paused_source;snapshot('paused')
        assert(not app.preview:playing()and paused~=nil,'Pause did not stop and bookmark the source')
        app.bar:dispatch('downmix')
        snapshot('paused toggle')
        assert(not app.preview:playing(),'Paused Downmix toggle started playback')
        assert(app.preview.starts==starts,'Paused Downmix toggle created a preview')
        assert(app.paused_source==paused,('Paused Downmix bookmark changed: %s -> %s'):format(tostring(paused),tostring(app.paused_source)))
        app:native_transport(1008);assert(app.preview:playing()and select(2,app.preview:get('I_CHANNELS'))==n)
        for _,command in ipairs{'play','replay'}do
          r.SetExtState(App.EXT,'queue',command,false);app:tick()
          if command=='play'then assert(not app.preview:playing())else assert(app.preview:playing())end
        end
        local read_range=app.explorer.preview_range;app.explorer.preview_range=function()return true,{.2,.8}end
        app:tick();app.explorer.preview_range=read_range
        assert(app.preview:playing()and app.range[1]==.2,'Range selection failed on multichannel')
        -- Multichannel Normalize queues the selected reference and uses unity
        -- until its background measurement is available.
        app:set_normalization(true,-18)
        local spec=app:analysis_spec()
        assert(spec.basis=='loudest_channel' and spec.source_channels==n)
        assert(require('am.analysis_policy').same(app.loudness.wanted_analysis,spec))
        assert(app:gain()==0,'Unmeasured source received a guessed Normalize gain')
        app:set_normalization(false,-18)
        check(n..'ch: all channels preserved, stereo averages verified, same-position toggle, pause, actions, range and native UI')
      end
      if n==3 or n==8 then transform_audio()else advance()end
      return
    end
    if stage=='transformed_off'or stage=='transformed_on'then
      if not measured(now)then return end
      assert(r.gmem_read(1)==8,'Observer did not receive eight valid channels')
      local mixed=stage=='transformed_on';local peaks=J.array{}
      local output=mixed and 2 or n;local width=math.max(2,2*math.ceil(output/2))
      local diagnostics=J.decode(r.AM_Preview_Diagnostics())
      assert(app.preview:playing()and not app.selected_id,'Transformed preview stopped or changed the Raw branch')
      assert(app.bank.channels==width and r.GetMediaTrackInfo_Value(app.bank.raw,'I_NCHAN')==width)
      assert(diagnostics.active and diagnostics.source_channels==n and diagnostics.output_channels==output)
      assert(diagnostics.downmix==mixed and diagnostics.blocks>measure_start_blocks and diagnostics.sample_rate>0,
        'No live transformed audio callbacks were measured')
      assert(select(2,app.preview:get('D_PITCH'))==7 and select(2,app.preview:get('D_PLAYRATE'))==.5)
      assert(app.preview.macro.source_transform.reverse and select(2,app.preview:get('B_PPITCH'))==1)
      for c=1,8 do
        local peak=r.gmem_read(15+c);peaks[#peaks+1]=peak
        assert(U.finite(peak),('Non-finite transformed audio %dch mix=%s channel=%d'):format(n,tostring(mixed),c))
        if c<=output then
          assert(peak>1e-6,('Silent transformed audio %dch mix=%s channel=%d'):format(n,tostring(mixed),c))
        else
          assert(peak==0,('Unexpected transformed audio %dch mix=%s channel=%d'):format(n,tostring(mixed),c))
        end
      end
      -- The real pitch engine's outputs are only checked for finite signal on
      -- every intended channel. This does not compare pitch/audio quality.
      report.transformed_audio[#report.transformed_audio+1]={source_channels=n,downmix=mixed,
        track_channels=width,peaks=peaks,measurement_blocks=diagnostics.blocks-measure_start_blocks,
        probe_blocks=r.gmem_read(2),diagnostics=diagnostics}
      if not mixed then app:set_downmix(true);measure('transformed_on');return end
      check(n..'ch: live Reverse/Pitch/Rate/range callbacks produced finite nonzero audio on every intended channel, Downmix ON/OFF')
      advance()
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif stage~='done'then r.defer(tick)end
end
r.defer(tick)
