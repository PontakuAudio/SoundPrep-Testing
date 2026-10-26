local D=require('am.render_item')
local saved=D.render
local ok,err=xpcall(function()
  local project={};local snapshot={};local state,stops,renders=0,0,0
  local r={EnumProjects=function()return project end,
    GetPlayStateEx=function(p)assert(p==project);return state end,
    OnStopButtonEx=function(p)assert(p==project);stops=stops+1;state=0 end}
  D.render=function(api,s,directory,stem)
    assert(api==r and s==snapshot and state==0 and directory=='output' and stem=='drop')
    renders=renders+1;return 'output/drop.wav'
  end
  for _,transport in ipairs{0,1,2,3}do
    state=transport;local before=stops
    assert(D.render_drop(r,snapshot,'output','drop')=='output/drop.wav')
    assert(state==0 and stops==before+(transport~=0 and 1 or 0))
  end
  assert(renders==4)
  -- A recording cannot be stopped implicitly, including paused recording.
  for _,transport in ipairs{4,5,6,7}do
    state=transport;local before=stops
    assert(not pcall(D.render_drop,r,snapshot,'output','drop'))
    assert(state==transport and stops==before and renders==4)
  end
  state=1;r.OnStopButtonEx=function()end
  assert(not pcall(D.render_drop,r,snapshot,'output','drop') and renders==4)
  r.OnStopButtonEx=function()state=0 end
  D.render=function()error('Render cancelled')end
  assert(not pcall(D.render_drop,r,snapshot,'output','drop') and state==0,
    'Cancelled rendering must stay stopped and report failure')
end,debug.traceback)
D.render=saved
assert(ok,err)

-- Run the actual drop transaction through capture and finish. Native Raw items
-- must survive unchanged, including ranges, multichannel sources and playback.
local U=require('am.util');local J=require('am.json');local Model=require('am.model')
local I=require('am.insert');local Explorer=require('am.media_explorer');local EXT=require('am.drop').EXT
local L=require('am.loudness');local Analysis=require('am.analysis_policy')
local saved={reaper=reaper,read=U.read,explorer=Explorer.new,stamp=D.stamp,render=D.render,
  prepare=I.prepare,stage=I.stage,cached=I.cached,source=I.source,replace=I.replace,peaks=I.build_missing_peaks}
