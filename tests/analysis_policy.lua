local A=require('am.analysis_policy');local L=require('am.loudness');local U=require('am.util');local J=require('am.json')
local Model=require('am.model')
for _,channels in ipairs{1,2}do
  for _,enabled in ipairs{false,true}do
    local spec,reason=A.resolve('/test.wav',channels,{preview_downmix=enabled,preview_downmix_mode='ambix'})
    assert(spec==nil and reason==nil,'Mono/stereo analysis policy must remain legacy')
  end
end
for _,channels in ipairs{3,4,6,9,16,64,121,128}do
  local spec=A.resolve('/test.wav',channels,{preview_downmix=false,preview_downmix_mode='discrete'})
  assert(A.valid(spec) and spec.basis=='loudest_channel' and spec.source_channels==channels)
  assert(A.label(spec)=='loudest channel')
  spec=A.resolve('/test.wav',channels,{preview_downmix=true,preview_downmix_mode='discrete'})
  assert(spec.basis=='downmix_discrete'and A.label(spec)=='stereo downmix')
end
for _,channels in ipairs{4,9,16,25,36,49,64,81,100,121}do
  for _,preference in ipairs{'auto','ambix'}do
    local settings={preview_downmix_mode=preference,preview_downmix=true}
    local spec=A.resolve('/field_AMBIX.wav',channels,settings);assert(spec.basis=='downmix_ambix')
    settings.preview_downmix=false;spec=A.resolve('/field_AMBIX.wav',channels,settings)
    assert(spec.basis=='ambix_w'and A.label(spec)=='AmbiX W')
  end
  assert(A.resolve('/generic.wav',channels,{preview_downmix_mode='ambix'}).basis=='ambix_w')
end
for _,path in ipairs{'/ambix/field.wav','fieldambix.wav','field_Ambisonics.wav','field_B-format.wav'}do
  assert(A.resolve(path,4,{}).basis=='loudest_channel')
end
for _,channels in ipairs{3,6,128}do
  local spec,reason=A.resolve('/field_ambix.wav',channels,{preview_downmix=true,preview_downmix_mode='ambix'})
  assert(spec==nil and reason:find('full 3D',1,true))
  assert(A.resolve('/field_ambix.wav',channels,{preview_downmix=false,preview_downmix_mode='ambix'}).basis=='loudest_channel',
    'Original-channel analysis must not require an AmbiX decoder')
end
for _,count in ipairs{0,-1,3.5,129,144,math.huge,0/0}do
  local spec,reason=A.resolve('/test.wav',count,{});assert(not spec and reason)
end
local discrete=A.resolve('/test.wav',4,{preview_downmix=true})
local ambix=A.resolve('/field_ambix.wav',4,{preview_downmix=true})
local original=A.resolve('/test.wav',4,{})
local w=A.resolve('/field_ambix.wav',4,{})
assert(A.label(nil)=='source'and A.same(nil,nil)and not A.same(nil,original))
assert(A.same(discrete,U.copy(discrete))and not A.same(discrete,ambix))
for _,invalid in ipairs{{},J.null,{revision=2,source_channels=4,basis='ambix_w'},
  {revision=1,source_channels=6,basis='ambix_w'},{revision=1,source_channels=4,basis='unknown'},
  {revision=1,source_channels=4,basis='ambix_w',unexpected=true},'ambix',false}do
  assert(not A.valid(invalid)and not A.same(invalid,invalid))
  assert(not pcall(L.key,{path='/test.wav'},'analyzer',invalid))
end
local identity={path='/test.wav',size=100,mtime=10}
local keys={}
for _,spec in ipairs{discrete,ambix,original,w}do
  local key=L.key(identity,'analyzer',spec);assert(not keys[key]);keys[key]=true
  assert(L.profile(spec)==L.MULTICHANNEL_PROFILE)
  local value={status='ready',identity=U.copy(identity),analyzer_key='analyzer',profile=L.profile(spec),analysis=U.copy(spec),
    channels=4,duration=10,max_momentary_lufs=-24,true_peak_dbtp=-12}
  assert(L.matches_measurement(value,identity,'analyzer',spec))
  assert(not L.matches_measurement(value,identity,'analyzer'))
  for _,other in ipairs{discrete,ambix,original,w}do
    assert(L.matches_measurement(value,identity,'analyzer',other)==A.same(spec,other))
  end
  value.channels=2;assert(not L.matches_measurement(value,identity,'analyzer',spec));value.channels=4
  value.profile=L.PROFILE;assert(not L.matches_measurement(value,identity,'analyzer',spec));value.profile=L.profile(spec)
  value.analysis.extra=true;assert(not L.matches_measurement(value,identity,'analyzer',spec))
end
assert(L.key(identity,'analyzer')==U.hash(J.encode(identity)..'analyzer'..L.PROFILE),'Legacy cache identity changed')
assert(not keys[L.key(identity,'analyzer')])
assert(L.profile(nil)==L.PROFILE)
local legacy={status='silence',identity=identity,analyzer_key='analyzer',profile=L.PROFILE,channels=2,
  duration=10,max_momentary_lufs=J.null,true_peak_dbtp=J.null}
assert(L.matches_measurement(legacy,identity,'analyzer'))
assert(not L.matches_measurement(legacy,identity,'analyzer',original))

-- Silent W/loudness does not imply that directional channels have no peaks.
local value={status='silence',identity=identity,analyzer_key='analyzer',profile=L.profile(w),analysis=w,channels=4,
  duration=10,max_momentary_lufs=J.null,true_peak_dbtp=3}
assert(L.matches_measurement(value,identity,'analyzer',w))
local macro=Model.macro('test','Test');macro.normalization.enabled=true
assert(L.gain(macro,value)==-4,'A silent reference must still protect peaks on the other channels')
macro.source_peak_guard.enabled=true
local gain,reason=L.gain(macro,value);assert(gain==-4 and reason=='source peak capped')
value.true_peak_dbtp=-12;gain,reason=L.gain(macro,value);assert(gain==0 and reason=='silence')
value.true_peak_dbtp=J.null;assert(L.gain(macro,value)==0)
value.true_peak_dbtp=0/0;assert(not L.matches_measurement(value,identity,'analyzer',w))
