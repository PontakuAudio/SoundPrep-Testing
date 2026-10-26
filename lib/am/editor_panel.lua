-- Native Presets / Tools controller. Both hosts send the same typed events.
local J=require('am.json');local U=require('am.util');local Model=require('am.model');local Chunk=require('am.chunk')
local M={}
local fields={
  name={'name','string'},reverse={'source_transform','reverse','boolean'},pitch={'source_transform','pitch_semitones',-24,24},
  rate={'source_transform','rate',.1,4},preserve={'source_transform','preserve_pitch','boolean'},
  normalize={'normalization','enabled','boolean'},metric={'normalization','metric','metric'},
  lufs={'normalization','target_lufs',-60,0},sones={'normalization','target_sones',.01,256},
  reference_dbfs={'normalization','reference_dbfs',-120,0},reference_spl={'normalization','reference_spl_db',0,140},
  boost={'normalization','max_boost_db',0,24},gain={'output_gain_db',-60,12},
  guard={'source_peak_guard','enabled','boolean'},ceiling={'source_peak_guard','ceiling_dbtp',-12,0},
  tail={'export','tail_seconds',0,30},final={'export','normalize_final','boolean'},
  limiter={'export','true_peak_limit','boolean'},export_ceiling={'export','ceiling_dbtp',-12,0}}
local raw_allowed={normalize=true,metric=true,lufs=true,sones=true,reference_dbfs=true,reference_spl=true,boost=true,guard=true,ceiling=true,preserve=true,reverse=true}
local function location(m,spec)
  if type(m[spec[1]])=='table'then return m[spec[1]],spec[2],3 end
  return m,spec[1],2
end
function M.open(a,page)
  a.editor_panel_open=true;a.editor_panel_focus=(a.editor_panel_focus or 0)+1;a.editor_page=page or -1
