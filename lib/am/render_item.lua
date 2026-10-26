-- Offline item FX rendering in the current REAPER. No process, project tab,
-- device initialization, save-project operation or main render dialog.
local U=require('am.util');local J=require('am.json');local C=require('am.chunk')
local E=require('am.export');local L=require('am.loudness')
local Channels=require('am.render_channels')
local M={}
-- Called only on an automatic drop's cache miss. Apply track/take FX stops
-- REAPER's transport itself; stop explicitly and finish the drop now instead
-- of leaving it pending until the user happens to stop. Recording is separate.
function M.render_drop(r,snapshot,directory,stem)
  local project=r.EnumProjects(-1);local state=r.GetPlayStateEx(project)
  assert((state&4)==0,'Render waits until recording stops')
  if state~=0 then
    r.OnStopButtonEx(project)
    assert(r.GetPlayStateEx(project)==0,'Could not stop playback for the drop render')
  end
  return M.render(r,snapshot,directory,stem)
end
local function sample_rate(r)
  local project=r.EnumProjects(-1)
  if r.GetSetProjectInfo(project,'PROJECT_SRATE_USE',0,false)>0 then return r.GetSetProjectInfo(project,'PROJECT_SRATE',0,false)end
  return tonumber(select(2,r.GetAudioDeviceInfo('SRATE'))) or 48000
