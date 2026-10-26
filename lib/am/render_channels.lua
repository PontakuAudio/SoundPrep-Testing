-- Frozen channel routing shared by editable drops and offline renders.
local Selection=require('am.channel_selection');local U=require('am.util');local C=require('am.chunk');local Mix=require('am.channel_mix')
local M={effect='AuditionMacro/channels_v1',selection_effect='AuditionMacro/channels_v2',subset_effect='AuditionMacro/channels_v3'}
local module_path=debug.getinfo(1,'S').source:sub(2):gsub('\\','/')
local root=assert(module_path:match('^(.*)/lib/am/render_channels%.lua$'),'Cannot locate channel processor')
local function integer(n,a,b)return U.finite(n) and n%1==0 and n>=a and n<=b end
function M.validate(snapshot)
  local mix=snapshot.channel_mix;if mix==nil then return end
  local selected=type(mix)=='table' and (mix.revision==2 or mix.revision==3 or mix.revision==4) and mix.mode==3 and Selection.valid(mix.source_channels,mix.selection) and (mix.revision==4)==(mix.selection.channels~=nil)
  assert(type(mix)=='table' and (selected or mix.revision==1 and integer(mix.source_channels,3,128)) and
    integer(mix.mode,0,selected and 3 or 2) and integer(mix.fx_channels,2,128) and mix.fx_channels%2==0,
    'Invalid frozen drop channel routing')
  assert(mix.output_channels==(selected and Selection.output(mix.selection)or mix.mode==0 and mix.source_channels or 2),'Invalid drop output channels')
  assert(mix.mode~=2 or Mix.valid_channels(mix.source_channels),'Invalid AmbiX drop channel count')
  assert(mix.chain_applied==nil or type(mix.chain_applied)=='boolean','Invalid drop FX routing state')
  return mix
end
function M.output(snapshot)
  local mix=M.validate(snapshot);return mix and mix.output_channels or 2
end
function M.take_mode(snapshot)
  local mix=M.validate(snapshot)
  return mix and (mix.revision==3 or mix.revision==4)and Selection.take_mode(mix.selection) or 0
end
function M.width(snapshot)
  local mix=M.validate(snapshot)
  return mix and math.max(M.take_mode(snapshot)>0 and 2 or math.ceil(mix.source_channels/2)*2,mix.fx_channels) or 2
end
function M.ensure(r,selected)
  local version=selected=='v3' and 'v3' or selected and 'v2' or 'v1'
  local contents=assert(U.read(root..'/resources/audition_macro_channels_'..version..'.jsfx'),'Channel processor is missing from SoundPrep')
  local directory=r.GetResourcePath()..'/Effects/AuditionMacro'
  local path=directory..'/channels_'..version;local existing=U.read(path)
  if existing then
    assert(existing==contents,'Installed SoundPrep channels_'..version..' differs from the bundled processor')
  else
    r.RecursiveCreateDirectory(directory,0)
    assert(U.write(path,contents),'Cannot install SoundPrep channel processor')
  end
  return version=='v3' and M.subset_effect or selected and M.selection_effect or M.effect
end
local function effect(r,mode,channels,gain,label,selection)
  if selection then
    local list=Selection.list(selection)
    if #list>2 then
      local masks={0,0,0,0}
      for _,ch in ipairs(list)do local group=math.floor((ch-1)/32)+1;masks[group]=masks[group]+2^((ch-1)%32)end
      return ('\nBYPASS 0 0 0\n<JS %s "%s"\n%.0f %.0f %.0f %.0f\n>\nFXID %s\nWAK 0 0\n')
        :format(M.ensure(r,'v3'),label,masks[1],masks[2],masks[3],masks[4],r.genGuid())
    end
    return ('\nBYPASS 0 0 0\n<JS %s "%s"\n%d %d %.17g %d %d\n>\nFXID %s\nWAK 0 0\n')
      :format(M.ensure(r,true),label,mode,channels,gain,list[1],list[2]or list[1],r.genGuid())
  end
  return ('\nBYPASS 0 0 0\n<JS %s "%s"\n%d %d %.17g\n>\nFXID %s\nWAK 0 0\n')
    :format(M.ensure(r),label,mode,channels,gain,r.genGuid())
end
function M.chain(r,snapshot,post_gain)
  local mix=M.validate(snapshot);local chain=C.chain_body(snapshot.chain)
  if mix and mix.mode>0 and not mix.chain_applied and M.take_mode(snapshot)==0 then
    chain=effect(r,mix.mode,mix.source_channels,0,mix.selection and 'Macro Input Channels' or 'Macro Channel Mix',mix.selection)..chain
  elseif mix and mix.chain_applied then
    if chain:find(M.effect,1,true)then M.ensure(r)end
    if chain:find(M.selection_effect,1,true)then M.ensure(r,true)end
    if chain:find(M.subset_effect,1,true)then M.ensure(r,'v3')end
  end
  local gain=snapshot.macro.output_gain_db
  if post_gain and (gain~=0 or mix and not mix.chain_applied and (M.take_mode(snapshot)==0 or mix.fx_channels>2)) then
    if mix then chain=chain..effect(r,0,mix.output_channels,gain,'Macro Output Channels / Gain')
    else
      chain=chain..('\nBYPASS 0 0 0\n<JS utility/volume_pan "Macro Output Gain"\n%.17g 0 0\n>\nFXID %s\nWAK 0 0\n'):format(gain,r.genGuid())
    end
  end
  return chain
end
function M.widen(r,track,snapshot)
  local mix=M.validate(snapshot);if not mix then return end
  local width=math.ceil(mix.output_channels/2)*2
  if r.GetMediaTrackInfo_Value(track,'I_NCHAN')<width then r.SetMediaTrackInfo_Value(track,'I_NCHAN',width)end
end
return M