end
function M.state(a)
  if not a.editor_panel_open then return nil end
  a:stash_preset()
  local id=a.selected_id or 'raw';local draft=a:preset_draft(id);local values={}
  for key,spec in pairs(fields)do local target,field=location(draft,spec);values[key]=target[field]end
  if id=='raw'then local t=a:effective().source_transform;values.preserve=t.preserve_pitch;values.reverse=t.reverse end
  values.directory=a.export_dir or '';values.slot=0
  for slot,assigned in pairs(a.definition.slots)do if assigned==id then values.slot=tonumber(slot)end end
  local now=a.r.time_precise()
  if a.editor_checked_id~=id or not a.editor_checked_at or now-a.editor_checked_at>.5 then
    a.editor_checked_id=id;a.editor_checked_at=now;a.editor_fx_changed=false
    if id~='raw'then
      local ok,changed=pcall(function()return Chunk.portable(a.bank:chain(id))~=Chunk.portable(assert(U.read(a.data..'/'..draft.fx_chain)))end)
      a.editor_fx_changed=not ok or changed
    end
  end
  local presets=J.array{{id='raw',label='Raw'}}
  for _,m in ipairs(a.definition.macros)do presets[#presets+1]={id=m.id,label=a:preset_draft(m.id).name}end
  local measured=a:measurement();local gain,status=a:gain();local measurement='Loudness: '..tostring(status)
  if measured and measured.status=='ready'then
    if draft.normalization.metric~='lufs_m_max' and measured.zwicker_sones then
      measurement=('Source: %.2f sones (Zwicker %s) · %.1f dBTP · Gain: %+.1f dB (%s)'):format(measured.zwicker_sones,draft.normalization.metric=='zwicker_p95' and 'P95' or 'Max',measured.true_peak_dbtp,gain,status)
    else measurement=('Source: %.1f LUFS-M max · %.1f dBTP · Gain: %+.1f dB (%s)'):format(measured.max_momentary_lufs,measured.true_peak_dbtp,gain,status)end
  elseif a.loudness.active then measurement='Analysing in background…'end
  if a.loudness.error then measurement=measurement..'\n'..a.loudness.error end
  if a.preview:playing() and a.preview.gain_target~=nil then measurement=measurement..('\nApplying Normalize: %+.1f → %+.1f dB'):format(a.preview.gain_db,a.preview.gain_target)end
  return {open=true,focus=a.editor_panel_focus or 0,page=a.editor_page or 0,id=id,presets=presets,values=values,
    dirty=not U.equal(draft,Model.editable(a.definition,id)) or a.editor_fx_changed,
    deleting=a.editor_delete_id==id,playing=a.preview:playing()==true,source=a.path and U.basename(a.path)or 'Select a file in Media Explorer',
    measurement=measurement,notice=a.editor_notice or a.message or ''}
end
local function dispatch(a,command)
  if command=='editor:close'then a.editor_panel_open=false;a.editor_delete_id=nil;return end
  local e=J.decode(command:sub(8));assert(type(e)=='table','Invalid editor event')
  local id=a.selected_id or 'raw'
  -- A queued edit from an old selection must never modify the newly active preset.
  assert(e.id==id,'Preset changed; edit was not applied')
  if e.op=='set'then
    local key,value=e.key,e.value
    if key=='directory'then
      assert(type(value)=='string' and #value<=4096 and not value:find('%z'),'Invalid export directory');a.export_dir=value;return
    end
    if key=='slot'then assert(id~='raw' and U.finite(value)and value%1==0 and value>=0 and value<=9,'Invalid action slot');a:slot(id,value);return end
    local spec=assert(fields[key],'Unknown preset setting')
    assert(id~='raw' or raw_allowed[key],'Raw does not save this setting')
    a:stash_preset();local draft=U.copy(a:preset_draft(id));local target,field,index=location(draft,spec)
    local kind=spec[index]
    if kind=='boolean'then assert(type(value)=='boolean','Expected a checkbox value')
    elseif kind=='string'then assert(type(value)=='string' and #value>0 and #value<=128 and utf8.len(value)and not value:find('[%z\1-\31]'),'Name must be 1–128 UTF-8 bytes')
    elseif kind=='metric'then assert(value=='lufs_m_max' or value=='zwicker_max' or value=='zwicker_p95','Invalid loudness meter')
    else assert(U.finite(value)and value>=kind and value<=spec[index+1],'Value outside allowed range')end
    if key=='preserve' and id=='raw'then a:set_preserve_pitch(value);return end
    if key=='reverse' and id=='raw'then if a:effective().source_transform.reverse~=value then a:reverse()end;return end
    target[field]=value
    -- Validate before audition_edit stores the draft, so failures leave it intact.
    local candidate=U.copy(a.definition)
    if id=='raw'then candidate.raw={normalization=U.copy(draft.normalization),source_peak_guard=U.copy(draft.source_peak_guard)}
    else local _,i=Model.find(candidate,id);candidate.macros[i]=draft end
    Model.validate(candidate);a:audition_edit(draft)
  elseif e.op=='select'then
    assert(e.value=='raw' or Model.find(a.definition,e.value),'Unknown preset');a:activate(e.value~='raw' and e.value or nil);a.editor_delete_id=nil
  elseif e.op=='save'then a:save_preset(id);a.editor_checked_at=nil
  elseif e.op=='revert'then a:revert_preset(id);a.editor_checked_at=nil
  elseif e.op=='fx'then assert(id~='raw');a.bank:edit(id)
  elseif e.op=='new'then a:new_macro();a.editor_delete_id=nil
  elseif e.op=='duplicate'then assert(id~='raw');a:new_macro(id);a.editor_delete_id=nil
  elseif e.op=='up' or e.op=='down'then assert(id~='raw');a:move(id,e.op=='up' and -1 or 1)
  elseif e.op=='import'then
    assert(id~='raw');local ok,path=a.r.GetUserFileNameForRead('','Import FX chain','.RfxChain')
    if ok then a:import_chain(id,path);a.editor_checked_at=nil end
  elseif e.op=='delete'then assert(id~='raw');a.editor_delete_id=id
  elseif e.op=='cancel_delete'then a.editor_delete_id=nil
  elseif e.op=='confirm_delete'then assert(id~='raw' and a.editor_delete_id==id,'Select Delete preset first');a:delete(id);a.editor_delete_id=nil
  elseif e.op=='play'then a:transport()
  elseif e.op=='replay'then a:play()
  elseif e.op=='ab'then a:ab()
  elseif e.op=='focus'then a.explorer:focus_list()
  elseif e.op=='analyse'then a:analyse(true)
  elseif e.op=='render' or e.op=='render_dialog'then a:export(e.op=='render_dialog')
  elseif e.op=='render_drops'then a:render_drops()
  elseif e.op=='directory_choose'then
    local result,path=a.r.JS_Dialog_BrowseForFolder('SoundPrep — Export folder',a.export_dir or '')
    if result==1 then a.export_dir=path end
  else error('Unknown editor action')end
end
function M.dispatch(a,command)
  local previous_notice=a.editor_notice
  local ok,err=pcall(dispatch,a,command)
  if not ok then a.editor_notice=tostring(err);a.message=a.editor_notice;error(err,0)end
  if a.message==previous_notice then a.message=''end
  a.editor_notice=nil
end
return M
