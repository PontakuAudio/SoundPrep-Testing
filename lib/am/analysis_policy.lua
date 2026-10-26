-- A source measurement is meaningful only for the channel interpretation that
-- produced it. These immutable descriptors also separate cache/job identities.
local U=require('am.util');local Mix=require('am.channel_mix')
local Selection=require('am.channel_selection')
local M={}
local bases={downmix_discrete=true,downmix_ambix=true,loudest_channel=true,ambix_w=true}
function M.valid_meter(meter)
  if type(meter)~='table' or (meter.metric~='zwicker_max' and meter.metric~='zwicker_p95')then return false end
  for key in pairs(meter)do
    if key~='metric' and key~='target_sones' and key~='reference_dbfs' and key~='reference_spl_db'then return false end
  end
  return U.finite(meter.target_sones)and meter.target_sones>=.01 and meter.target_sones<=256 and
    U.finite(meter.reference_dbfs)and meter.reference_dbfs>=-120 and meter.reference_dbfs<=0 and
    U.finite(meter.reference_spl_db)and meter.reference_spl_db>=0 and meter.reference_spl_db<=140
end
function M.meter(normalization,include_disabled)
  if not normalization or normalization.metric=='lufs_m_max' or normalization.enabled==false and not include_disabled then return end
  return {metric=normalization.metric,target_sones=normalization.target_sones or require('am.model').DEFAULT_TARGET_SONES,
    reference_dbfs=normalization.reference_dbfs or -20,reference_spl_db=normalization.reference_spl_db or 79}
end
-- Every Zwicker job also measures LUFS and true peak before solving its target.
-- Those measurements depend on the channel mapping, not the target/calibration.
function M.without_meter(spec)
  assert(spec==nil or M.valid(spec),'Invalid source analysis policy')
  if not spec or not spec.meter then return U.copy(spec)end
  if spec.revision==2 and spec.source_channels<=2 then return nil end
  local base=U.copy(spec);base.meter=nil
  if base.revision==2 then base.revision=1 end
  return base
end
function M.valid(spec)
  if type(spec)=='table' and (spec.revision==3 or spec.revision==4)then
    if (spec.revision==4)~=(type(spec.selection)=='table' and spec.selection.channels~=nil)or spec.basis~='selected_channels' or not Selection.valid(spec.source_channels,spec.selection)or
      (spec.meter~=nil and not M.valid_meter(spec.meter))then return false end
    for key in pairs(spec)do
      if key~='revision' and key~='basis' and key~='source_channels' and key~='selection' and key~='meter'then return false end
    end
    return true
  end
  if type(spec)~='table' or (spec.revision~=1 and spec.revision~=2)or not U.finite(spec.source_channels) or
    spec.source_channels%1~=0 or spec.source_channels<1 or spec.source_channels>128 then return false end
  if spec.revision==1 then
    if spec.source_channels<3 or not bases[spec.basis]then return false end
  elseif not M.valid_meter(spec.meter)or (spec.source_channels<=2 and spec.basis~='source')or
    (spec.source_channels>2 and not bases[spec.basis])then return false end
  for key in pairs(spec)do
    if key~='revision' and key~='source_channels' and key~='basis'and not(spec.revision==2 and key=='meter')then return false end
  end
  return (spec.basis~='downmix_ambix' and spec.basis~='ambix_w')or Mix.valid_channels(spec.source_channels)
end
function M.same(a,b)
  if a==nil or b==nil then return a==nil and b==nil end
  return M.valid(a) and M.valid(b) and U.equal(a,b)
end
function M.label(spec)
  if spec==nil then return 'source' end
  assert(M.valid(spec),'Invalid source analysis policy')
  if spec.basis=='selected_channels'then return Selection.label(spec.selection)end
  return spec.basis=='source' and 'source' or spec.basis=='ambix_w' and 'AmbiX W' or spec.basis=='loudest_channel' and 'loudest channel' or 'stereo downmix'
end
function M.resolve(path,channels,settings,normalization,include_disabled)
  if not U.finite(channels) or channels%1~=0 or channels<1 or channels>128 then
    return nil,'Analysis requires an audio source with 1–128 channels.'
  end
  local meter=M.meter(normalization,include_disabled)
  if meter and not M.valid_meter(meter)then return nil,'Invalid Zwicker target or calibration.'end
  local selection=Selection.get(settings,channels)
  if selection then
    if not Selection.valid(channels,selection)then return nil,'Invalid input channel selection.'end
    return {revision=selection.channels and 4 or 3,source_channels=channels,basis='selected_channels',selection=U.copy(selection),meter=meter}
  end
  if channels<=2 then return meter and {revision=2,source_channels=channels,basis='source',meter=meter}or nil end
  settings=settings or {}
  local preference=settings.preview_downmix_mode or 'auto';local basis
  if settings.preview_downmix then
    local mode,reason=Mix.resolve(path,channels,preference)
    if not mode then return nil,reason end
    basis=mode==2 and 'downmix_ambix' or 'downmix_discrete'
  else
    if preference~='auto' and preference~='discrete' and preference~='ambix'then
      return nil,'Unknown preview downmix mode.'
    end
    -- Original-channel playback needs no decoder: an incompatible saved
    -- AmbiX preference must not prevent OFF from measuring discrete channels.
    local ambix=preference=='ambix' and Mix.valid_channels(channels) or
      preference=='auto' and Mix.detected(path,channels)
    basis=ambix and 'ambix_w' or 'loudest_channel'
  end
  return {revision=meter and 2 or 1,source_channels=channels,basis=basis,meter=meter}
end
return M
