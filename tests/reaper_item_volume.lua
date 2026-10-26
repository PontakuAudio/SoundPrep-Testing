-- Actual native media insertion, frozen drop callbacks, item gain and Undo.
-- Analysis values and the drag UI payload are fixtures; no render is permitted.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local Model=require('am.model');local L=require('am.loudness')
local A=require('am.analysis_policy');local I=require('am.insert');local D=require('am.render_item')
local Explorer=require('am.media_explorer');local EXT=require('am.drop').EXT
local saved={context=r.AM_DropContext,result=r.AM_DropResult,explorer=Explorer.new,
  render=D.render,prepare=I.prepare,stage=I.stage,cached=I.cached}
local report={status='RUNNING',cases=J.array{},host_version=r.GetAppVersion()}
local data=host..'/item-volume-data';local context,accepted
local function process(phase)
  context.phase=phase;accepted=nil
  dofile(root..'/internal/Process waveform drop.lua');assert(accepted,r.GetExtState(EXT,'message'))
end
local function fixture(channels)
  local frame={};for ch=1,channels do frame[ch]=string.pack('<i2',100*ch)end
  local samples=table.concat(frame):rep(24000);local path=data..'/'..channels..'ch.wav'
  assert(U.write(path,'RIFF'..string.pack('<I4',36+#samples)..'WAVEfmt '..
    string.pack('<I4I2I2I4I4I2I2',16,1,channels,48000,48000*channels*2,channels*2,16)..'data'..string.pack('<I4',#samples)..samples))
  return path
end
local ok,err=xpcall(function()
  require('am.native').require(r);r.RecursiveCreateDirectory(data,0)
  r.AM_DropContext=function()return J.encode(context)end;r.AM_DropResult=function(value)accepted=value end
  Explorer.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  local function forbidden()error('Gain-only drop attempted a render/cache/queue operation')end
  D.render,I.prepare,I.stage,I.cached=forbidden,forbidden,forbidden,forbidden
  local project=r.EnumProjects(-1)
  r.InsertTrackAtIndex(0,false);local input=r.GetTrack(project,0);r.SetMediaTrackInfo_Value(input,'B_MAINSEND',0)
  r.InsertTrackAtIndex(1,false);local target=r.GetTrack(project,1);r.SetOnlyTrackSelected(target)
  r.SetMediaTrackInfo_Value(target,'B_MAINSEND',0);r.SetMediaTrackInfo_Value(target,'D_PANLAW',1)
  r.Undo_OnStateChange2(project,'Item Volume test setup')
  local sequence=0
  for _,channels in ipairs{1,2,6,128}do
    local path=fixture(channels)
    for _,db in ipairs{6,0,-9}do for _,range in ipairs{false,true}do
      -- Undo/Redo can rebuild track objects as well as their items.
      input=r.GetTrack(project,0);target=r.GetTrack(project,1);r.SetOnlyTrackSelected(target)
      sequence=sequence+1
      local definition=Model.defaults();local macro=Model.effective(definition,nil)
      macro.normalization.enabled=true;macro.normalization.target_lufs=-24+db
      definition.settings.auto_render_drops=sequence%2==0;definition.settings.insert_handles=sequence%2~=0
      definition.settings.monitor_gain_db=-24 -- never becomes item gain
      local identity=assert(L.identity(r,path));local analysis=A.resolve(path,channels,definition.settings,macro.normalization)
      local state={project=tostring(project),session='item-volume',path=path,identity=identity,macro=macro,
        settings=definition.settings,data=data,input=r.GetTrackGUID(input),defer_items=false,analyzer_key='gain-fixture',
        measurement={identity=identity,analyzer_key='gain-fixture',analysis=analysis,profile=L.profile(analysis),
          status='ready',channels=channels,duration=.5,max_momentary_lufs=-24,true_peak_dbtp=-18}}
      if channels==2 then
        local C=require('am.chunk')
        assert(r.SetTrackStateChunk(input,C.replace(C.read_track(r,input),'SHOW -1\nLASTSEL 0\nDOCKED 0\n'),false))
        state.track=r.GetTrackGUID(input);macro.id='empty-macro'
      end
      r.SetExtState(EXT,'state',J.encode(state),false)
      context={id=sequence,origin=range and 'waveform'or 'list',path=path,paths=J.array{path},
        preview={path=path,mode=256,start=.2,['end']=.8}}
      process('capture');process('prepare_captured')
      r.Undo_BeginBlock2(project);r.SetEditCurPos(2,false,false)
      if range then assert(r.InsertMediaSection(path,0,.1,.4,0)==1)else assert(r.InsertMedia(path,0)==1)end
      local item=r.GetMediaItem(project,0);local take=r.GetActiveTake(item);local source=r.GetMediaItemTake_Source(take)
      local length=r.GetMediaItemInfo_Value(item,'D_LENGTH');local offset=r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')
      -- Exercise replacement, not multiplication by a native preview gain.
      r.SetMediaItemInfo_Value(item,'D_VOL',.5);r.SetMediaItemTakeInfo_Value(take,'D_VOL',.25)
      context.items=J.array{select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))}
      r.OnPlayButtonEx(project);assert(r.GetPlayStateEx(project)==1)
      process('finish')
      assert(r.GetPlayStateEx(project)==1,'Normalization stopped timeline playback');r.OnStopButtonEx(project)
      r.Undo_EndBlock2(project,'Item Volume test drop',-1)
      assert(r.CountTakes(item)==1 and r.GetMediaItemTake_Source(take)==source,'Normalization replaced native source/take')
      assert(r.GetMediaItemInfo_Value(item,'D_POSITION')==2 and r.GetMediaItemInfo_Value(item,'D_LENGTH')==length and
        r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')==offset,'Normalization changed range or placement')
      local gain=U.gain(db)
      assert(math.abs(r.GetMediaItemInfo_Value(item,'D_VOL')-gain)<1e-12 and r.GetMediaItemTakeInfo_Value(take,'D_VOL')==1)
      assert(r.TakeFX_GetCount(take)==0 and r.CountTracks(project)==2 and r.GetExtState(EXT,'queue')=='')
      assert(not r.file_exists(data..'/inserted-media'),'Normalization created render artifacts')
      -- Track accessor reads the item mix, including Item Volume; a take
      -- accessor alone would only prove that the original PCM stayed intact.
      r.UpdateArrange()
      local accessor=assert(r.CreateTrackAudioAccessor(target));local buffer=r.new_array(channels*16)
      assert(r.GetAudioAccessorSamples(accessor,48000,channels,2.1,16,buffer)==1)
      r.DestroyAudioAccessor(accessor);local samples=buffer.table()
      for ch=1,channels do
        assert(math.abs(samples[ch]-100*ch/32768*gain)<1e-6,('Item Volume audio mismatch ch %d: %.8f'):format(ch,samples[ch]))
      end
      assert(r.Undo_DoUndo2(project)==1 and r.CountMediaItems(project)==0,'One Undo did not remove the drop')
      assert(r.Undo_DoRedo2(project)==1 and r.CountMediaItems(project)==1)
      item=r.GetMediaItem(project,0);take=r.GetActiveTake(item)
      -- Undo serializes VOLPAN with fewer decimals than the live API double.
      assert(r.CountTakes(item)==1 and math.abs(r.GetMediaItemInfo_Value(item,'D_VOL')-gain)<1e-6 and
        r.GetMediaItemTakeInfo_Value(take,'D_VOL')==1,
        ('Redo lost Item Volume: item %.12f, take %.12f, takes %d'):format(
          r.GetMediaItemInfo_Value(item,'D_VOL'),r.GetMediaItemTakeInfo_Value(take,'D_VOL'),r.CountTakes(item)))
      local original=r.GetMediaItemTake_Source(take)
      while r.GetMediaSourceParent(original)do original=r.GetMediaSourceParent(original)end
      assert(U.path_equal(r.GetMediaSourceFileName(original,''),path),'Redo lost original media')
      assert(r.Undo_DoUndo2(project)==1 and r.CountMediaItems(project)==0)
      report.cases[#report.cases+1]={channels=channels,gain_db=db,range=range,item_volume=gain,audio_first_sample=samples[1]}
    end end
  end
end,debug.traceback)
r.OnStopButton()
r.AM_DropContext,r.AM_DropResult,Explorer.new=saved.context,saved.result,saved.explorer
D.render,I.prepare,I.stage,I.cached=saved.render,saved.prepare,saved.stage,saved.cached
for _,key in ipairs{'state','prepared','captured','busy','preview_stop','message'}do r.DeleteExtState(EXT,key,false)end
report.status=ok and 'PASS'or 'FAIL';report.error=err
assert(U.write(host..'/item-volume.json',J.encode(report)))
