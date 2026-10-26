local U=require('am.util');local J=require('am.json');local L=require('am.loudness');local Model=require('am.model')
local Analysis=require('am.analysis_policy')
local Drop=require('am.drop');local E=require('am.export');local Render=require('am.render_item');local Explorer=require('am.media_explorer')
local read,snapshot,stamp,explorer,reaper_before=U.read,E.snapshot,Render.stamp,Explorer.new,reaper
local files,ext,context,ack,console={},{},nil,nil,''
local project={};local mutations,sources,destroyed,snapshots,reads=0,0,0,0,0
local identities,counts,kinds,lengths,undecodable={},{},{},{},{}
local macro_track={};local macro_width=12
local function file(name,channels)
  local path='/test/'..name;identities[path]={path=path,size=100+channels,mtime=10};counts[path]=channels;return path
end
local mono=file('mono.wav',1);local stereo=file('stereo.wav',2)
local multi=file('MixPre-002.WAV',6);local ambix=file('field_AMBIX.wav',4)
local r={
  APIExists=function(name)return name=='AM_DropContext'end,
  AM_DropContext=function()return J.encode(context)end,AM_DropResult=function(ok)ack=ok end,
  EnumProjects=function()return project,''end,time_precise=function()return 10 end,
  SetExtState=function(section,key,value)ext[section..':'..key]=value end,
  GetExtState=function(section,key)return ext[section..':'..key]or ''end,
  DeleteExtState=function(section,key)ext[section..':'..key]=nil end,
  ShowConsoleMsg=function(text)console=console..text end,
  JS_File_Stat=function(path)local id=identities[path];return id and 0 or -1,id and id.size,0,id and id.mtime end,
  PCM_Source_CreateFromFile=function(path)if undecodable[path]then return end;sources=sources+1;return {path=path}end,
  PCM_Source_Destroy=function()destroyed=destroyed+1 end,
  GetMediaSourceLength=function(source)return lengths[source.path]or 10,false end,
  GetMediaSourceNumChannels=function(source)return counts[source.path]end,
  GetMediaSourceType=function(source)return kinds[source.path]or 'WAVE'end,
  InsertTrackAtIndex=function()mutations=mutations+1 end,AddMediaItemToTrack=function()mutations=mutations+1 end,
  SetMediaTrackInfo_Value=function()mutations=mutations+1 end,
  CountTracks=function()return 1 end,GetTrack=function()return macro_track end,GetTrackGUID=function()return 'macro'end,
  GetMediaTrackInfo_Value=function(track,key)assert(track==macro_track and key=='I_NCHAN');return macro_width end,
  GetTrackStateChunk=function()return true,'<TRACK\nNAME "Macro"\n<FXCHAIN\nBYPASS 0 0 0\n<JS utility/volume_pan ""\n-12 0 0\n>\nWAK 0 0\n>\n>\n'end,
}
local function state(path,enabled,mode)
  local bank=Model.defaults();bank.raw.normalization.enabled=true;bank.raw.normalization.target_lufs=-18
  bank.raw.source_peak_guard.enabled=true;bank.settings.preview_downmix=enabled or false;bank.settings.preview_downmix_mode=mode or 'auto'
  return {project=tostring(project),session='session',path=path,identity=U.copy(identities[path]),macro=Model.effective(bank,nil),
    settings=bank.settings,data='/multi-drop',analyzer_key='analyzer',input='input',defer_items=true}
end
local function measurement(path,analysis)
  return {status='ready',identity=U.copy(identities[path]),profile=L.profile(analysis),analyzer_key='analyzer',
    channels=counts[path],analysis=U.copy(analysis),duration=10,max_momentary_lufs=-24,true_peak_dbtp=-18}
end
local function spec(path,s)return Analysis.resolve(path,counts[path],s.settings)end
local function ready(s)
  s.measurement=measurement(s.path,spec(s.path,s));return s
end
local function cached(path,s)
  local analysis=spec(path,s)
  files[s.data..'/cache/'..L.key(identities[path],s.analyzer_key,analysis)..'.json']=J.encode(measurement(path,analysis))
end
local function invoke(s,paths,phase)
  context={id=1,phase=phase or 'prepare',origin=paths and 'list' or 'waveform',path=s.path,paths=paths or {s.path},
    preview={path=s.path,mode=256,start=.1,['end']=.5}}
  ext={};r.SetExtState(Drop.EXT,'state',J.encode(s));ack=nil;console='';snapshots=0;reads=0
  dofile('./internal/Process waveform drop.lua')
  assert(ack~=nil,'Drop did not return a result')
  assert(mutations==0,'Preflight mutated project contents')
  assert(sources==destroyed,'Preflight leaked a PCM source')
  if not ack then
    assert(r.GetExtState(Drop.EXT,'prepared')=='','Rejected batch retained a prepared transaction')
    assert(not console:find('stack traceback:',1,true),'Expected refusal leaked a stack trace: '..console)
    return nil,r.GetExtState(Drop.EXT,'message')
  end
  local key=phase=='capture'and 'captured'or 'prepared'
  return J.decode(r.GetExtState(Drop.EXT,key))
