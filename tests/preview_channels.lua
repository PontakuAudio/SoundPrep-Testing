local Preview=require('am.preview');local Model=require('am.model');local U=require('am.util')

local function fixture(mode)
  local native=mode~='SWS';local modern=mode=='modern' or mode=='ambix' or mode=='selection';local modes=mode=='ambix'
  local state={channels=1,sources={},bound=nil,
    counts={file=0,destroy=0,channels=0,length=0,section=0,configure=0,am=0,cf=0,
      output=0,set=0,wave=0,latency=0,play=0,stop=0,bind=0,multi=0,mix=0}}
  local project,track,fx={},{},{}
  local function count(name)state.counts[name]=state.counts[name]+1 end
  local function source(kind)
    local value={kind=kind,channels=state.channels,length=10}
    state.sources[#state.sources+1]=value;return value
  end
  local function create(value,downmix)
    assert(not value.destroyed and (modern or value.channels<=2))
    return {channels=value.channels,output_channels=value.channels>2 and not downmix and value.channels or 2,
      downmix=downmix,length=value.length,values={}}
  end
  local function get(handle,key)
    if handle.stopped then return false,0 end
    return true,key=='D_LENGTH' and handle.length or handle.values[key] or 0
  end
  local function set(handle,key,value)
    assert(not handle.stopped);count('set');handle.values[key]=value;return true
  end
  local function play(handle)assert(not handle.stopped);count('play');handle.playing=true;return true end
  local function stop(handle)
    assert(not handle.stopped);count('stop');handle.stopped=true;handle.playing=false
    if state.bound==handle then state.bound=nil end
  end
  local r={
    APIExists=function(name)
      if name=='AM_Preview_CreateWithChannelSelection'then return mode=='selection' end
      if name=='AM_Preview_CreateWithChannels'then return modern end
      if name=='AM_Preview_CreateWithDownmix'then return modes end
      return native and ({AM_Preview_Create=true,AM_Preview_SetWaveform=true,
        AM_Preview_SetLatencyTrack=true,AM_WaveCursorState=true})[name]==true
    end,
    ValidatePtr2=function(p,t,kind)return p==project and t==track and kind=='MediaTrack*'end,
    PCM_Source_CreateFromFile=function()count('file');return source('file')end,
    PCM_Source_CreateFromType=function(kind)assert(kind=='SECTION');count('section');return source('section')end,
    PCM_Source_Destroy=function(value)
      assert(value and not value.destroyed,'PCM source released twice');count('destroy');value.destroyed=true
    end,
    GetMediaSourceNumChannels=function(value)assert(not value.destroyed);count('channels');return value.channels end,
    GetMediaSourceLength=function(value)assert(not value.destroyed);count('length');return value.length,false end,
    CF_PCM_Source_SetSectionInfo=function(section,value,a,length)
      assert(not value.destroyed and not section.destroyed);count('configure');section.length=length;return true
    end,
    AM_Preview_Create=function(value,p,t)assert(native and p==project and t==track);count('am');return create(value)end,
    AM_Preview_CreateWithChannelSelection=function(value,p,t,left,right)
      assert(mode=='selection' and left>=1 and right>=1 and left<=value.channels and right<=value.channels)
      local h=create(value,true);h.left=left;h.right=right;return h
    end,
    AM_Preview_CreateWithChannels=function(value,p,t,downmix)
      assert(modern and p==project and t==track and type(downmix)=='boolean')
      count('multi');return create(value,downmix)
    end,
    AM_Preview_CreateWithDownmix=function(value,p,t,downmix_mode)
      assert(modes and p==project and t==track and (downmix_mode==0 or downmix_mode==1 or downmix_mode==2))
      count('mix');local handle=create(value,downmix_mode~=0);handle.downmix_mode=downmix_mode;return handle
    end,
    CF_CreatePreview=function(value)assert(not native);count('cf');return create(value)end,
    CF_Preview_SetOutputTrack=function(_,p,t)assert(p==project and t==track);count('output');return true end,
    AM_Preview_GetValue=get,CF_Preview_GetValue=get,
    AM_Preview_SetValue=set,CF_Preview_SetValue=set,
    AM_Preview_Play=play,CF_Preview_Play=play,AM_Preview_Stop=stop,CF_Preview_Stop=stop,
    AM_Preview_SetWaveform=function()count('wave');return true end,
    AM_Preview_SetLatencyTrack=function(_,t)assert(t==fx);count('latency');return true end,
    AM_Preview_BindControls=function(handle)count('bind');state.bound=handle end,
  }
  local preview=Preview.new(r,project,track);preview:latency_track(fx)
  return preview,state
end

local cases={
  {name='Raw'},
  {name='rate',rate=.5},
  {name='pitch',pitch_semitones=7},
  {name='preserve pitch',rate=2,preserve_pitch=true},
  {name='reverse',reverse=true},
  {name='range',range={2,8}},
  {name='combined transforms and range',rate=.5,pitch_semitones=-7,preserve_pitch=true,reverse=true,range={2,8}},
}
for _,mode in ipairs{'legacy','SWS','modern','ambix'}do
  local native=mode~='SWS';local modern=mode=='modern' or mode=='ambix' or mode=='selection';local modes=mode=='ambix'
  for _,case in ipairs(cases)do
    local preview,state=fixture(mode)
    local definition=Model.defaults();local macro=Model.effective(definition,nil)
    for _,key in ipairs{'rate','pitch_semitones','preserve_pitch','reverse'}do
      if case[key]~=nil then macro.source_transform[key]=case[key]end
    end
    local settings=definition.settings
    local context=mode..' '..case.name
    local function reject_all()
      for _,channels in ipairs(modern and {129,256} or {3,4,6,8,64,128,129})do
        state.channels=channels
        local counts=U.copy(state.counts);local bound=state.bound
        local handle,path,saved_macro,range=preview.handle,preview.path,preview.macro,preview.range
        local starts,length,gain,ended,eof=preview.starts,preview.source_length,preview.gain_db,preview.ended_path,preview.eof_path
        local saved_source,saved_output=preview.source_channels,preview.output_channels
        local ok,started,err=pcall(preview.start,preview,'/multichannel.wav',macro,6,settings,case.range,.5)
        local reason=channels>128 and 'up to 128' or 'updated native helper'
        assert(ok and started==false and tostring(err):find(reason,1,true),context..' '..channels..'ch: unexpected result '..tostring(err))
        for key,before in pairs(counts)do
          local increment=(key=='file' or key=='channels' or key=='destroy')and 1 or 0
          assert(state.counts[key]==before+increment,context..' '..channels..'ch unexpectedly called '..key)
        end
        assert(preview.handle==handle and preview.path==path and preview.macro==saved_macro and preview.range==range)
        assert(preview.starts==starts and preview.source_length==length and preview.gain_db==gain)
        assert(preview.ended_path==ended and preview.eof_path==eof and state.bound==bound)
        assert(preview.source_channels==saved_source and preview.output_channels==saved_output)
        assert(not handle or (handle.playing and not handle.stopped),context..': rejected replacement stopped existing playback')
        for _,value in ipairs(state.sources)do assert(value.destroyed,context..': PCM source leaked')end
      end
    end
    -- A rejection before any playback must preserve completion bookmarks too.
    preview.ended_path='/completed.wav';preview.eof_path=preview.ended_path
    reject_all()
    local starts=0
    for _,channels in ipairs(modern and {1,2,3,4,6,8,64,128} or {1,2})do
      for _,downmix in ipairs{false,true}do
      settings.preview_downmix=downmix
      state.channels=channels
      local counts=U.copy(state.counts);local old=preview.handle
      assert(preview:start('/supported-'..channels..'.wav',macro,0,settings,case.range,.5))
      starts=starts+1
      assert(preview.handle and preview.handle.channels==channels and preview:playing())
      assert(preview.source_channels==channels and preview.output_channels==(channels>2 and not downmix and channels or 2))
      assert(preview.handle.output_channels==preview.output_channels)
      if channels>2 then assert(preview.handle.downmix==downmix)end
      assert(preview.starts==starts and not preview.ended_path and not preview.eof_path)
      assert(state.counts.play==counts.play+1 and state.counts.stop==counts.stop+(old and 1 or 0))
      assert(not old or old.stopped)
      local section=macro.source_transform.reverse or case.range
      assert(state.counts.section==counts.section+(section and 1 or 0))
      assert(state.counts.destroy==counts.destroy+(section and 2 or 1))
      assert(state.counts.am==counts.am+(native and channels<=2 and 1 or 0) and state.counts.cf==counts.cf+(native and 0 or 1))
      assert(state.counts.multi==counts.multi+(modern and not modes and channels>2 and 1 or 0))
      assert(state.counts.mix==counts.mix+(modes and channels>2 and 1 or 0))
      assert(state.counts.output==counts.output+(native and 0 or 1))
      assert(not native or state.bound==preview.handle)
      local values=preview.handle.values;local transform=macro.source_transform
      assert(values.D_PLAYRATE==transform.rate and values.D_PITCH==transform.pitch_semitones)
      assert(values.B_PPITCH==(transform.preserve_pitch and 1 or 0) and values.D_POSITION==.5)
      assert(preview.source_length==10 and preview.handle.length==(case.range and 6 or 10))
      reject_all()
      end
    end
    preview:stop();assert(not preview.handle and not state.bound)
    for _,value in ipairs(state.sources)do assert(value.destroyed,context..': PCM source leaked')end
  end
end

-- Re-resolve each selected filename, independently of the prior live handle.
-- The decoder choice must survive all existing section/transform paths.
for _,case in ipairs(cases)do
  local preview,state=fixture('ambix')
  local settings=Model.defaults().settings;settings.preview_downmix=true
  local macro=Model.macro('test','Test')
  for _,key in ipairs{'rate','pitch_semitones','preserve_pitch','reverse'}do
    if case[key]~=nil then macro.source_transform[key]=case[key]end
  end
  for _,channels in ipairs{4,9,16,64,121}do
    state.channels=channels
    for _,entry in ipairs{{'/library/field_AMBIX.wav','auto',2},{'/library/field.wav','auto',1},
      {'/Ambix/field.wav','auto',1},{'/field_Ambix.wav','discrete',1},{'/field.wav','ambix',2}}do
      settings.preview_downmix_mode=entry[2]
      assert(preview:start(entry[1],macro,0,settings,case.range,.5))
      assert(preview.downmix_mode==entry[3] and preview.handle.downmix_mode==entry[3])
      assert(preview.output_channels==2 and preview.source_channels==channels)
    end
  end
  local function rejected(path,channels,preference,reason)
    state.channels=channels;settings.preview_downmix_mode=preference
    local handle,starts,counts=preview.handle,preview.starts,U.copy(state.counts)
    local ok,error=preview:start(path,macro,0,settings,case.range,.5)
    assert(ok==false and error:find(reason,1,true))
    assert(preview.handle==handle and handle.playing and not handle.stopped and preview.starts==starts)
    for key,before in pairs(counts)do
      assert(state.counts[key]==before+((key=='file' or key=='channels' or key=='destroy')and 1 or 0),
        'Rejected AmbiX replacement changed '..key)
    end
  end
  for _,channels in ipairs{3,5,6,8,15,128}do rejected('/field_Ambix.wav',channels,'ambix','full 3D')end
  -- A selected manual mode never affects unprocessed playback.
  state.channels=6;settings.preview_downmix=false;settings.preview_downmix_mode='ambix'
  assert(preview:start('/field_Ambix.wav',macro,0,settings,case.range,.5))
  assert(preview.downmix_mode==0 and preview.handle.downmix_mode==0 and preview.output_channels==6)
  preview:stop()
  for _,source in ipairs(state.sources)do assert(source.destroyed)end
end

-- An older multichannel helper must not substitute its discrete decoder for
-- an AmbiX request, while legacy discrete and unchanged mono/stereo work.
do
  local preview,state=fixture('modern');state.channels=4
  local settings=Model.defaults().settings;settings.preview_downmix=true
  local macro=Model.macro('test','Test')
  assert(preview:start('/discrete.wav',macro,0,settings))
  local handle=preview.handle;local counts=U.copy(state.counts)
  local ok,reason=preview:start('/field_Ambix.wav',macro,0,settings)
  assert(ok==false and reason:find('AmbiX',1,true)and reason:find('updated native helper',1,true))
  assert(preview.handle==handle and not handle.stopped and state.counts.multi==counts.multi)
  assert(state.counts.destroy==counts.destroy+1 and state.counts.length==counts.length)
  settings.preview_downmix_mode='ambix';state.channels=2
  assert(preview:start('/field_Ambix.wav',macro,0,settings))
  assert(preview.downmix_mode==0 and preview.source_channels==2 and preview.output_channels==2)
  preview:stop()
end

for _,case in ipairs(cases)do
  local preview,state=fixture('selection')
  local settings=Model.defaults().settings;local macro=Model.macro('test','Test')
  for key,value in pairs(case)do if macro.source_transform[key]~=nil then macro.source_transform[key]=value end end
  settings.preview_downmix=true;settings.preview_downmix_mode='ambix'
  for _,channels in ipairs{1,2,6,128}do
    state.channels=channels;settings.channel_selections={[tostring(channels)]={left=channels,right=1}}
    assert(preview:start('/selected.wav',macro,0,settings,case.range,.5))
    assert(preview.handle.left==channels and preview.handle.right==1 and preview.output_channels==2 and preview.downmix_mode==0)
    assert(preview.channel_selection.left==channels)
    settings.channel_selections[tostring(channels)].left=1
    assert(preview.channel_selection.left==channels,'Live preview route changed without rebuilding its source')
  end
  preview:stop();for _,source in ipairs(state.sources)do assert(source.destroyed)end
end
-- Old helper rejection must preserve the currently playing source.
do
  local preview,state=fixture('modern');state.channels=6
  local settings=Model.defaults().settings;local macro=Model.macro('test','Test')
  assert(preview:start('/six.wav',macro,0,settings))
  local handle=preview.handle
  settings.channel_selections={['6']={left=6,right=3}}
  local started,reason=preview:start('/six.wav',macro,0,settings)
  assert(started==false and reason:find('updated native helper',1,true) and preview.handle==handle and not handle.stopped)
  preview:stop()
end
