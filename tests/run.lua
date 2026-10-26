package.path='./lib/?.lua;'..package.path
local count=0
local function test(name,fn)
  local ok,e=xpcall(fn,debug.traceback)
  if not ok then io.stderr:write('FAIL ',name,'\n',e,'\n');os.exit(1)end
  count=count+1;print('ok '..name)
end
test('Selected microphones preserve routing, analysis identities, transport and frozen render recipes',function()dofile('tests/channel_selection.lua')end)
test('Native microphone panel preserves names, source identity and independent selections',function()dofile('tests/channel_panel.lua')end)
test('WAV microphone names preserve iXML track positions, Unicode, fallbacks and file identity',function()dofile('tests/channel_names.lua')end)
test('Native app settings persist shared values and preserve modeless panel state',function()dofile('tests/settings_panel.lua')end)
test('Native Presets and Tools preserve drafts, validate edits and guard stale events',function()dofile('tests/editor_panel.lua')end)
local J=require('am.json');local M=require('am.model');local U=require('am.util')
test('Cache folder selection persists, validates writes and preserves running analysis',function()dofile('tests/cache_directory.lua')end)
test('SoundPrep and legacy action paths share commands, heartbeat and preserved shortcuts',function()dofile('tests/entrypoint_compatibility.lua')end)
test('Native helper compatibility is checked by features on both OSes before project changes',function()dofile('tests/native.lua')end)
test('Withdrawn dictionary assistance leaves startup and native search untouched',function()dofile('tests/search_omission.lua')end)
test('Media Explorer display preferences survive selection, failures, close and legacy recovery',function()dofile('tests/media_explorer.lua')end)
test('AmbiX filename detection and selectable stereo preview preserve explicit channel choices',function()dofile('tests/ambix.lua')end)
test('Multichannel analysis policies separate loudness references and preserve silent-source peak protection',function()dofile('tests/analysis_policy.lua')end)
test('Analysis dependencies reuse source meters and avoid Zwicker work for peak protection alone',function()dofile('tests/analysis_dependencies.lua')end)
test('Native Zwicker jobs freeze calibrated targets and apply validated solver gain with shared caps',function()dofile('tests/zwicker.lua')end)
test('Analysis progress and failures remain visible after a rejected normalized drop',function()dofile('tests/analysis_status.lua')end)
test('Fast drops await frozen analysis, survive selection changes and protect edits, Undo and failures',function()dofile('tests/drop_analysis.lua')end)
test('Normalized drops consume completed analysis without a companion poll and reject incomplete batches',function()dofile('tests/normalized_drop.lua')end)
test('Multichannel drops freeze mapping and preserve analysis policy per file',function()dofile('tests/multichannel_drop.lua')end)
test('Drop channel processing keeps frozen recipes and edited FX without double mixing',function()dofile('tests/render_channels.lua')end)
test('Multichannel Source + FX and rendered takes preserve frozen channels and edited processing',function()dofile('tests/multichannel_insert.lua')end)
test('Multichannel preview bypasses Macro FX while preserving gain, selection and keep-running preference',function()dofile('tests/multichannel_preview.lua')end)
test('Live preview gain transitions preserve playback and bound changes across edits and UI stalls',function()dofile('tests/preview_gain.lua')end)
test('Completed source analysis applies normalization during playback without replay or stale-source gain',function()dofile('tests/live_normalization.lua')end)
test('WAV channel trimming preserves samples and metadata with bounded buffers',function()dofile('tests/wave_channels.lua')end)
test('JSON round trip, Unicode, empty array and sorted keys',function()
  local v=J.decode('{"b":[],"a":"\\uD83D\\uDD09 日本語 \\n", "n":null,"f":false}')
  assert(v.a=='🔉 日本語 \n' and v.f==false and v.n==J.null)
  assert(J.encode(v):find('"b": %[%]'));assert(J.encode(J.decode(J.encode(v)))==J.encode(v))
  local copy=U.copy(v);assert(copy~=v and copy.n==J.null and copy.b~=v.b)
  assert(J.encode(copy)==J.encode(v),'Snapshot copies must retain JSON null and empty arrays')
end)
test('Malformed JSON fails closed',function()
  for _,s in ipairs{'[1,]','{"a":1,"a":2}','01','1.','1.e1','1e400','"\\uD800"','"\1"','true false'}do assert(not pcall(J.decode,s),s)end
end)
test('JSON encoding rejects sparse arrays without silently discarding later values',function()
  -- JSON arrays contain a value at every position (use explicit null for gaps).
  -- Lua's length boundary varies with allocation, so test several capacities.
  for length=3,16 do
    local sparse=J.array{};for i=1,length do sparse[i]=i end;sparse[2]=nil
    assert(not pcall(J.encode,sparse),'Sparse array silently lost trailing values at capacity '..length)
    sparse[2]=J.null
    local decoded=J.decode(J.encode(sparse))
    assert(#decoded==length and decoded[2]==J.null and decoded[length]==length)
  end
end)
test('Bank schema keeps Raw FX-free with independent normalization',function()
  local b=M.validate(M.defaults());b.macros[1].normalization.enabled=true
  local raw=M.effective(b,nil);assert(not raw.fx_chain and not raw.normalization.enabled and raw.source_transform.rate==1 and not raw.source_transform.reverse)
  b.raw.normalization.enabled=true;b.raw.normalization.target_lufs=-12
  raw=M.effective(b,nil);assert(raw.normalization.enabled and raw.normalization.target_lufs==-12 and not raw.fx_chain)
  assert(b.macros[1].normalization.target_lufs==-18)
  b.raw=nil;M.validate(b);assert(not b.raw.normalization.enabled,'Old banks must not gain normalization implicitly')
  local x=M.effective(b,'heavy',true);assert(x.source_transform.reverse and not b.macros[1].source_transform.reverse)
  b.macros[1].fx_chain='../danger.RfxChain';assert(not pcall(M.validate,b))
end)
test('Unsupported schema and stale shortcut are rejected',function()
  local b=M.defaults();b.schema_version=2;assert(not pcall(M.validate,b))
  b=M.defaults();b.slots['1']='missing';assert(not pcall(M.validate,b))
end)
test('Calibrated factory loudness targets retain explicitly saved presets and old targets',function()
  local b=M.defaults()
  for _,m in ipairs{M.effective(b,nil),M.effective(b,'heavy'),M.macro('new','New')}do
    assert(m.normalization.target_lufs==-18 and m.normalization.target_sones==36)
    assert(m.normalization.reference_dbfs==-20 and m.normalization.reference_spl_db==79)
    assert(m.source_peak_guard.ceiling_dbtp==-1 and not m.normalization.enabled)
  end
  b.raw.normalization.target_lufs=-16;b.raw.normalization.target_sones=8
  b.macros[1].normalization.target_lufs=-15;b.macros[1].normalization.target_sones=12
  b=M.validate(J.decode(J.encode(b)))
  assert(b.raw.normalization.target_lufs==-16 and b.raw.normalization.target_sones==8)
  assert(b.macros[1].normalization.target_lufs==-15 and b.macros[1].normalization.target_sones==12)
end)
local Chunk=require('am.chunk');local L=require('am.loudness')
test('Nested FX chain round trip preserves plugin state',function()
  local chain='SHOW -1\nBYPASS 0 0 0\n<CONTAINER Container ""\n<JS test\n1 2 3\n>\n>\nFXID {old}\nWAK 0 0\n'
  local track='<TRACK\nNAME "test"\n>\n'
  local inserted=Chunk.replace(track,chain)
  local body=Chunk.chain_body(assert(Chunk.block(inserted,'FXCHAIN')))
  assert(body:find('<JS test\n1 2 3\n>',1,true))
  local fresh=Chunk.fresh(body,function()return '{new}'end)
  assert(fresh:find('FXID {new}',1,true))
  assert(not Chunk.portable(fresh):find('FXID',1,true))
  local takefx='<TAKEFX\n'..chain..'>\n'
  assert(Chunk.portable(takefx)==Chunk.portable(chain),'Take FX must remain executable when copied to a render track')
  assert(not Chunk.replace(track,takefx):find('<TAKEFX',1,true),'Take FX must not be nested inside FXCHAIN')
  assert(not pcall(Chunk.replace,track,'>\n<TRACK\n'))
  local replaced=Chunk.replace(inserted,'SHOW -1\n');assert(not replaced:find('<JS',1,true))
  assert(Chunk.fresh('BYPASS 0 0 0\n<JS test\n0\n>\n',function()return '{new}'end):match('^SHOW %-1\n'),'Minimal FX chains must load without opening an editor')
end)
test('Normalize constraints and silent/unmeasured fallback',function()
  local m=M.macro('x','x');m.normalization.enabled=true;m.normalization.target_lufs=-12
  assert(L.gain(m,nil)==0)
  local measurement={status='ready',max_momentary_lufs=-40,true_peak_dbtp=-10}
  assert(L.gain(m,measurement)==9,'Normalize must respect source peaks without an optional guard')
  m.source_peak_guard.enabled=true;assert(L.gain(m,measurement)==9)
  assert(L.gain(m,{status='silence'})==0)
end)
test('Default and saved Raw/Macro Normalize cannot boost past the source ceiling',function()
  local Policy=require('am.analysis_policy')
  -- Round-trip the old schema: guard=false must not restore unsafe boosts.
  local bank=M.validate(J.decode(J.encode(M.defaults())))
  for _,id in ipairs{'raw','heavy'}do
    local m=M.effective(bank,id~='raw' and id or nil)
    m.normalization.enabled=true
    assert(not m.source_peak_guard.enabled)
    for _,metric in ipairs{'lufs_m_max','zwicker_max','zwicker_p95'}do
      m.normalization.metric=metric
      local measurement={status='ready',max_momentary_lufs=-40,true_peak_dbtp=-.25,
        normalization_gain_db=24,gain_status='ready',analysis=Policy.resolve('/impulse.wav',2,{},m.normalization)}
      local gain,reason=L.gain(m,measurement)
      assert(gain==-.75 and reason=='source peak capped',id..' / '..metric..' exceeded its source ceiling')
      measurement.true_peak_dbtp=-40
      gain,reason=L.gain(m,measurement);assert(gain==18 and reason=='boost capped')
      measurement.true_peak_dbtp=2.5
      assert(L.gain(m,measurement)==-3.5,'Float sources above full scale need attenuation')
      m.source_peak_guard.ceiling_dbtp=-3
      assert(L.gain(m,measurement)==-5.5,'Normalize ignored the saved ceiling')
      m.source_peak_guard.ceiling_dbtp=-1
      for _,peak in ipairs{J.null,0/0,math.huge,-math.huge}do
        measurement.true_peak_dbtp=peak;gain,reason=L.gain(m,measurement)
        assert(gain==0 and reason=='invalid','An invalid peak allowed normalization gain')
      end
      measurement.true_peak_dbtp=nil;gain,reason=L.gain(m,measurement)
      assert(gain==0 and reason=='invalid','A missing peak allowed normalization gain')
    end
    m.normalization.enabled=false
    local gain,reason=L.gain(m,{status='ready',max_momentary_lufs=-40,true_peak_dbtp=3})
    assert(gain==0 and reason=='off','Disabled normalization and guard must retain unity gain')
  end
end)
test('Cache identities include modification and analyzer profile',function()
  local a={path='/test.wav',size=10,mtime=1};local b=U.copy(a)
  assert(L.same(a,b));b.mtime=2;assert(not L.same(a,b));assert(L.key(a,'x')~=L.key(b,'x'))
  assert(L.key(a,'x')~=L.key(a,'y'))
end)
local Insert=require('am.insert')
local Time=require('am.timeline')
test('Source bookmarks survive rate, reverse, selected ranges and end boundaries',function()
  local range={2,8};local forward={rate=.5,reverse=false};local reverse={rate=2,reverse=true}
  local source=Time.source(4,10,range,forward);assert(source==4)
  assert(Time.position(source,10,range,reverse)==2)
  assert(Time.source(2,10,range,reverse)==source)
  assert(Time.position(20,10,range,forward)<12)
  assert(Time.position(-1,10,range,forward)==0)
end)
test('Processed handles map source ranges through rate and reverse',function()
  local t={rate=.5,reverse=false}
  local a=Insert.layout(10,{2,5},t,true)
  assert(a.offset==4 and a.duration==6 and a.source_duration==20 and a.render_range==J.null)
  t.reverse=true;a=Insert.layout(10,{2,5},t,true)
  assert(a.offset==10 and a.duration==6)
  a=Insert.layout(10,{2,5},t,false)
  assert(a.offset==0 and a.duration==6 and a.source_duration==6 and a.render_range[1]==2)
  a=Insert.layout(10,nil,t,true);assert(a.offset==0 and a.duration==20)
  for _,range in ipairs{{-1,2},{4,4},{3,11},{0,0/0}}do assert(not pcall(Insert.layout,10,range,t,true))end
end)
test('Prepared recipes reuse full handles and invalidate crop, FX, transform and source changes',function()
  local s={path='/test.wav',identity={path='/test.wav',size=10,mtime=1},macro=M.macro('test','Test'),
    range={1,3},source_gain_db=0,fade_ms=5,chain='SHOW -1\n',created_at='first'}
  local function key(snapshot,handles)return select(3,Insert.recipe(snapshot,10,handles))end
  local full,crop=key(s,true),key(s,false)
  s.created_at='second';assert(key(s,true)==full)
  s.range={2,5};assert(key(s,true)==full and key(s,false)~=crop)
  for _,change in ipairs{
    function(x)x.chain=x.chain..'BYPASS 1 0 0\n'end,
    function(x)x.macro.source_transform.reverse=true end,
    function(x)x.identity.mtime=2 end,
    function(x)x.source_gain_db=3 end,
  }do local x=U.copy(s);change(x);assert(key(x,true)~=full)end
end)
test('Drop cache invalidates when the project default pitch algorithm changes',function()
  local pitch=589824
  local r={EnumProjects=function()return {}end,CountTempoTimeSigMarkers=function()return 0 end,
    Master_GetTempo=function()return 120 end,GetSetProjectInfo=function(_,key)return key=='PROJECT_SRATE'and 48000 or 1 end,
    SNM_GetIntConfigVar=function(key)
      assert(key=='defpitchcfg' or key=='projrenderresample','Unknown render preference')
      return key=='defpitchcfg'and pitch or 3
    end}
  local s={path='/test.wav',macro=M.macro('test','Test'),chain='',range=J.null}
  local render=require('am.render_item');render.stamp(r,s)
  local key=select(3,Insert.recipe(s,10,true));pitch=65;render.stamp(r,s)
  assert(key~=select(3,Insert.recipe(s,10,true)),'Changed pitch algorithm reused stale rendered media')
end)
test('Existing banks migrate to full handles, invalid settings are rejected',function()
  local b=M.defaults();b.settings.insert_handles=nil;assert(M.validate(b).settings.insert_handles)
  b.settings.insert_handles=false;assert(not M.validate(b).settings.insert_handles)
  b.settings.insert_handles='false';assert(not pcall(M.validate,b))
  b=M.defaults();b.settings.prepare_drops=nil;assert(M.validate(b).settings.prepare_drops==false)
  b.settings.prepare_drops='true';assert(not pcall(M.validate,b))
  b=M.defaults();b.settings.auto_render_drops=nil;assert(M.validate(b).settings.auto_render_drops)
  b.settings.auto_render_drops=false;assert(not M.validate(b).settings.auto_render_drops)
  b.settings.auto_render_drops='true';assert(not pcall(M.validate,b))
  b=M.defaults();b.settings.preview_fade_ms=nil;b.settings.fade_ms=17
  assert(M.validate(b).settings.preview_fade_ms==0 and b.settings.fade_ms==17)
end)
test('Warm switching changes only two branches and reconciles bypass policy',function()
  local writes=0
  local r={ValidatePtr=function()return true end,ValidatePtr2=function(_,t)return t.valid~=false end,
    TrackFX_GetCount=function()return 0 end,
    SetMediaTrackInfo_Value=function(t,k,v)t[k]=v;writes=writes+1 end}
  local b=setmetatable({r=r,project={},input={},raw={},macros={},switches=0,
    definition={settings={keep_fx_running=false,monitor_gain_db=-6}}},require('am.bank'))
  for i=1,9 do b.macros[tostring(i)]={} end
  b:activate('1');writes=0;b:activate('2')
  assert(writes==5 and b.macros['1'].B_MAINSEND==0 and b.macros['1'].I_FXEN==0)
  assert(b.macros['1'].D_VOL>0) -- No fader ramp through zero on a later switch.
  assert(b.macros['2'].D_VOL>0 and b.macros['2'].I_FXEN==1)
  writes=0;b:activate('2');assert(writes==0)
  b.definition.settings.keep_fx_running=true;b:activate('2')
  for _,t in pairs(b.macros)do assert(t.I_FXEN==1)end
  writes=0;b:activate(nil);assert(writes==3 and b.raw.D_VOL>0 and b.macros['2'].B_MAINSEND==0)
  b.routing_dirty=true;b.macros['3'].B_MAINSEND=1;b:activate(nil);assert(b.macros['3'].B_MAINSEND==0)
end)
test('Deleted and failed Macro tracks release ownership and bounded PDC state',function()dofile('tests/bank_lifecycle.lua')end)
test('Preview channel routing preserves all owned branches without changing the Master or reloading FX',function()dofile('tests/bank_channels.lua')end)
test('Export and insertion release unassigned PCM sources on every reported allocation failure',function()dofile('tests/source_ownership.lua')end)
test('Live PDC stays out of saved/rendered chains without touching plugin payload',function()
  local C=require('am.chunk')
  local body='SHOW -1\nPDC_OPTIONS 3\n<JS test\nPDC_OPTIONS 42\n>\n'
  assert(C.pdc_options(body)=='PDC_OPTIONS 3')
  local live=C.pdc_options(body,'PDC_OPTIONS 2',true)
  assert(C.pdc_options(live)=='PDC_OPTIONS 2')
  assert(C.pdc_options(live,'PDC_OPTIONS 3',true)==body:gsub('SHOW %-1\nPDC_OPTIONS 3\n','PDC_OPTIONS 3\nSHOW -1\n'))
  local cleared=C.pdc_options(live,false,true)
  assert(not C.pdc_options(cleared) and cleared:find('PDC_OPTIONS 42',1,true))
end)
test('Loudness cache misses are not repeatedly read and completion replaces them',function()
  local reads=0;local original=U.read;U.read=function()reads=reads+1;return nil end
  local cache=setmetatable({data='/unused',memory={},keys=setmetatable({},{__mode='k'}),analyzer_key='test'},L)
  local id={path='/test.wav',size=1,mtime=1}
  for _=1,100 do assert(cache:get(id)==nil)end
  assert(reads==1)
  local value={status='ready',max_momentary_lufs=-16,true_peak_dbtp=-3,duration=1,channels=1,
    identity=id,profile=L.PROFILE,analyzer_key='test'}
  cache.memory[L.key(id,'test')]=value;assert(cache:get(id)==value)
  id=U.copy(id);id.mtime=2;assert(cache:get(id)==nil and reads==2)
  local collision=L.key(id,'test');cache.memory[collision]=value
  assert(cache:get(id)==nil,'A colliding hash must not use another identity\'s loudness')
  U.read=original
end)
test('Loudness cancellation, launch failures and bounded polling',function()dofile('tests/loudness.lua')end)
test('Windows paths, executable discovery and worker argument quoting',function()dofile('tests/platform.lua')end)
test('Drop peak generation is batched, scoped and preserves selection on failure',function()
  local a,b,other={},{},{};local selected={other};local calls,writes=0,0
  local r={ValidatePtr2=function(_,item)return item~=nil end,
    CountSelectedMediaItems=function()return #selected end,GetSelectedMediaItem=function(_,i)return selected[i+1]end,
    SetMediaItemSelected=function(item,on)
      writes=writes+1
      for i,v in ipairs(selected)do if v==item then table.remove(selected,i);break end end
      if on then selected[#selected+1]=item end
    end,UpdateArrange=function()end}
  r.Main_OnCommandEx=function(id,_,project)
    assert(id==40245 and project=='project','Must only build missing peaks in the target project')
    assert(#selected==2 and selected[1]==a and selected[2]==b,'Unrelated media was included')
    calls=calls+1
  end
  Insert.build_missing_peaks(r,'project',{a,b})
  assert(calls==1 and #selected==1 and selected[1]==other)
  selected={a,b};writes=0;Insert.build_missing_peaks(r,'project',{a,b});assert(calls==2 and writes==0)
  selected={other};r.Main_OnCommandEx=function()error('fixture failure')end
  assert(not pcall(Insert.build_missing_peaks,r,'project',{a,b}))
  assert(#selected==1 and selected[1]==other,'Selection lost on failed peak request')
  writes=0;Insert.build_missing_peaks(r,'project',{});assert(writes==0)
end)
test('Waveform drop uses the frozen source range, while list insertion stays full length',function()
  local Range=require('am.drop_range')
  local r={MediaExplorerGetLastPlayedFileInfo=function()return true,'/source.wav',0,0,1 end}
  local ctx={origin='waveform',preview={path='/source.wav',mode=256,start=.2,['end']=.7}}
  local range=Range.read(r,ctx,'/source.wav',10);assert(range[1]==2 and range[2]==7)
  ctx.preview.mode=128;range=Range.read(r,ctx,'/source.wav',10);assert(range[1]==2 and range[2]==7)
  ctx.origin='list';assert(Range.read(r,ctx,'/source.wav',10)==nil)
  ctx.origin='waveform';ctx.preview.path='/another.wav';assert(not pcall(Range.read,r,ctx,'/source.wav',10))
  ctx.preview=nil;assert(Range.read(r,ctx,'/source.wav',10)==nil)
end)
test('Windows waveform bookmarks accept path aliases and skip an already-applied native seek',function()
  local event={path='c:/素材/FOO.wav',fraction=.4,applied=true,sequence=9}
  local seeks,plays=0,0
  local app=setmetatable({r={GetOS=function()return 'Win64'end},path=[[C:\素材\foo.wav]],
    explorer={wave_event=function()return event end},
    preview={path=[[C:\素材\foo.wav]],source_length=10,native=true,
      playing=function()return true end,get=function()return true,9 end,
      seek_source=function(_,at)assert(at==4);seeks=seeks+1;return true end},
    sync_range=function()return false end},require('am.app'))
  app:sync_wave();assert(app.last_seek.source==4 and seeks==0)
  event.applied=false;app:sync_wave();assert(seeks==1)
  app.sync_range=function(self)self.range={2,8};return true end
  app.effective=function()return {source_transform={rate=.5,reverse=true}}end
  app.play=function(_,at)assert(at==0);plays=plays+1 end
  app:sync_wave();assert(plays==1 and seeks==1)
  app.preview.playing=function()return false end
  app:sync_wave();assert(plays==2,'Stopped range gesture did not start at the section head')
  app.sync_range=function()return false end
  app:sync_wave();assert(app.paused_source==4 and plays==2)
  event.path='C:/another.wav';app.explorer.selection=function()return [[c:\ANOTHER.wav]]end
  app:sync_wave();assert(app.pending_wave==event)
end)
test('Native seek-step size uses client pixels independently of scrollbar units',function()
  local r={JS_Window_GetScrollInfo=function()return true,400,800,0,1600 end,
    JS_Window_GetClientSize=function()return true,800,100 end}
  local explorer=setmetatable({r=r,control=function()return {}end},require('am.media_explorer'))
  assert(explorer:seek_step(12)==.0375)
end)
test('Deferred drops preserve item edits, skip removed items and roll back failed renders',function()dofile('tests/drop_pending.lua')end)
test('Raw and Item Volume drops preserve native items; signal processing alone renders or defers',function()dofile('tests/drop_playback.lua')end)
test('Range audition and completed-drop transport regressions',function()dofile('tests/audition_gestures.lua')end)
test('Native launcher keeps panels and edits across drag waits and closes on startup failure',function()dofile('tests/launcher_lifecycle.lua')end)
test('Single-entry ZIP setup waits for restart and never replaces an existing helper',function()dofile('tests/setup.lua')end)
test('Project closure stops before stale track access and preserves saved FX without false warnings',function()dofile('tests/project_lifecycle.lua')end)
test('Waveform clicks replay after EOF but preserve explicit Stop/Pause',function()dofile('tests/preview_eof.lua')end)
test('Native multichannel preview supports downmix and original channels; older helpers fail without stopping playback',function()dofile('tests/preview_channels.lua')end)
test('Downmix preserves source position, stopped bookmarks, settings, and multichannel analysis boundaries',function()dofile('tests/downmix.lua')end)
test('Preserve Pitch defaults off; explicitly saved Macro choices survive',function()
  local bank=M.defaults()
  assert(not M.effective(bank,nil).source_transform.preserve_pitch)
  assert(not M.macro('new','New').source_transform.preserve_pitch)
  for _,macro in ipairs(bank.macros)do assert(not macro.source_transform.preserve_pitch)end
  bank.macros[1].source_transform.preserve_pitch=true
  assert(M.effective(M.validate(bank),bank.macros[1].id).source_transform.preserve_pitch)
end)
test('Preserve Pitch toggle updates native controls and preset drafts without baking tempo match',function()
  local reflected,refreshes=nil,0
  local app=setmetatable({definition=M.defaults(),selected_id='heavy',tempo_factor=1.5,
    explorer={set_transform=function(_,t)reflected=U.copy(t)end},
    bank={activate=function()end},preview={latency_track=function()end},
    refresh_processing=function()refreshes=refreshes+1 end},require('am.app'))
  local bar=setmetatable({app=app,r={EnumProjects=function()return nil end}},require('am.bar'))
  bar:dispatch('preserve_pitch')
  assert(app:effective().source_transform.preserve_pitch and reflected.preserve_pitch)
  assert(math.abs(reflected.rate-.72)<1e-10 and math.abs(app:preset_draft('heavy').source_transform.rate-.72)<1e-10)
  assert(app:preset_draft('heavy').source_transform.preserve_pitch)
  assert(not M.find(app.definition,'heavy').source_transform.preserve_pitch,'Toggle prematurely saved a draft')
  app:activate('dark');assert(not app:effective().source_transform.preserve_pitch)
  app:activate('heavy');assert(app:effective().source_transform.preserve_pitch,'Switch lost Preserve Pitch draft')
  bar:dispatch('preserve_pitch');assert(not app:effective().source_transform.preserve_pitch and not reflected.preserve_pitch)
  app:activate(nil);bar:dispatch('preserve_pitch')
  assert(app:effective().source_transform.preserve_pitch and reflected.preserve_pitch,'Raw toggle is unavailable')
  app:activate('dark');app:activate(nil)
  assert(not app:effective().source_transform.preserve_pitch,'Raw must return to its default OFF')
  assert(refreshes>=4)
end)
test('File changes clear every FX branch while retaining settings, routing and normal playback fades',function()dofile('tests/source_buffers.lua')end)
test('Drop peak building yields, reuses existing peaks and never changes Timeline selection',function()dofile('tests/peaks.lua')end)
test('Inactive drop FX stay offline with editors open and restore audible sources by ownership',function()dofile('tests/take_fx.lua')end)
print(('Passed %d tests'):format(count))