end
local ok,err=xpcall(function()
  reaper=r;U.read=function(path)reads=reads+1;return files[path]end
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  E.snapshot=function(_,path,macro,chain,gain,identity,range,settings)
    snapshots=snapshots+1
    return {path=path,macro=U.copy(macro),chain=chain,source_gain_db=gain,identity=U.copy(identity),range=range,fade_ms=settings.fade_ms}
  end
  Render.stamp=function(_,value)value.item_render={revision=2}end

  -- OFF preserves every source channel, applies one common measured gain, and
  -- bypasses stereo Macro FX without changing the user's normalization flags.
  for _,count in ipairs{3,4,6,9,16,64,121,128}do
    local path=file('original_'..count..'.wav',count);local s=ready(state(path,false,'ambix'))
    s.analysis_job={identity=U.copy(s.identity),result='/pending.json',job_id='pending'}
    local before=J.encode(s);local prepared=assert(invoke(s));local value=prepared.entries[1].snapshot
    local mix=value.channel_mix
    assert(mix.revision==1 and mix.source_channels==count and mix.output_channels==count and mix.mode==0)
    assert(mix.fx_channels==math.ceil(count/2)*2 and mix.preference=='ambix')
    assert(value.source_gain_db==6 and value.macro.normalization.enabled and value.macro.source_peak_guard.enabled)
    assert(value.source_processing.fx_bypassed and value.source_processing.bypass_reason=='multichannel_downmix_off')
    assert(Analysis.same(value.analysis,spec(path,s)) and value.chain=='')
    assert(J.encode(s)==before and reads==0,'Multichannel preflight changed settings or reread a valid measurement')
    assert(value.range[1]==1 and value.range[2]==5,'Waveform range was lost')
  end

  -- Freeze each resolved mode rather than asking Auto again at rendering time.
  for _,case in ipairs{
    {multi,'auto',1},{multi,'discrete',1},{ambix,'auto',2},{ambix,'ambix',2},{ambix,'discrete',1},
    {file('field_ambix_9.wav',9),'auto',2},{file('B_format.wav',4),'auto',1},
    {file('ambixation.wav',4),'auto',1},{file('field_ambix_6.wav',6),'auto',1},
  }do
    local path,preference,mode=table.unpack(case);local s=ready(state(path,true,preference))
    local captured=assert(invoke(s,nil,'capture'));local value=captured.entries[1].snapshot
    assert(value.channel_mix.source_channels==counts[path] and value.channel_mix.output_channels==2 and value.channel_mix.mode==mode)
    assert(value.channel_mix.fx_channels==2 and value.channel_mix.preference==preference)
    assert(value.analysis.basis==(mode==2 and'downmix_ambix'or'downmix_discrete') and value.source_gain_db==6)
    assert(not value.source_processing.fx_bypassed)
    assert(captured.state.macro.normalization.enabled and captured.state.macro.source_peak_guard.enabled,
      'The original normalization settings changed')
    s.settings.preview_downmix=false;s.settings.preview_downmix_mode='discrete'
    assert(value.channel_mix.mode==mode,'Captured channel mapping was not frozen')
  end

  -- The current Macro track may have deliberately wide FX pin mappings.
  local s=ready(state(ambix,true));s.track='macro';s.macro.output_gain_db=-3;s.macro.source_transform.rate=.8
  local value=assert(invoke(s)).entries[1].snapshot
  assert(value.channel_mix.output_channels==2 and value.channel_mix.fx_channels==12 and value.chain:find('utility/volume_pan',1,true))
  s.settings.preview_downmix=false;ready(s)
  value=assert(invoke(s)).entries[1].snapshot
  assert(value.channel_mix.output_channels==4 and value.channel_mix.fx_channels==4 and value.chain=='')
  assert(value.source_processing.fx_bypassed and value.analysis.basis=='ambix_w')
  assert(value.macro.output_gain_db==-3 and value.macro.source_transform.rate==.8,'FX bypass lost gain/transform')

  -- Mono/stereo keep their existing snapshot shape and analysis requirements.
  -- A mixed list requires the appropriate measurement for every source.
  for _,path in ipairs{mono,stereo}do
    files={};s=state(path,true,'ambix');s.measurement=measurement(path)
    local prepared=assert(invoke(s));value=prepared.entries[1].snapshot
    assert(value.source_gain_db==6 and value.macro.normalization.enabled and value.macro.source_peak_guard.enabled)
    assert(not value.channel_mix and not value.source_processing,'Legacy channel recipes were changed')
    assert(not value.analysis)
    s.settings.preview_downmix_mode='auto'
    cached(multi,s)
    prepared=assert(invoke(s,{multi,path}));local first,second=prepared.entries[1].snapshot,prepared.entries[2].snapshot
    assert(first.source_gain_db==6 and first.macro.normalization.enabled and first.analysis.basis=='downmix_discrete')
    assert(second.source_gain_db==6 and second.macro.normalization.enabled,'Multichannel policy leaked to a later mono/stereo entry')
  end
  files={};s=ready(state(multi,false));s.track='macro'
  local prepared,message=invoke(s,{multi,stereo})
  assert(not prepared and message:find('Analysis required:',1,true)and snapshots==1,
    'Missing analysis accepted part of a mixed batch')
  cached(stereo,s)
  prepared=assert(invoke(s,{multi,stereo}));assert(prepared.entries[2].snapshot.source_gain_db==6)
  assert(prepared.entries[1].snapshot.macro.normalization.enabled)
  assert(prepared.entries[1].snapshot.chain=='' and prepared.entries[2].snapshot.chain:find('utility/volume_pan',1,true),
    'Multichannel FX bypass leaked to the stereo entry of a mixed batch')

  -- Different channel interpretations of the same file never share a result,
  -- an in-flight response, or a published analysis failure.
  files={};s=ready(state(ambix,true,'auto'));local downmix=U.copy(s.measurement)
  s.settings.preview_downmix=false
  prepared,message=invoke(s);assert(not prepared and message:find('Analysis required:',1,true))
  s.analysis_identity=U.copy(s.identity);s.analysis_spec=U.copy(downmix.analysis);s.analysis_error='Wrong basis failed'
  prepared,message=invoke(s);assert(not prepared and not message:find('Wrong basis failed',1,true))
  s.analysis_spec=spec(ambix,s)
  prepared,message=invoke(s);assert(not prepared and message:find('Wrong basis failed',1,true))
  s.analysis_error=nil
  s.analysis_job={identity=U.copy(s.identity),analysis=U.copy(downmix.analysis),result='/basis.result.json',job_id='basis'}
  downmix.job_id='basis';files[s.analysis_job.result]=J.encode(downmix)
  prepared,message=invoke(s);assert(not prepared and message:find('Analysis required:',1,true))
  local current=measurement(ambix,spec(ambix,s));current.job_id='basis'
  s.analysis_job.analysis=U.copy(current.analysis);files[s.analysis_job.result]=J.encode(current)
  prepared=assert(invoke(s));assert(prepared.entries[1].snapshot.source_gain_db==6 and prepared.entries[1].snapshot.analysis.basis=='ambix_w')
  files={};s=state(multi,false)
  prepared,message=invoke(s);assert(not prepared and message:find('Analysis required:',1,true))
  s.macro.normalization.enabled=false;s.macro.source_peak_guard.enabled=false
  prepared=assert(invoke(s));assert(prepared.entries[1].snapshot.source_gain_db==0)

  -- An explicit AmbiX preference is a clear refusal for incompatible files;
  -- the whole list is prevalidated before any native insertion is accepted.
  for _,preference in ipairs{'ambix','invalid'}do
    s=state(multi,true,preference);prepared,message=invoke(s)
    assert(not prepared and message:find(preference=='ambix'and 'full 3D'or 'Unknown preview downmix mode',1,true))
  end
  s=ready(state(ambix,true,'ambix'));prepared,message=invoke(s,{ambix,multi})
  assert(not prepared and snapshots==1 and message:find('full 3D',1,true))
  for _,count in ipairs{0,129,144,4.5}do
    local path=file('unsupported_'..count..'.wav',count)
    prepared,message=invoke(state(path,false))
    assert(not prepared and message:find('1–128 audio channels',1,true))
  end
  for _,kind in ipairs{'MIDI','VIDEO','RPP_PROJECT'}do
    kinds[multi]=kind;prepared,message=invoke(state(multi,false));assert(not prepared and message:find('Unsupported audio source',1,true))
  end
  kinds[multi]=nil;lengths[multi]=0
  prepared,message=invoke(state(multi,false));assert(not prepared and message:find('Unsupported audio source',1,true))
  lengths[multi]=nil;undecodable[multi]=true
  prepared,message=invoke(state(multi,false));assert(not prepared and message:find('Cannot decode dropped file',1,true))
  undecodable[multi]=nil;s=state(multi,false);local identity=identities[multi];identities[multi]=nil
  prepared,message=invoke(s);assert(not prepared and message:find('Cannot read dropped file',1,true));identities[multi]=identity
end,debug.traceback)
U.read,E.snapshot,Render.stamp,Explorer.new,reaper=read,snapshot,stamp,explorer,reaper_before
assert(ok,err)