local ok,err=xpcall(function()
  local project={};local input={};local ext,context,items,calls,transport,cache,transform,tempo,measurements
  local paths={'/mono.wav','/stereo.wav','/multi.wav'}
  local channels={[paths[1]]=1,[paths[2]]=2,[paths[3]]=6}
  local function identity(path)return {path=path,size=100,mtime=10}end
  local r={
    APIExists=function(name)return name=='AM_DropContext'end,
    AM_DropContext=function()return J.encode(context)end,
    AM_DropResult=function(value)calls.accepted=value end,
    EnumProjects=function()return project,''end,time_precise=function()return 10 end,
    SetExtState=function(_,key,value)ext[key]=value end,
    GetExtState=function(_,key)return ext[key]or ''end,DeleteExtState=function(_,key)ext[key]=nil end,
    ShowConsoleMsg=function(value)calls.console=value end,
    JS_File_Stat=function()return 0,100,0,10 end,
    PCM_Source_CreateFromFile=function(path)return {path=path}end,PCM_Source_Destroy=function()end,
    GetMediaSourceLength=function()return 10,false end,
    GetMediaSourceNumChannels=function(source)return channels[source.path]end,GetMediaSourceType=function()return 'WAVE'end,
    CountTracks=function()return 1 end,GetTrack=function()return input end,GetTrackGUID=function()return 'input'end,
    GetMediaTrackInfo_Value=function()return 1 end,SetMediaTrackInfo_Value=function()end,ValidatePtr=function()return true end,
    GetPlayStateEx=function()return transport end,OnStopButtonEx=function()transport=0;calls.stops=calls.stops+1 end,
    CountMediaItems=function()return #items end,GetMediaItem=function(_,index)return items[index+1]end,
    GetSetMediaItemInfo_String=function(item)return true,item.guid end,
    GetActiveTake=function(item)return item.take end,GetMediaItemTake_Source=function(take)return take.source end,
    ValidatePtr2=function()return true end,CountTakes=function()return 1 end,
    SetMediaItemTakeInfo_Value=function(take,key,value)take[key]=value end,
    SetMediaItemInfo_Value=function(item,key,value)item[key]=value end,UpdateItemInProject=function()end,
    GetMediaItem_Track=function()return input end,
    GetMediaSourceParent=function(source)return source.parent end,GetMediaSourceFileName=function(source)return source.path end,
    GetSetMediaItemTakeInfo_String=function()return true,''end,
    GetItemStateChunk=function()return true,'<ITEM\nPOSITION 3\nLENGTH 10\n>\n'end,
    GetMainHwnd=function()return {}end,JS_Window_FindChildByID=function()end,
  }
  reaper=r;U.read=function(path)return measurements[path]end
  Explorer.new=function()return {transform=function()return transform end,tempo_factor=function()return tempo end}end
  D.stamp=function()end
  D.render=function(_,_,directory,stem)calls.renders=calls.renders+1;return directory..'/'..stem..'.wav'end
  I.cached=function()calls.cache=calls.cache+1;return cache and '/cached.wav'or nil end
  I.prepare=function(api,s,length,handles,directory,_,render)
    calls.prepare=calls.prepare+1
    if not cache then render(api,s,directory,'drop')end
    local plan=I.live_plan(s,length,handles);plan.pending=nil;plan.target='/rendered.wav';return plan
  end
  I.stage=function(_,s,length,handles)calls.stage=calls.stage+1;return I.live_plan(s,length,handles)end
  I.source=function(_,_,item,plan,s)
    assert(plan.original==s.path and s.path==item.path,'Mixed batch assigned the wrong frozen snapshot')
    item.processed=true;calls.sources=calls.sources+1
  end
  I.replace=function(_,_,item,plan)assert(plan.original==item.path);item.processed=true;calls.replaced=calls.replaced+1 end
  I.build_missing_peaks=function(_,_,processed)calls.peaks=#processed end
  local function run(options)
    options=options or {};ext={};items={};measurements={};transport=options.transport or 0;cache=options.cache
    transform=options.transform or {};tempo=options.tempo or 1
    calls={stops=0,renders=0,prepare=0,stage=0,cache=0,sources=0,replaced=0,console=''}
    local bank=Model.defaults();local macro=Model.effective(bank,nil)
    bank.settings.auto_render_drops=options.auto_render~=false
    bank.settings.insert_handles=options.handles~=false
    if options.edit then options.edit(macro,bank.settings)end
    local files=options.paths or {paths[2]};local path=files[1]
    local state={project=tostring(project),session='session',path=path,identity=identity(path),macro=macro,
      settings=bank.settings,data='/raw-drop',input='input',defer_items=options.defer_items~=false,analyzer_key='analyzer'}
    if macro.normalization.enabled or macro.source_peak_guard.enabled then
      for i,file in ipairs(files)do
        local analysis=Analysis.resolve(file,channels[file],bank.settings,macro.normalization)
        local value={status='ready',identity=identity(file),profile=L.profile(analysis),analyzer_key='analyzer',analysis=analysis,
          channels=channels[file],duration=10,max_momentary_lufs=-16-i,true_peak_dbtp=-10}
        if i==1 then state.measurement=value end
        measurements[L.cache_directory(state.data,state.settings)..'/'..L.key(identity(file),'analyzer',analysis)..'.json']=J.encode(value)
      end
    end
    ext.state=J.encode(state)
    context={id=1,phase=options.capture and 'capture'or 'prepare',origin=options.list and 'list'or 'waveform',
      path=path,paths=files,preview={path=path,mode=256,start=.2,['end']=.7}}
    local function invoke()
      calls.accepted=nil;dofile('./internal/Process waveform drop.lua');assert(calls.accepted,ext.message or calls.console)
    end
    invoke()
    if options.capture then
      -- A later live preset change cannot alter the captured Raw decision.
      state.macro=Model.macro('heavy','Heavy');ext.state=J.encode(state)
      context.phase='prepare_captured';invoke()
    end
    local prepared=J.decode(ext.prepared)
    for i=#files,1,-1 do
      local file=files[i];local source={path=file}
      if not options.list then source={parent=source,offset=2,length=5}end
      items[#items+1]={guid='item-'..i,path=file,take={source=source},position=3+i,length=options.list and 10 or 5}
    end
    local before=J.encode(items)
    context.phase='finish';context.items={};for _,item in ipairs(items)do context.items[#context.items+1]=item.guid end
    invoke()
    assert(ext.prepared==nil and ext.preview_stop=='session','Completion did not clean up or stop auditioning')
    return before,prepared
  end
  for _,state in ipairs{0,1,2,4,5,6}do
    for _,cached in ipairs{false,true}do for _,automatic in ipairs{false,true}do
      local before=run{transport=state,cache=cached,auto_render=automatic,handles=false,defer_items=false}
      assert(J.encode(items)==before and transport==state,'Raw drop changed the native item or transport')
      assert(calls.renders==0 and calls.prepare==0 and calls.stage==0 and calls.cache==0 and calls.peaks==0)
      assert(ext.queue==nil and ext.message:find('no render',1,true),'Raw drop queued a later render')
    end end
  end
  local before=run{capture=true,list=true,paths=paths,transport=1}
  assert(J.encode(items)==before and calls.prepare==0 and ext.queue==nil,'Captured mixed-channel Raw list was rendered')
  -- Gain-only drops apply the frozen normalization/guard/output gain to the
  -- native item, even while recording or when automatic rendering is disabled.
  for _,state in ipairs{0,1,2,3,4,5,6,7}do for _,automatic in ipairs{false,true}do
    for _,handles in ipairs{false,true}do
      local before,prepared=run{transport=state,auto_render=automatic,handles=handles,defer_items=false,
        edit=function(m,s)m.normalization.enabled=true;m.normalization.target_lufs=-12;s.monitor_gain_db=-12 end}
      local original=J.decode(before);local snapshot=prepared.entries[1].snapshot
      original[1].D_VOL=U.gain(snapshot.source_gain_db);original[1].take.D_VOL=1
      assert(J.encode(items)==J.encode(original),'Gain-only drop changed native source, range or placement')
      assert(snapshot.source_gain_db==5 and transport==state and calls.renders==0 and calls.prepare==0 and
        calls.stage==0 and calls.cache==0 and calls.peaks==0 and not ext.queue)
      assert(ext.message:find('Item Volume',1,true)and ext.message:find('no render',1,true))
    end
  end end
  for _,change in ipairs{
    function(m)m.normalization.enabled=true;m.normalization.target_lufs=-17 end,
    function(m)m.normalization.enabled=true;m.normalization.target_lufs=-24 end,
    function(m)m.source_peak_guard.enabled=true;m.source_peak_guard.ceiling_dbtp=-15 end,
    function(m)m.source_peak_guard.enabled=true end,
    function(m)m.source_transform.preserve_pitch=true end,
    function(m)m.output_gain_db=-3 end,function(m)m.id='macro'end,
  }do
    local _,prepared=run{edit=change,transport=1}
    local s=prepared.entries[1].snapshot
    assert(items[1].D_VOL==U.gain(s.source_gain_db+s.macro.output_gain_db) and items[1].take.D_VOL==1)
    assert(calls.prepare==0 and calls.stage==0 and calls.renders==0 and calls.stops==0 and not ext.queue)
    local with_fx=U.copy(s);with_fx.chain='BYPASS 0 0 0\n<JS utility/volume_pan\n>\n'
    assert(I.item_volume(with_fx)==nil,'FX input gain must not move to item volume')
    with_fx.chain='<FXCHAIN\nWNDRECT 112 422 724 394\nSHOW -1\nLASTSEL 0\nDOCKED 0\n>'
    assert(I.item_volume(with_fx)==I.item_volume(s),'Empty FX editor metadata triggered a render')
  end
  local before=J.encode(items);local stale={macro=Model.effective(Model.defaults(),nil),chain='',
    path=paths[2],identity={path=paths[2],size=100,mtime=11},source_gain_db=6}
  assert(not pcall(I.apply_item_volume,r,project,items[1],stale)and J.encode(items)==before,
    'Changed media received normalization from a stale analysis')
  -- Actual source transforms retain the existing render path.
  for _,change in ipairs{
    function(m)m.source_transform.reverse=true end,function(m)m.source_transform.pitch_semitones=1 end,
    function(m)m.source_transform.rate=.8 end,
  }do
    run{edit=change,transport=1}
    assert(calls.prepare==1 and calls.renders==1 and calls.replaced==1 and calls.stops==1 and calls.peaks==1)
  end
  for _,options in ipairs{{transform={rate=.8}},{transform={pitch_semitones=2}},{transform={rate=1},tempo=1.5}}do
    run(options);assert(calls.prepare==1 and calls.replaced==1,'Native transform was ignored by Raw detection')
  end
  for _,options in ipairs{{transport=5},{auto_render=false}}do
    options.list=true;options.paths=paths;options.edit=function(_,settings)settings.preview_downmix=true end
    run(options)
    assert(calls.prepare==0 and calls.stage==1 and calls.sources==1 and calls.peaks==1)
    local pending=J.decode(ext.queue);assert(#pending==1 and #pending[1].entries==1)
    assert(pending[1].entries[1].snapshot.path==paths[3],'Unprocessed Raw files entered the render queue')
    assert(items[1].processed and not items[2].processed and not items[3].processed)
  end
  run{list=true,paths=paths,edit=function(_,settings)settings.preview_downmix=true end,transport=1}
  assert(calls.prepare==1 and calls.replaced==1 and calls.renders==1 and calls.peaks==1 and not ext.queue)
  run{list=true,paths=paths,edit=function(_,settings)settings.preview_downmix=true end,transport=5,cache=true}
  assert(calls.prepare==1 and calls.replaced==1 and calls.renders==0 and calls.stage==0 and transport==5 and not ext.queue)
  for _,state in ipairs{1,5}do
    local _,prepared=run{list=true,paths=paths,transport=state,
      edit=function(m,s)m.normalization.enabled=true;m.normalization.target_lufs=-12;s.preview_downmix=true end}
    assert(items[1].processed and not items[2].processed and not items[3].processed)
    assert(items[2].D_VOL==U.gain(prepared.entries[2].snapshot.source_gain_db)and
      items[3].D_VOL==U.gain(prepared.entries[1].snapshot.source_gain_db),'Reordered batch mixed up per-file gains')
    if state==5 then
      local pending=J.decode(ext.queue);assert(#pending==1 and #pending[1].entries==1 and
        pending[1].entries[1].snapshot.path==paths[3],'Gain-only files entered the deferred render queue')
    else assert(calls.prepare==1 and calls.replaced==1 and not ext.queue)end
  end
end,debug.traceback)
reaper,U.read,Explorer.new,D.stamp,D.render=saved.reaper,saved.read,saved.explorer,saved.stamp,saved.render
I.prepare,I.stage,I.cached,I.source,I.replace,I.build_missing_peaks=saved.prepare,saved.stage,saved.cached,saved.source,saved.replace,saved.peaks
assert(ok,err)