end
function M.stamp(r,snapshot)
  local project=r.EnumProjects(-1);local tempo={}
  for i=0,r.CountTempoTimeSigMarkers(project)-1 do
    tempo[#tempo+1]={r.GetTempoTimeSigMarker(project,i)}
  end
  snapshot.item_render={revision=snapshot.channel_mix and 3 or 2,sample_rate=sample_rate(r),tempo=r.Master_GetTempo(),tempo_markers=tempo,
    pitch_mode=r.SNM_GetIntConfigVar('defpitchcfg',-1),resample=r.SNM_GetIntConfigVar('projrenderresample',-1)}
end
function M.render(r,snapshot,directory,stem)
  assert(stem~='' and not stem:find('[/\\%z\r\n]'),'Use a plain output file name')
  local project=r.EnumProjects(-1);local target=directory..'/'..stem..'.wav'
  assert(r.GetPlayStateEx(project)==0,'Render waits until playback and recording stop')
  assert(not r.file_exists(target),'Output already exists')
  assert(L.same(snapshot.identity,L.identity(r,snapshot.path)),'Source changed after snapshot')
  local selected,tracks,strings,config={},{},{},{}
  for i=0,r.CountSelectedMediaItems(project)-1 do selected[#selected+1]=r.GetSelectedMediaItem(project,i)end
  for i=0,r.CountSelectedTracks(project)-1 do tracks[#tracks+1]=r.GetSelectedTrack(project,i)end
  for _,key in ipairs{'RECORD_PATH','RECORD_PATH_SECONDARY','OPENCOPY_CFGIDX','APPLYFX_FORMAT'}do
    local ok,value=r.GetSetProjectInfo_String(project,key,'',false);assert(ok,'Unsupported project setting: '..key);strings[key]=value
  end
  for _,key in ipairs{'applyfxtail','itemfxtail','showpeaksbuild'}do
    config[key]=r.SNM_GetIntConfigVar(key,-9999);assert(config[key]~=-9999,'Unsupported render setting: '..key)
  end
  local staging=directory..'/.render-'..r.genGuid():gsub('[^%w]','')
  r.RecursiveCreateDirectory(staging,0)
  local output_channels=Channels.output(snapshot)
  local track,generated,generated_channels;local began=r.time_precise()
  r.PreventUIRefresh(1)
  local ok,err=xpcall(function()
    r.GetSetProjectInfo_String(project,'RECORD_PATH',staging,true)
    r.GetSetProjectInfo_String(project,'RECORD_PATH_SECONDARY','',true)
    r.GetSetProjectInfo_String(project,'OPENCOPY_CFGIDX','1',true)
    r.GetSetProjectInfo_String(project,'APPLYFX_FORMAT','evaw',true)
    for _,key in ipairs{'applyfxtail','itemfxtail'}do r.SNM_SetIntConfigVar(key,math.floor(snapshot.macro.export.tail_seconds*1000+.5))end
    -- The scratch render's transient peak build must not activate its own
    -- window over Arrange. Restore the user's preference on every exit.
    r.SNM_SetIntConfigVar('showpeaksbuild',0)
    -- Index zero is outside any existing folder; the scratch track cannot
    -- include destination-track FX, folder processing, sends or master FX.
    r.InsertTrackAtIndex(0,false);track=assert(r.GetTrack(project,0))
    for key,value in pairs{B_MAINSEND=0,B_SHOWINTCP=1,B_SHOWINMIXER=0,I_RECARM=0,I_SOLODEFEAT=1,D_PANLAW=1}do
      r.SetMediaTrackInfo_Value(track,key,value)
    end
    local render=U.copy(snapshot)
    render.chain=Channels.chain(r,render,true)
    if render.channel_mix then render.channel_mix.chain_applied=true end
    render.macro.output_gain_db=0
    local item,duration=E.populate(r,render,track)
    r.SelectAllMediaItems(project,false);r.SetMediaItemSelected(item,true)
    local chunk=C.read_track(r,track):gsub('([\r\n]%s*)MAINSEND 0','%1MAINSEND 1')
      :gsub('([\r\n]%s*)SHOWINMIX 0','%1SHOWINMIX 1')
    local rate=sample_rate(r)
    local tempo=r.GetTrackEnvelopeByChunkName(r.GetMasterTrack(project),'<TEMPOENVEX')
    local tempoChunk=tempo and select(2,r.GetEnvelopeStateChunk(tempo,'',false)) or ''
    local projectText=('<REAPER_PROJECT 0.1 7 1\nSAMPLERATE %.17g 1 0\nTEMPO %.17g\nSELECTION 0 %.17g\nRENDER_RANGE 2 0 %.17g 4 %.17g\nRENDER_FMT 0 %d %.17g\nRENDER_1X 0\n<RENDER_CFG\nZXZhdxgAAQ==\n>\n%s\n%s\n>\n'):format(rate,r.Master_GetTempo(),duration,duration,snapshot.macro.export.tail_seconds*1000,output_channels,rate,tempoChunk,chunk)
    local action=output_channels>2 and 41993 or 40209
    if not(r.AM_QuietItemAction and r.AM_QuietItemAction(action,project))then
      r.Main_OnCommandEx(action,0,project) -- Compatible with older helper DLLs.
    end
    assert(r.CountTakes(item)==2,'Item render was cancelled')
    local source=r.GetMediaItemTake_Source(r.GetActiveTake(item))
    generated_channels=r.GetMediaSourceNumChannels(source)
    assert(generated_channels>=output_channels,'Item render lost source channels')
    generated=r.GetMediaSourceFileName(source,'')
    assert(generated~='' and r.file_exists(generated),'Item render did not create media')
    assert(U.path_equal(generated:match('^(.*)[/\\]'),staging),'Unexpected render output directory')
    assert(U.write(directory..'/'..stem..'.rpp',projectText))
    assert(U.write(directory..'/'..stem..'.macro.json',J.encode(snapshot)))
  end,debug.traceback)
  if track and r.ValidatePtr2(project,track,'MediaTrack*')then r.DeleteTrack(track)end
  for key,value in pairs(strings)do r.GetSetProjectInfo_String(project,key,value,true)end
  for key,value in pairs(config)do r.SNM_SetIntConfigVar(key,value)end
  for _,item in ipairs(selected)do if r.ValidatePtr2(project,item,'MediaItem*')then r.SetMediaItemSelected(item,true)end end
  for _,t in ipairs(tracks)do if r.ValidatePtr2(project,t,'MediaTrack*')then r.SetTrackSelected(t,true)end end
  r.PreventUIRefresh(-1)
  if ok then
    if generated_channels>output_channels then
      -- REAPER renders the even track width, including internal FX sidechains.
      -- Trim only after releasing the scratch take's file handle (Windows).
      ok,err=pcall(require('am.wave_channels').trim,generated,target,output_channels)
    else
      ok,err=os.rename(generated,target)
      if not ok then ok,err=U.copy_file(generated,target);if ok then os.remove(generated)end end
    end
  end
  -- Only this invocation's freshly created staging directory is cleaned.
  local files={};local index=0
  while true do local name=r.EnumerateFiles(staging,index);if not name then break end;files[#files+1]=name;index=index+1 end
  for _,name in ipairs(files)do os.remove(staging..'/'..name)end
  os.remove(staging)
  assert(ok,err)
  M.last_seconds=r.time_precise()-began
  return target
end
return M
