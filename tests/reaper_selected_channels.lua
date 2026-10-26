-- Run in an isolated marked host. Real insertion/channel modes/FX/audio;
-- only the drag callback payload and analysis gain are controlled fixtures.
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local Model=require('am.model');local L=require('am.loudness')
local Selection=require('am.channel_selection');local I=require('am.insert');local D=require('am.render_item');local E=require('am.media_explorer');local EXT=require('am.drop').EXT
local report={status='RUNNING',cases=J.array{},version=r.GetAppVersion()}
local saved={context=r.AM_DropContext,result=r.AM_DropResult,explorer=E.new,render=I.prepare,stage=I.stage}
local context,accepted
local function process(phase)
  context.phase=phase;accepted=nil;dofile(root..'/internal/Process waveform drop.lua')
  assert(accepted,r.GetExtState(EXT,'message'))
end
local data=host..'/selected-channels-test-'..U.hash(r.genGuid())
local ok,err=xpcall(function()
  require('am.native').require(r);r.RecursiveCreateDirectory(data,0)
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.GetSetProjectInfo(0,'PROJECT_SRATE',48000,true);r.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  r.AM_DropContext=function()return J.encode(context)end;r.AM_DropResult=function(value)accepted=value end
  E.new=function()return {transform=function()return {}end,tempo_factor=function()return 1 end}end
  I.prepare=function()error('Channel-only drop tried to render')end;I.stage=function()error('Channel-only drop was deferred')end
  local files={}
  for _,n in ipairs{6,128}do
    local frame={};for c=1,n do frame[c]=string.pack('<i2',100*c)end
    local samples=table.concat(frame):rep(12000);local path=data..'/'..n..'ch.wav'
    assert(U.write(path,'RIFF'..string.pack('<I4',36+#samples)..'WAVEfmt '..
      string.pack('<I4I2I2I4I4I2I2',16,1,n,48000,48000*n*2,n*2,16)..'data'..string.pack('<I4',#samples)..samples))
    files[n]=path
  end
  r.GetSetProjectInfo_String(0,'RECORD_PATH',data,true)
  local project=r.EnumProjects(-1)
  r.InsertTrackAtIndex(r.CountTracks(project),false);local input=r.GetTrack(project,r.CountTracks(project)-1)
  r.SetMediaTrackInfo_Value(input,'B_MAINSEND',0)
  local all={};for ch=1,128 do all[ch]=ch end
  for seq,c in ipairs{{6,4,4,6},{6,5,6,71},{6,5,2,0},{6,2,5,0},{128,64,64,66},{128,65,65,131},{128,128,128,194},{128,64,65,130},{128,65,66,195},{128,127,128,257},{6,1,3,0,{1,3,5}},{128,32,64,0,{32,64,96,128}},{128,1,65,0,{1,65,128}},{128,1,2,0,all}}do
    local n,left,right,mode,list=table.unpack(c);local path=files[n]
    local selection=list and {channels=list}or {left=left,right=right}
    local expected=list or {left,right};local output=Selection.output(selection)
    local def=Model.defaults();local macro=Model.effective(def,nil)
    macro.normalization.enabled=false;macro.source_peak_guard.enabled=false
    def.settings.channel_selections={[tostring(n)]=selection};def.settings.auto_render_drops=seq%2==0
    local state={project=tostring(project),session='selected-test',path=path,identity=assert(L.identity(r,path)),
      macro=macro,settings=def.settings,data=data,input=r.GetTrackGUID(input),defer_items=false}
    r.SetExtState(EXT,'state',J.encode(state),false)
    context={id=seq,origin='waveform',path=path,paths=J.array{path},preview={path=path,mode=256,start=.2,['end']=.8}}
    process('capture');local snapshot=J.decode(r.GetExtState(EXT,'captured')).entries[1].snapshot
    state.settings.channel_selections={};r.SetExtState(EXT,'state',J.encode(state),false)
    process('prepare_captured')
    r.InsertTrackAtIndex(r.CountTracks(project),false);local target=r.GetTrack(project,r.CountTracks(project)-1)
    r.SetOnlyTrackSelected(target);r.SetMediaTrackInfo_Value(target,'B_MAINSEND',0);r.SetMediaTrackInfo_Value(target,'D_PANLAW',1)
    r.SetMediaTrackInfo_Value(target,'I_NCHAN',list and 2 or n);r.SetEditCurPos(0,false,false)
    r.Undo_BeginBlock2(project);assert(r.InsertMediaSection(path,0,.05,.2,0)==1)
    local item=r.GetTrackMediaItem(target,0)
    context.items=J.array{select(2,r.GetSetMediaItemInfo_String(item,'GUID','',false))};process('finish')
    r.Undo_EndBlock2(project,'Selected channel drop test',-1)
    local take=r.GetActiveTake(item)
    assert(r.CountTakes(item)==1,'Selection created rendered media')
    assert(r.GetMediaTrackInfo_Value(target,'I_NCHAN')>=output,'Drop track too narrow')
    assert(r.GetMediaItemTakeInfo_Value(take,'I_CHANMODE')==mode,'Wrong native take mode')
    assert(r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')==path,'Original source replaced')
    assert(math.abs(r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')-.05)<1e-8)
    assert(math.abs(r.GetMediaItemInfo_Value(item,'D_LENGTH')-.15)<1e-8)
    assert((r.TakeFX_GetCount(take)==0)==(mode~=0),'Unexpected channel mapper FX')
    -- Track accessors include take channel mode, but omit Take FX. Bake an
    -- independent scratch recipe for arbitrary pairs, never the dropped item.
    local rendered=D.render(r,snapshot,data,'verify_'..seq)
    local src=assert(r.PCM_Source_CreateFromFile(rendered));assert(r.GetMediaSourceNumChannels(src)==output);r.PCM_Source_Destroy(src)
    local check=r.AddMediaItemToTrack(target);local ct=r.AddTakeToMediaItem(check)
    r.SetMediaItemTake_Source(ct,assert(r.PCM_Source_CreateFromFile(rendered)))
    r.SetMediaItemInfo_Value(check,'D_LENGTH',.15)
    local accessor=assert(r.CreateTakeAudioAccessor(ct));local values=r.new_array(output*16)
    assert(r.GetAudioAccessorSamples(accessor,48000,output,.05,16,values)==1);r.DestroyAudioAccessor(accessor)
    for ch=1,output do assert(math.abs(values[ch]-expected[ch]*100/32768)<1e-5,
      ('Wrong output %d for %s: %.8f'):format(ch,Selection.label(selection),values[ch]))end
    r.DeleteTrackMediaItem(target,check)
    r.SelectAllMediaItems(project,false);r.SetMediaItemSelected(item,true)
    r.GetSetProjectInfo_String(project,'RECORD_PATH',data,true)
    r.GetSetProjectInfo_String(project,'RECORD_PATH_SECONDARY','',true)
    r.GetSetProjectInfo_String(project,'OPENCOPY_CFGIDX','1',true)
    r.GetSetProjectInfo_String(project,'APPLYFX_FORMAT','evaw',true)
    r.SNM_SetIntConfigVar('applyfxtail',0);r.SNM_SetIntConfigVar('itemfxtail',0);r.SNM_SetIntConfigVar('showpeaksbuild',0)
    r.Main_OnCommandEx(41993,0,project) -- Bake the actual dropped take, including its FX.
    local baked=r.GetActiveTake(item);assert(baked~=take)
    local nch=r.GetMediaSourceNumChannels(r.GetMediaItemTake_Source(baked))
    local aa=assert(r.CreateTakeAudioAccessor(baked));local actual=r.new_array(nch*16)
    assert(r.GetAudioAccessorSamples(aa,48000,nch,.05,16,actual)==1);r.DestroyAudioAccessor(aa)
    for ch=1,output do assert(math.abs(actual[ch]-values[ch])<1e-5,'Dropped take differs from preview recipe')end
    for ch=output+1,nch do assert(math.abs(actual[ch])<1e-7,'Unselected microphone leaked into channel '..ch)end
    report.cases[#report.cases+1]={source_channels=n,left=left,right=right,take_mode=mode,fx=r.TakeFX_GetCount(take),selection=selection,output_channels=output,audio=values.table()}
    assert(U.write(host..'/selected-channels-report.json',J.encode(report)))
  end
end,debug.traceback)
r.AM_DropContext=saved.context;r.AM_DropResult=saved.result;E.new=saved.explorer;I.prepare=saved.render;I.stage=saved.stage
report.status=ok and 'PASS'or 'FAIL';report.error=err
assert(U.write(host..'/selected-channels-report.json',J.encode(report)))
