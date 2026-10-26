-- Real REAPER rendering in a marked, muted host. The drop callback payload is
-- injected; capture, frozen recipes, insertion, Take FX and audio are real APIs.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local C=require('am.chunk')
local Model=require('am.model');local L=require('am.loudness');local T=require('am.take_fx')
local Analysis=require('am.analysis_policy')
local DropRender=require('am.drop_render');local Direct=require('am.render_item')
local Explorer=require('am.media_explorer');local EXT=require('am.drop').EXT
local report={status='RUNNING',checks=J.array{},cases=J.array{},host_version=r.GetAppVersion(),
  analysis_scope='Explicit matching-policy cache fixtures; worker analysis is tested separately.'}
local saved={context=r.AM_DropContext,result=r.AM_DropResult,transform=Explorer.transform,tempo=Explorer.tempo_factor}
local settings=Model.defaults().settings;settings.fade_ms=0;settings.auto_render_drops=true
local fixture_dir=host..'/multichannel-fixtures';local output_dir=host..'/source-fx-renders'
local function check(text)
  report.checks[#report.checks+1]=text
  assert(U.write(host..'/multichannel-drop-progress.json',J.encode(report)))
end
local function fixture(name,n)
  local frame={};for ch=1,n do frame[ch]=string.pack('<i2',100*ch)end
  local samples=table.concat(frame):rep(24000)
  local header='RIFF'..string.pack('<I4',36+#samples)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,n,48000,48000*n*2,n*2,16)
    ..'data'..string.pack('<I4',#samples)
  local path=fixture_dir..'/'..name..'.wav';assert(U.write(path,header..samples));return path
end
local function samples(take,count)
  local source=r.GetMediaItemTake_Source(take);local channels=r.GetMediaSourceNumChannels(source)
  if count then assert(channels==count,('Rendered channel count: expected %d, got %d'):format(count,channels))end
  local accessor=assert(r.CreateTakeAudioAccessor(take));local buffer=r.new_array(channels*16)
  local result=r.GetAudioAccessorSamples(accessor,48000,channels,.2,16,buffer)
  r.DestroyAudioAccessor(accessor);assert(result==1,'Rendered audio accessor returned no samples')
  local data=buffer.table();local measured={}
  for ch=1,channels do
    measured[ch]=data[ch]
    for frame=1,15 do assert(math.abs(data[frame*channels+ch]-data[ch])<1e-7,'DC fixture changed across samples')end
  end
  return measured,channels,r.GetMediaSourceFileName(source,'')
end
local function expected(n,mode,gain,selection)
  local result={};gain=10^(gain/20)
  if selection then result={100*selection.left/32768*gain,100*selection.right/32768*gain}
  elseif mode==0 then for ch=1,n do result[ch]=100*ch/32768*gain end
  elseif mode==2 then result={150/32768*gain,-50/32768*gain}
  else
    local left,right=0,0
    for ch=1,n do if ch%2==1 then left=left+100*ch else right=right+100*ch end end
    result={left/math.ceil(n/2)/32768*gain,right/math.floor(n/2)/32768*gain}
  end
  return result
end
local function close_samples(actual,wanted,extra_zero)
  assert(#actual>=#wanted,'Audio output lost channels')
  for ch,value in ipairs(wanted)do
    assert(math.abs(actual[ch]-value)<1e-5,('Channel %d: expected %.10f, got %.10f'):format(ch,value,actual[ch]))
  end
  if extra_zero then for ch=#wanted+1,#actual do assert(math.abs(actual[ch])<1e-7,'Unwanted output on channel '..ch)end end
end
local context,acknowledged
local function process(phase,want_success)
  context.phase=phase;acknowledged=nil
  r.AM_DropContext=function()return J.encode(context)end
  r.AM_DropResult=function(value)acknowledged=value end
  dofile(root..'/internal/Process waveform drop.lua')
  if want_success~=false then assert(acknowledged,r.GetExtState(EXT,'message'))
  else assert(acknowledged==false,'Invalid batch was accepted')end
end
local ok,err=xpcall(function()
  require('am.native').require(r)
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  r.RecursiveCreateDirectory(fixture_dir,0);r.RecursiveCreateDirectory(output_dir,0)
  local leak_js={'desc:Audition Macro test internal channel generator\n'}
  for ch=1,128 do leak_js[#leak_js+1]='in_pin:Input '..ch..'\n'end
  for ch=1,128 do leak_js[#leak_js+1]='out_pin:Output '..ch..'\n'end
  leak_js[#leak_js+1]='slider1:12<1,128,1>Channel\nslider2:0.125<-1,1,0.001>Value\n@sample\nspl(slider1-1)=slider2;\n'
  assert(U.write(host..'/Effects/am_test_channel_leak',table.concat(leak_js)))
  local section=r.SectionFromUniqueID(0);report.multichannel_action=r.kbd_getTextFromCmd(41993,section)
  assert(report.multichannel_action:find('multichannel',1,true),'Unexpected multichannel item action')
  -- Avoid depending on whichever transform a fresh Media Explorer remembers.
  -- This suite targets channel handling; transform controls have their own suite.
  Explorer.transform=function()return {}end;Explorer.tempo_factor=function()return 1 end
  r.InsertTrackAtIndex(0,false);local input=r.GetTrack(0,0)
  r.SetMediaTrackInfo_Value(input,'B_MAINSEND',0)
  local project=r.EnumProjects(-1);local sequence=0
  local cases={
    {name='select6_5_2',n=6,mode=3,selection={left=5,right=2}},
    {name='select6_2_5',n=6,mode=3,selection={left=2,right=5},fx_channels=12,macro_gain=-12},
    {name='select6_mono4',n=6,mode=3,selection={left=4,right=4},normalization_gain=6},
    {name='select2_mono2',n=2,mode=3,selection={left=2,right=2}},
    {name='select128',n=128,mode=3,selection={left=128,right=64}},
    {name='select_reverse_range',n=6,mode=3,selection={left=6,right=3},rate=.8,reverse=true,range={.2,.8},crop=true},
    {name='off3',n=3,mode=0},{name='off4',n=4,mode=0},{name='off6',n=6,mode=0},{name='off9',n=9,mode=0},
    {name='off128',n=128,mode=0},
    {name='discrete4',n=4,mode=1,preference='discrete'},
    {name='discrete6',n=6,mode=1,preference='discrete',fx_channels=12,macro_gain=-12},
    {name='auto_generic4',n=4,mode=1,preference='auto'},
    {name='auto_ambix_4',n=4,mode=2,preference='auto'},
    {name='auto_AMBIX_9',n=9,mode=2,preference='auto'},
    {name='manual9',n=9,mode=2,preference='ambix'},
    {name='gain6',n=6,mode=0,gain=6,normalization_gain=6},
    {name='gain_ambix_9',n=9,mode=2,preference='auto',gain=6,normalization_gain=6},
    {name='bypassed_macro6',n=6,mode=0,fx_channels=12,macro_gain=-12,gain=6},
    {name='leak_discrete6',n=6,mode=1,preference='discrete',fx_channels=6,leak_channel=4},
    {name='leak_off3',n=3,mode=0,fx_channels=12,leak_channel=12},
    {name='leak_off6',n=6,mode=0,fx_channels=12,leak_channel=12},
    {name='range_reverse6',n=6,mode=1,preference='discrete',rate=.8,reverse=true,range={.2,.8},crop=true},
    {name='range_rate3',n=3,mode=0,rate=1.25,range={.2,.8},crop=true},
  }
  for _,case in ipairs(cases)do
    sequence=sequence+1
    local path=fixture(case.name,case.n)
    local total_gain=(case.gain or 0)+(case.normalization_gain or 0)+(case.mode~=0 and case.macro_gain or 0)
    local wanted=expected(case.n,case.mode,total_gain,case.selection)
    local macro=Model.macro('channels','Channel preservation');macro.export.tail_seconds=0
    macro.output_gain_db=case.gain or 0
    macro.source_transform.rate=case.rate or 1;macro.source_transform.reverse=case.reverse or false
    macro.normalization.enabled=true;macro.source_peak_guard.enabled=true
    macro.normalization.target_lufs=-24+(case.normalization_gain or 0)
    settings.preview_downmix=case.mode~=0;settings.preview_downmix_mode=case.preference or 'auto'
    settings.channel_selections=case.selection and {[tostring(case.n)]=U.copy(case.selection)}or {}
    settings.insert_handles=not case.crop
    for fx=r.TrackFX_GetCount(input)-1,0,-1 do r.TrackFX_Delete(input,fx)end
    if case.leak_channel then
      local chain=('BYPASS 0 0 0\n<JS am_test_channel_leak "Generated internal channel"\n%d 0.125\n>\nWAK 0 0\n'):format(case.leak_channel)
      assert(r.SetTrackStateChunk(input,C.replace(C.read_track(r,input),C.fresh(chain,r.genGuid)),false))
      assert(select(2,r.TrackFX_GetIOSize(input,0))==128,'Test channel generator did not load')
    elseif case.fx_channels or case.selection then
      -- This suite exercises processed drops. Channel-only one-take drops
      -- have a separate real-host regression in reaper_selected_channels.lua.
      local fx=r.TrackFX_AddByName(input,'JS: utility/volume_pan',false,-1);assert(fx>=0,'Bundled unity FX missing')
      r.TrackFX_SetParam(input,fx,0,case.macro_gain or 0)
      -- Include an otherwise silent sidechain input so the captured FX routing
      -- really addresses channel 12, not only a wide track with an empty chain.
      if case.fx_channels then assert(r.TrackFX_SetPinMappings(input,fx,0,0,1|(1<<(case.fx_channels-1)),0))end
    end
    r.SetMediaTrackInfo_Value(input,'I_NCHAN',case.fx_channels or 2)
    local state={project=tostring(project),session='multichannel-drop',path=path,identity=assert(L.identity(r,path)),
      macro=macro,settings=U.copy(settings),data=host..'/multichannel-drop-data',input=r.GetTrackGUID(input),
      track=r.GetTrackGUID(input),defer_items=true,analyzer_key='integration-policy-fixture'}
    local analysis=assert(Analysis.resolve(path,case.n,state.settings))
    local measurement={status='ready',identity=U.copy(state.identity),profile=L.profile(analysis),
      analyzer_key=state.analyzer_key,analysis=U.copy(analysis),channels=case.n,duration=.5,
      max_momentary_lufs=-24,true_peak_dbtp=-18}
    r.RecursiveCreateDirectory(state.data..'/cache',0)
    assert(U.write(state.data..'/cache/'..L.key(state.identity,state.analyzer_key,analysis)..'.json',J.encode(measurement)))
    r.SetExtState(EXT,'state',J.encode(state),false)
    context={id=sequence,origin=case.range and'waveform'or'list',path=path,paths=J.array{path},items=J.array{}}
    if case.range then context.preview={path=path,mode=256,start=case.range[1],['end']=case.range[2]}end
    local before_items,before_tracks=r.CountMediaItems(project),r.CountTracks(project)
    process('capture')
    assert(r.CountMediaItems(project)==before_items and r.CountTracks(project)==before_tracks,'Capture modified the project')
    local captured=J.decode(r.GetExtState(EXT,'captured'));local snapshot=captured.entries[1].snapshot
    assert(snapshot.channel_mix.source_channels==case.n and snapshot.channel_mix.mode==case.mode)
    assert(snapshot.channel_mix.output_channels==#wanted)
    assert(snapshot.macro.normalization.enabled and snapshot.macro.source_peak_guard.enabled)
    assert(snapshot.source_gain_db==(case.normalization_gain or 0) and Analysis.same(snapshot.analysis,analysis))
    assert(snapshot.source_processing.fx_bypassed==(case.mode==0))
    if case.mode==0 then assert(snapshot.chain=='','OFF retained Macro FX')
    elseif case.macro_gain then assert(snapshot.chain:find('utility/volume_pan',1,true),'ON lost Macro FX')end
    assert(state.macro.normalization.enabled and state.macro.source_peak_guard.enabled,'Capture changed the live Macro')
    local fx_width=case.mode==0 and 2*math.ceil(case.n/2) or case.fx_channels or 2
    assert(snapshot.channel_mix.fx_channels==fx_width,'Capture used the wrong effective Macro width')
    -- The actual native drag may remain modal while the live state changes.
    state.settings.preview_downmix=not state.settings.preview_downmix;state.settings.preview_downmix_mode='discrete'
    state.settings.channel_selections={}
    state.macro.output_gain_db=-18;r.SetMediaTrackInfo_Value(input,'I_NCHAN',2)
    r.SetExtState(EXT,'state',J.encode(state),false)
    process('prepare_captured')
    local prepared=J.decode(r.GetExtState(EXT,'prepared'))
    assert(U.equal(prepared.entries[1].snapshot,snapshot),'Live settings replaced the captured recipe')
    r.InsertTrackAtIndex(r.CountTracks(project),false);local target=r.GetTrack(project,r.CountTracks(project)-1)
    r.SetMediaTrackInfo_Value(target,'B_MAINSEND',0);r.SetMediaTrackInfo_Value(target,'D_PANLAW',1)
    if case.fx_channels then r.SetMediaTrackInfo_Value(target,'I_NCHAN',case.fx_channels)end
    r.Undo_BeginBlock2(project)
    local item=r.AddMediaItemToTrack(target);local take=r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take,assert(r.PCM_Source_CreateFromFile(path)))
    r.SetMediaItemInfo_Value(item,'D_LENGTH',.5)
    r.SetMediaItemInfo_Value(item,'D_FADEINLEN',0);r.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',0)
    context.items=J.array{select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))}
    process('finish');r.Undo_EndBlock2(project,'Multichannel test drop',-1)
    local item_gain=require('am.insert').item_volume(snapshot)
    if item_gain then
      assert(r.CountTakes(item)==1 and r.TakeFX_GetCount(take)==0,'Gain-only drop rendered or added FX')
      assert(r.GetMediaItemTakeInfo_Value(take,'D_VOL')==1 and
        math.abs(r.GetMediaItemInfo_Value(item,'D_VOL')-item_gain)<1e-10,'Gain-only drop lost Item Volume')
      assert(U.path_equal(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),''),path),'Gain-only drop replaced original media')
      local accessor=assert(r.CreateTrackAudioAccessor(target));local buffer=r.new_array(case.n*16)
      assert(r.GetAudioAccessorSamples(accessor,48000,case.n,.2,16,buffer)==1);r.DestroyAudioAccessor(accessor)
      local actual={};for ch=1,case.n do actual[ch]=buffer[ch]end
      close_samples(actual,wanted)
      report.cases[#report.cases+1]={name=case.name,source_channels=case.n,mode=case.mode,
        item_volume=item_gain,expected=wanted,item_audio=actual,original_path=path}
      check(case.name..': original source and Item Volume match audition without rendering')
    else
    assert(r.CountTakes(item)==2 and r.GetActiveTake(item)==r.GetTake(item,1),'Drop did not create Source + FX / Rendered')
    local source_take=r.GetTake(item,0);local rendered_take=r.GetTake(item,1)
    local duration=(case.range and(case.range[2]-case.range[1])or 1)*.5/(case.rate or 1)
    assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-duration)<1e-8,'Dropped transform/range duration changed')
    assert(math.abs(r.GetMediaItemTakeInfo_Value(source_take,'D_PLAYRATE')-(case.rate or 1))<1e-8,'Source take rate changed')
    if case.range then
      local offset=(case.reverse and 1-case.range[2]or case.range[1])*.5
      assert(math.abs(r.GetMediaItemTakeInfo_Value(source_take,'D_STARTOFFS')-offset)<1e-8,'Source range alignment changed')
      assert(math.abs(r.GetMediaSourceLength(r.GetMediaItemTake_Source(rendered_take))-duration)<1/48000,'Cropped render length changed')
    end
    local original=r.GetMediaItemTake_Source(source_take)
    while r.GetMediaSourceParent(original)do original=r.GetMediaSourceParent(original)end
    assert(U.path_equal(r.GetMediaSourceFileName(original,''),path) and r.GetMediaSourceNumChannels(original)==case.n,
      'Source + FX lost the original multichannel file')
    local take_width=r.GetMediaItemTakeInfo_Value(source_take,'I_TAKEFX_NCH')
    if r.TakeFX_GetCount(source_take)>0 then
      assert(take_width>=require('am.render_channels').width(snapshot),'Editable Take FX lost source or active Macro channels')
    end
    assert(r.TakeFX_GetCount(rendered_take)==0,'Rendered take contains live FX')
    local rendered,rendered_channels,rendered_path=samples(rendered_take,#wanted);close_samples(rendered,wanted)
    local plan=J.decode(select(2,r.GetSetMediaItemTakeInfo_String(source_take,'P_EXT:AuditionMacro','',false)))
    local stored=J.decode(assert(U.read(plan.snapshot)))
    assert(U.equal(stored.channel_mix,snapshot.channel_mix),'Stored recipe changed the frozen channel mapping')
    assert(Analysis.same(stored.analysis,analysis) and stored.source_gain_db==(case.normalization_gain or 0),
      'Stored recipe changed the normalization basis or common gain')
    -- Bake the actual restored editable take, not a reconstructed test chain.
    -- Take accessors read pre-FX data, so apply-FX is required to inspect audio.
    r.SetActiveTake(source_take);T.restore(r,source_take)
    r.SelectAllMediaItems(project,false);r.SetMediaItemSelected(item,true)
    r.GetSetProjectInfo_String(project,'RECORD_PATH',output_dir,true)
    r.GetSetProjectInfo_String(project,'RECORD_PATH_SECONDARY','',true)
    r.GetSetProjectInfo_String(project,'OPENCOPY_CFGIDX','1',true)
    r.GetSetProjectInfo_String(project,'APPLYFX_FORMAT','evaw',true)
    r.SNM_SetIntConfigVar('applyfxtail',0);r.SNM_SetIntConfigVar('itemfxtail',0);r.SNM_SetIntConfigVar('showpeaksbuild',0)
    r.Main_OnCommandEx(41993,0,project)
    assert(r.CountTakes(item)==3,'Could not bake the editable Source + FX')
    local editable,editable_channels,editable_path=samples(r.GetActiveTake(item));close_samples(editable,wanted,true)
    if case.leak_channel then
      assert(editable_channels>=case.leak_channel,'Destination was too narrow to observe the generated internal channel')
    end
    report.cases[#report.cases+1]={name=case.name,source_channels=case.n,mode=case.mode,
      output_channels=rendered_channels,source_fx_render_channels=editable_channels,take_fx_channels=take_width,
      frozen_fx_channels=snapshot.channel_mix.fx_channels,gain_db=case.gain or 0,
      normalization_gain_db=case.normalization_gain or 0,analysis=analysis,fx_bypassed=case.mode==0,
      generated_internal_channel=case.leak_channel,rate=case.rate or 1,reverse=case.reverse or false,range=case.range,
      expected=wanted,rendered=rendered,source_fx=editable,rendered_path=rendered_path,source_fx_path=editable_path}
    check(case.name..': exact rendered width, source file retained, frozen settings and Source + FX audio match')
    end
    process('discard')
  end
  -- The user can edit a pending Source + FX chain. Reconstructing its render
  -- recipe must keep those edits without prepending another mix or gain stage.
  sequence=sequence+1
  local edited_path=fixture('edited_ambix_9',9)
  local edited_macro=Model.macro('edited','Edited source');edited_macro.export.tail_seconds=0;edited_macro.output_gain_db=6
  settings.preview_downmix=true;settings.preview_downmix_mode='auto';settings.auto_render_drops=false;settings.insert_handles=true
  for fx=r.TrackFX_GetCount(input)-1,0,-1 do r.TrackFX_Delete(input,fx)end
  r.SetMediaTrackInfo_Value(input,'I_NCHAN',2)
  local edited_state={project=tostring(project),session='multichannel-drop',path=edited_path,identity=L.identity(r,edited_path),
    macro=edited_macro,settings=U.copy(settings),data=host..'/multichannel-drop-data',input=r.GetTrackGUID(input),
    track=r.GetTrackGUID(input),defer_items=true}
  r.SetExtState(EXT,'state',J.encode(edited_state),false)
  context={id=sequence,origin='list',path=edited_path,paths=J.array{edited_path},items=J.array{}}
  process('capture');process('prepare_captured')
  r.InsertTrackAtIndex(r.CountTracks(project),false);local edited_track=r.GetTrack(project,r.CountTracks(project)-1)
  r.SetMediaTrackInfo_Value(edited_track,'B_MAINSEND',0);r.SetMediaTrackInfo_Value(edited_track,'D_PANLAW',1)
  local edited_item=r.AddMediaItemToTrack(edited_track);local edited_take=r.AddTakeToMediaItem(edited_item)
  r.SetMediaItemTake_Source(edited_take,assert(r.PCM_Source_CreateFromFile(edited_path)))
  r.SetMediaItemInfo_Value(edited_item,'D_LENGTH',.5)
  r.SetMediaItemInfo_Value(edited_item,'D_FADEINLEN',0);r.SetMediaItemInfo_Value(edited_item,'D_FADEOUTLEN',0)
  context.items=J.array{select(2,r.GetSetMediaItemInfo_String(edited_item,'GUID','',false))}
  process('finish');assert(r.CountTakes(edited_item)==1,'Explicitly deferred drop rendered early')
  edited_take=r.GetTake(edited_item,0)
  local edited_plan=J.decode(select(2,r.GetSetMediaItemTakeInfo_String(edited_take,'P_EXT:AuditionMacro','',false)))
  assert(edited_plan.pending and r.TakeFX_GetCount(edited_take)==2,'Pending source chain has unexpected stages')
  assert(r.TakeFX_GetParam(edited_take,0,0)==2,'Initial editable mix is not AmbiX')
  assert(r.TakeFX_SetParam(edited_take,0,0,1)) -- User changes AmbiX to discrete in the source chain.
  assert(r.TakeFX_SetParam(edited_take,1,2,-3)) -- User changes post-FX gain from +6 to -3 dB.
  local edited_snapshot=DropRender.recipe(r,edited_item,edited_plan)
  assert(edited_snapshot.channel_mix.chain_applied and edited_snapshot.macro.output_gain_db==0,
    'Edited recipe will apply mix/output gain twice')
  local edited_render=Direct.render(r,edited_snapshot,output_dir,'edited-source-recipe')
  local reference_item=r.AddMediaItemToTrack(edited_track);local reference_take=r.AddTakeToMediaItem(reference_item)
  r.SetMediaItemTake_Source(reference_take,assert(r.PCM_Source_CreateFromFile(edited_render)))
  r.SetMediaItemInfo_Value(reference_item,'D_LENGTH',.5)
  r.SetMediaItemInfo_Value(reference_item,'D_FADEINLEN',0);r.SetMediaItemInfo_Value(reference_item,'D_FADEOUTLEN',0)
  local edited_wanted=expected(9,1,-3);local edited_result=samples(reference_take,2);close_samples(edited_result,edited_wanted)
  r.SelectAllMediaItems(project,false);r.SetMediaItemSelected(edited_item,true)
  r.GetSetProjectInfo_String(project,'RECORD_PATH',output_dir,true)
  r.Main_OnCommandEx(41993,0,project);assert(r.CountTakes(edited_item)==2)
  local edited_live=samples(r.GetActiveTake(edited_item));close_samples(edited_live,edited_wanted,true)
  report.edited_source={rendered=edited_result,source_fx=edited_live,expected=edited_wanted,path=edited_render,
    frozen_mode=edited_snapshot.channel_mix.mode,chain_applied=edited_snapshot.channel_mix.chain_applied}
  check('Edited pending Source + FX retains changed mix and gain; baking does not apply either stage twice')
  process('discard');settings.auto_render_drops=true
  -- The whole batch is validated before native insertion: the first valid file
  -- must not be inserted if a later file cannot use the selected AmbiX mode.
  local first=fixture('batch_ambix_4',4);local second=fixture('batch_invalid6',6)
  local macro=Model.macro('batch','Invalid batch');macro.export.tail_seconds=0
  settings.preview_downmix=true;settings.preview_downmix_mode='ambix'
  local state={project=tostring(project),session='multichannel-drop',path=first,identity=L.identity(r,first),macro=macro,
    settings=settings,data=host..'/multichannel-drop-data',input=r.GetTrackGUID(input),track=r.GetTrackGUID(input),defer_items=true}
  r.SetExtState(EXT,'state',J.encode(state),false)
  context={id=sequence+1,origin='list',path=first,paths=J.array{first,second},items=J.array{}}
  local count,tracks=r.CountMediaItems(project),r.CountTracks(project)
  process('capture',false)
  assert(r.CountMediaItems(project)==count and r.CountTracks(project)==tracks,'Rejected batch inserted partial items')
  assert(r.GetExtState(EXT,'prepared')=='','Rejected batch retained prepared insertion')
  local message=r.GetExtState(EXT,'message');assert(message:find('AmbiX',1,true) and not message:find('stack traceback',1,true))
  report.rejected_batch_message=message
  check('Invalid second source rejects the whole batch without items, scratch tracks or stack traceback')
end,debug.traceback)
r.AM_DropContext,r.AM_DropResult=saved.context,saved.result
Explorer.transform,Explorer.tempo_factor=saved.transform,saved.tempo
r.DeleteExtState(EXT,'prepared',false);r.DeleteExtState(EXT,'captured',false);r.DeleteExtState(EXT,'state',false)
report.status=ok and'PASS'or'FAIL';report.error=err
assert(U.write(host..'/multichannel-drop.json',J.encode(report)))
