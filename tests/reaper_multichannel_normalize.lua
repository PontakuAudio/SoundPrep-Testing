-- Real worker -> App gain/Preview callbacks -> frozen D&D -> rendered audio.
-- Only selection/waveform UI and native drag payloads are injected.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local C=require('am.chunk')
local App=require('am.app');local Bank=require('am.bank');local Preview=require('am.preview')
local L=require('am.loudness');local A=require('am.analysis_policy');local Model=require('am.model')
local Explorer=require('am.media_explorer');local EXT=require('am.drop').EXT
local report={status='RUNNING',checks=J.array{},cases=J.array{},host_version=r.GetAppVersion()}
local saved={context=r.AM_DropContext,result=r.AM_DropResult,explorer=Explorer.new,exec=r.ExecProcess}
local app,observer,send,macro_track,macro_guid,context,acknowledged
local destination_tracks={};local data=host..'/multichannel-normalize-data'
local fixture_dir=host..'/normalization-fixtures'
local sequence,epoch=0,0
local cases,index,stage,due,deadline,measurement,expected,gain,reference,blocks_before
local function check(text)
  report.checks[#report.checks+1]=text
  assert(U.write(host..'/multichannel-normalize-progress.json',J.encode(report)))
end
local function finish(ok,err)
  r.AM_DropContext,r.AM_DropResult,Explorer.new,r.ExecProcess=saved.context,saved.result,saved.explorer,saved.exec
  if app then
    if app.preview then pcall(app.preview.stop,app.preview,true)end
    if app.loudness then pcall(app.loudness.close,app.loudness)end
    if app.bank then pcall(app.bank.close,app.bank)end
  end
  if observer and r.ValidatePtr2(0,observer,'MediaTrack*')then r.DeleteTrack(observer)end
  for _,track in ipairs(destination_tracks)do if r.ValidatePtr2(0,track,'MediaTrack*')then r.DeleteTrack(track)end end
  for _,key in ipairs{'state','prepared','captured','busy','preview_stop','message'}do r.DeleteExtState(EXT,key,false)end
  report.status=ok and 'PASS'or 'FAIL';report.error=err
  assert(U.write(host..'/multichannel-normalize.json',J.encode(report)))
end
local function fixture(name,amplitudes)
  local n=#amplitudes;local frames={}
  for frame=0,96000-1 do
    local phase=math.sin(2*math.pi*440*frame/48000);local values={}
    for ch,amplitude in ipairs(amplitudes)do values[ch]=string.pack('<i2',math.floor(amplitude*phase+.5))end
    frames[#frames+1]=table.concat(values)
  end
  local pcm=table.concat(frames);local path=fixture_dir..'/'..name..'.wav'
  local header='RIFF'..string.pack('<I4',36+#pcm)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,n,48000,48000*n*2,n*2,16)
    ..'data'..string.pack('<I4',#pcm)
  assert(U.write(path,header..pcm));return {path=path,amplitudes=amplitudes}
end
local function wanted(case,source_gain)
  local values={};local amplitudes=case.fixture.amplitudes
  if case.mode==0 then for ch,value in ipairs(amplitudes)do values[ch]=value/32768 end
  elseif case.mode==2 then values={(amplitudes[1]+amplitudes[2])/65536,(amplitudes[1]-amplitudes[2])/65536}
  else
    for ch=1,2 do local sum,members=0,0
      for n=ch,#amplitudes,2 do sum=sum+amplitudes[n];members=members+1 end
      values[ch]=sum/(members*32768)
    end
  end
  local scale=U.gain(source_gain+3)*(case.mode==0 and 1 or .5)
  for ch,value in ipairs(values)do values[ch]=value*scale end
  return values
end
local function verify_audio(peaks,correlations,wanted_values,ref,label)
  local tolerance=math.max(.0008,math.abs(wanted_values[ref])*.008)
  for ch=1,#peaks do
    local value=wanted_values[ch]or 0
    assert(U.finite(peaks[ch])and math.abs(peaks[ch]-math.abs(value))<=tolerance,
      ('%s ch%d expected peak %.8f, got %.8f'):format(label,ch,math.abs(value),peaks[ch]))
    if math.abs(value)>tolerance and math.abs(wanted_values[ref])>tolerance then
      assert(correlations[ch]*value*wanted_values[ref]>0,('%s ch%d has the wrong polarity'):format(label,ch))
    end
  end
end
local function rendered_audio(take,count,ref,track)
  local source=r.GetMediaItemTake_Source(take)
  assert(r.GetMediaSourceNumChannels(source)==count,'Rendered audio has the wrong channel count')
  local accessor=assert(track and r.CreateTrackAudioAccessor(track)or r.CreateTakeAudioAccessor(take));local buffer=r.new_array(count*4800)
  local result=r.GetAudioAccessorSamples(accessor,48000,count,.5,4800,buffer)
  r.DestroyAudioAccessor(accessor);assert(result==1,'Rendered audio accessor returned no samples')
  local values=buffer.table();local peaks,correlations={},{}
  for ch=1,count do peaks[ch]=0;correlations[ch]=0 end
  for frame=0,4799 do
    local reference_sample=values[frame*count+ref]
    for ch=1,count do local value=values[frame*count+ch]
      peaks[ch]=math.max(peaks[ch],math.abs(value));correlations[ch]=correlations[ch]+reference_sample*value
    end
  end
  return peaks,correlations,r.GetMediaSourceFileName(source,'')
end
local function process(phase)
  context.phase=phase;acknowledged=nil
  r.AM_DropContext=function()return J.encode(context)end
  r.AM_DropResult=function(value)acknowledged=value end
  dofile(root..'/internal/Process waveform drop.lua')
  assert(acknowledged,r.GetExtState(EXT,'message'))
end
local function drop(case,record)
  app.preview:stop(true);sequence=sequence+1
  local state={project=tostring(app.project),session=app.session,path=app.path,identity=U.copy(app.identity),
    macro=U.copy(app:effective()),settings=U.copy(app.definition.settings),data=data,
    input=r.GetTrackGUID(app.bank.input),track=r.GetTrackGUID(macro_track),pdc_options=app.bank.pdc_options[macro_track],
    analyzer_key=app.loudness.analyzer_key,measurement=U.copy(measurement),defer_items=true}
  r.SetExtState(EXT,'state',J.encode(state),false)
  context={id=sequence,origin='list',path=app.path,paths=J.array{app.path},items=J.array{}}
  local before=r.CountMediaItems(app.project);process('capture')
  assert(r.CountMediaItems(app.project)==before,'Drop capture inserted an item')
  local captured=J.decode(r.GetExtState(EXT,'captured'));local snapshot=captured.entries[1].snapshot
  assert(A.same(snapshot.analysis,measurement.analysis)and math.abs(snapshot.source_gain_db-gain)<1e-8,
    'D&D did not freeze the real worker measurement gain')
  assert(snapshot.macro.normalization.metric==(case.metric or 'lufs_m_max'),'D&D changed the selected loudness meter')
  assert(snapshot.channel_mix.mode==case.mode and snapshot.channel_mix.output_channels==#expected)
  assert(snapshot.source_processing.fx_bypassed==(case.mode==0))
  assert((snapshot.chain:find('am_norm_half',1,true)~=nil)==(case.mode~=0),'Frozen Macro FX bypass differs from preview')
  process('prepare_captured')
  r.InsertTrackAtIndex(r.CountTracks(app.project),false)
  local target=r.GetTrack(app.project,r.CountTracks(app.project)-1);destination_tracks[#destination_tracks+1]=target
  r.SetMediaTrackInfo_Value(target,'B_MAINSEND',0);r.SetMediaTrackInfo_Value(target,'D_PANLAW',1)
  r.Undo_BeginBlock2(app.project)
  local item=r.AddMediaItemToTrack(target);local take=r.AddTakeToMediaItem(item)
  assert(r.SetMediaItemTake_Source(take,assert(r.PCM_Source_CreateFromFile(app.path))))
  r.SetMediaItemInfo_Value(item,'D_LENGTH',2)
  r.SetMediaItemInfo_Value(item,'D_FADEINLEN',0);r.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',0)
  context.items=J.array{select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))}
  process('finish');r.Undo_EndBlock2(app.project,'Normalized multichannel test drop',-1)
  local item_gain=require('am.insert').item_volume(snapshot)
  assert(r.CountTakes(item)==(item_gain and 1 or 2),'Normalized drop used the wrong gain/render path')
  local original=r.GetTake(item,0);local rendered=item_gain and original or r.GetTake(item,1)
  assert(math.abs(r.GetMediaItemTakeInfo_Value(original,'D_VOL')-(item_gain and 1 or U.gain(gain)))<1e-8,'Source take lost normalization gain')
  assert(math.abs(r.GetMediaItemInfo_Value(item,'D_VOL')-(item_gain or 1))<1e-8,'Item Volume does not match frozen gain')
  local source=r.GetMediaItemTake_Source(original)
  assert(r.GetMediaSourceNumChannels(source)==#case.fixture.amplitudes and U.path_equal(r.GetMediaSourceFileName(source,''),app.path),
    'Source take lost the original multichannel media')
  local item_chain=C.block(C.read_item(r,item),'TAKEFX')or ''
  assert((item_chain:find('am_norm_half',1,true)~=nil)==(case.mode~=0),'Source take uses the wrong Macro FX bypass')
  local peaks,correlations,path=rendered_audio(rendered,#expected,reference,item_gain and target)
  verify_audio(peaks,correlations,expected,reference,case.name..' rendered')
  record.rendered_peaks=peaks;record.rendered_correlations=correlations;record.rendered_path=path
  record.source_take_gain=r.GetMediaItemTakeInfo_Value(original,'D_VOL')
  record.item_volume=r.GetMediaItemInfo_Value(item,'D_VOL');record.rendered=item_gain==nil
  record.frozen_analysis=snapshot.analysis;record.fx_bypassed=snapshot.source_processing.fx_bypassed
  process('discard')
end
local function select_case()
  index=index+1
  if index>#cases then
    assert(r.TrackFX_GetFXGUID(macro_track,0)==macro_guid and r.TrackFX_GetCount(macro_track)==1,'Macro instance was lost')
    check('Actual worker cache, native preview, normalized D&D and retained Macro instance passed every case')
    finish(true);return false
  end
  local case=cases[index];app.preview:stop(true)
  app.definition.settings.preview_downmix=case.mode~=0
  app.definition.settings.preview_downmix_mode=case.mode==1 and 'discrete'or 'auto'
  app.definition.macros[1].source_peak_guard.ceiling_dbtp=case.silent_w and -12 or -3
  app.definition.macros[1].normalization.metric=case.metric or 'lufs_m_max'
  app.definition.settings.analysis_timeout_seconds=case.metric and 90 or 45
  app.effective_macro=nil;app.path=case.fixture.path;app.identity=assert(L.identity(r,app.path))
  app.source_channels=#case.fixture.amplitudes;app:configure_channels()
  case.counter_before=app.loudness.counter
  local found=app:measurement()
  assert((found~=nil)==(case.cached==true),'A different channel policy reused a stale measurement')
  app:request_analysis();stage='analysis';deadline=r.time_precise()+(case.metric and 110 or 65)
  check(case.name..': awaiting '..A.label(app:analysis_spec())..' measurement')
  return true
end
local ok,err=xpcall(function()
  require('am.native').require(r)
  r.ExecProcess=function()error('Native loudness analysis must not launch an external process')end
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  r.RecursiveCreateDirectory(fixture_dir,0);r.RecursiveCreateDirectory(data..'/chains',0)
  assert(U.write(host..'/Effects/am_norm_half','desc:Audition Macro normalization test half gain\nin_pin:Left\nin_pin:Right\nout_pin:Left\nout_pin:Right\n@sample\nspl0*=0.5;spl1*=0.5;\n'))
  local chain='BYPASS 0 0 0\n<JS am_norm_half "Test Macro half gain"\n>\nWAK 0 0\n'
  assert(U.write(data..'/chains/normalize.RfxChain',chain))
  local probe={'desc:Audition Macro normalization observer','options:gmem=AM_NORMALIZE_PROBE'}
  for ch=1,16 do probe[#probe+1]='in_pin:Channel '..ch end
  for ch=1,16 do probe[#probe+1]='out_pin:Channel '..ch end
  probe[#probe+1]='@init\nepoch=-1;ext_nodenorm=1;\n@block\nref=max(0,min(15,floor(gmem[4])-1));epoch!=gmem[0]?(epoch=gmem[0];i=0;loop(16,gmem[16+i]=0;gmem[48+i]=0;i+=1;);gmem[2]=0;gmem[3]=0;);gmem[1]=num_ch;gmem[2]+=1;\n@sample\ngmem[3]+=1;i=0;loop(16,gmem[16+i]=max(gmem[16+i],abs(spl(i)));gmem[48+i]+=spl(ref)*spl(i);i+=1;);'
  assert(U.write(host..'/Effects/am_normalize_probe',table.concat(probe,'\n')))
  local generic=fixture('generic6',{1000,1400,1800,2200,2600,3000})
  local ambix=fixture('field_ambix_9',{800,2000,2500,3000,1200,1600,2100,2700,3400})
  local silent=fixture('silent_W_ambix_4',{0,28000,0,0})
  cases={{name='generic OFF',fixture=generic,mode=0},{name='generic ON',fixture=generic,mode=1},
    {name='generic OFF cached',fixture=generic,mode=0,cached=true},
    {name='AmbiX OFF',fixture=ambix,mode=0},{name='AmbiX ON',fixture=ambix,mode=2},
    {name='silent W with directional peak',fixture=silent,mode=0,silent_w=true},
    {name='Zwicker Max generic OFF',fixture=generic,mode=0,metric='zwicker_max'},
    {name='Zwicker Max generic ON',fixture=generic,mode=1,metric='zwicker_max'},
    {name='Zwicker Max AmbiX OFF',fixture=ambix,mode=0,metric='zwicker_max'},
    {name='Zwicker Max AmbiX ON',fixture=ambix,mode=2,metric='zwicker_max'},
    {name='Zwicker P95 AmbiX ON',fixture=ambix,mode=2,metric='zwicker_p95'}}
  local definition=Model.defaults();local macro=Model.macro('normalize','Normalization test')
  macro.normalization.enabled=true;macro.normalization.target_lufs=-24;macro.source_peak_guard.enabled=true
  macro.output_gain_db=3;macro.export.tail_seconds=0
  definition.macros=J.array{macro};definition.slots={};definition.settings.monitor_gain_db=0
  definition.settings.keep_fx_running=true;definition.settings.loop=true
  definition.settings.preview_fade_ms=0;definition.settings.fade_ms=0;definition.settings.analysis_timeout_seconds=45
  definition.settings.auto_render_drops=true
  local project=r.EnumProjects(-1)
  app=setmetatable({r=r,root=root,data=data,project=project,definition=definition,selected_id='normalize',
    session='multichannel-normalize',message='',sync_transform=function()end,sync_range=function()return false end},App)
  app.explorer={selection=function()return app.path end,ensure_waveform=function()end}
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  app.bank=Bank.new(r,project,data,definition,app.session)
  app.preview=Preview.new(r,project,app.bank.input)
  app.loudness=L.new(r,root,data,definition.settings,app.session)
  assert(r.APIExists('AM_AnalysisStart')and r.APIExists('AM_AnalysisCancel'),'Native analysis APIs are required')
  assert(app.loudness.analyzer_key==L.ANALYZER_KEY and not app.loudness.python and not app.loudness.ffmpeg)
  report.analyzer_key=app.loudness.analyzer_key;report.external_analysis_process=false
  macro_track=app.bank.macros.normalize;macro_guid=r.TrackFX_GetFXGUID(macro_track,0)
  assert(r.TrackFX_GetCount(macro_track)==1 and macro_guid~='','Test Macro did not load')
  r.InsertTrackAtIndex(r.CountTracks(project),false);observer=r.GetTrack(project,r.CountTracks(project)-1)
  r.SetMediaTrackInfo_Value(observer,'I_NCHAN',16);r.SetMediaTrackInfo_Value(observer,'I_PERFFLAGS',3)
  r.SetMediaTrackInfo_Value(observer,'B_MAINSEND',1)
  assert(r.TrackFX_AddByName(observer,'JS: am_normalize_probe',false,1)>=0,'Cannot load audio observer')
  send=r.CreateTrackSend(macro_track,observer);assert(send>=0)
  r.SetTrackSendInfo_Value(macro_track,0,send,'I_SENDMODE',0);r.SetTrackSendInfo_Value(macro_track,0,send,'D_VOL',1)
  r.SetTrackSendInfo_Value(macro_track,0,send,'I_DSTCHAN',0)
  r.gmem_attach('AM_NORMALIZE_PROBE');r.Audio_Init();index=0;select_case()
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local continue=true
  local success,why=xpcall(function()
    local now=r.time_precise();assert(now<deadline,'Timed out: '..cases[index].name..' / '..stage)
    local case=cases[index]
    if stage=='analysis'then
      app.loudness:poll();assert(not app.loudness.error,app.loudness.error)
      measurement=app:measurement();if not measurement then return end
      local spec=app:analysis_spec();assert(A.same(spec,measurement.analysis))
      assert(measurement.channels==#case.fixture.amplitudes and measurement.profile==L.profile(spec))
      if case.metric then
        assert(spec.revision==2 and spec.meter.metric==case.metric and measurement.zwicker_sones>0 and
          U.finite(measurement.normalization_gain_db)and measurement.zwicker_tail_seconds==.4,
          'Zwicker result lost its selected summary, solved gain or response tail')
      else assert(spec.revision==1 and measurement.profile==L.MULTICHANNEL_PROFILE)end
      assert(app.loudness.counter==case.counter_before+(case.cached and 0 or 1),'Worker policy cache reuse was incorrect')
      gain=app:gain();assert(math.abs(gain)>.05,'Fixture did not exercise a nonzero source gain')
      if case.silent_w then
        assert(measurement.status=='silence'and U.finite(measurement.true_peak_dbtp)and gain<0,
          'Silent W failed to retain directional true-peak protection')
      else assert(measurement.status=='ready')end
      expected=wanted(case,gain);reference=1
      for ch,value in ipairs(expected)do if math.abs(value)>math.abs(expected[reference])then reference=ch end end
      assert(app:play(0,true))
      assert(math.abs(select(2,app.preview:get('D_VOLUME'))-U.gain(gain))<1e-10,'Native preview did not receive normalized source gain')
      assert(select(2,app.preview:get('I_DOWNMIX_MODE'))==case.mode)
      assert(app.bank.fx_bypassed==(case.mode==0)and r.GetMediaTrackInfo_Value(macro_track,'I_FXEN')==(case.mode==0 and 0 or 1),
        'Preview Macro bypass differs from Downmix policy')
      assert(r.TrackFX_GetFXGUID(macro_track,0)==macro_guid,'Changing mode replaced the Macro instance')
      local width=app.bank.channels
      r.SetTrackSendInfo_Value(macro_track,0,send,'I_SRCCHAN',width==2 and 0 or(width//2)<<10)
      due=now+.2;stage='settle';deadline=now+10
    elseif stage=='settle'and now>=due then
      epoch=epoch+1;r.gmem_write(4,reference);r.gmem_write(0,epoch)
      blocks_before=J.decode(r.AM_Preview_Diagnostics()).blocks or 0
      due=now+.25;stage='measure'
    elseif stage=='measure'and now>=due and r.gmem_read(2)>=4 then
      local diagnostic=J.decode(r.AM_Preview_Diagnostics())
      assert(app.preview:playing()and diagnostic.active and diagnostic.blocks>blocks_before and r.gmem_read(1)==16 and r.gmem_read(3)>0,
        'No active native audio callbacks reached the observer')
      local peaks,correlations=J.array{},J.array{}
      for ch=1,16 do peaks[ch]=r.gmem_read(15+ch);correlations[ch]=r.gmem_read(47+ch)end
      verify_audio(peaks,correlations,expected,reference,case.name..' preview')
      local record={name=case.name,path=app.path,mode=case.mode,metric=case.metric or 'lufs_m_max',analysis=U.copy(measurement.analysis),
        measurement=U.copy(measurement),gain_db=gain,expected=expected,preview_peaks=peaks,preview_correlations=correlations,
        cached=case.cached or false,worker_counter=app.loudness.counter,reference_channel=reference,
        preview_blocks=diagnostic.blocks-blocks_before,probe_blocks=r.gmem_read(2)}
      drop(case,record);report.cases[#report.cases+1]=record
      check(case.name..': worker reference, source gain, preview polarity/levels, FX policy and rendered audio match')
      continue=select_case()
    end
  end,debug.traceback)
  if not success then finish(false,why);return end
  if continue then r.defer(tick)end
end
r.defer(tick)
