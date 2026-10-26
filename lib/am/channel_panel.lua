-- Shared state for the native Media Explorer microphone panel and waveform.
local J=require('am.json');local Names=require('am.channel_names');local Selection=require('am.channel_selection');local U=require('am.util')
local M={}
function M.names(app)
  app.channel_name_cache=app.channel_name_cache or {}
  return Names.cached(app.channel_name_cache,app.path,app.source_channels or 0,app.identity)
end
local function display(name)
  if not name then return ''end
  local stop=utf8.offset(name,513)
  return stop and name:sub(1,stop-1)..'…'or name
end
function M.labels(app)
  local names=M.names(app);local count=app.source_channels or 0
  if count<1 or count>128 then count=0 end
  local cached=app.channel_labels
  if not cached or cached.names~=names or cached.count~=count then
    local labels=J.array{};local named=false
    for ch=1,count do labels[ch]=display(names[ch]);named=named or labels[ch]~=''end
    cached={names=names,count=count,labels=labels,json=J.encode(labels),named=named};app.channel_labels=cached
  end
  return cached.labels,cached.json,cached.named
end
function M.state(app)
  local count=app.source_channels or 0
  if count<1 or count>128 then count=0 end
  local selected=Selection.get(app.definition.settings,count);local list=selected and Selection.list(selected)or {}
  local key=(app.path or '')..':'..count
  if app.channel_panel_source~=key then app.channel_panel_source=key;app.channel_panel_page=math.floor(((list[1]or 1)-1)/8)end
  local page=math.max(0,math.min(math.max(0,math.ceil(count/8)-1),app.channel_panel_page or 0));app.channel_panel_page=page
  local active={};for _,ch in ipairs(list)do active[ch]=true end
  local names=M.names(app);local items=J.array{}
  for ch=page*8+1,math.min(count,(page+1)*8)do
    local name=display(names[ch]);items[#items+1]={channel=ch,name=name,selected=active[ch]==true}
  end
  local downmix=not selected and count>2 and app.definition.settings.preview_downmix==true
  return {open=app.channel_panel_open==true,source=key,file=app.path and U.basename(app.path)or 'Select an audio file in Media Explorer.',
    summary=selected and Selection.label(selected)or downmix and 'Downmix all channels'or 'All source channels',
    items=items,previous=page>0,next=(page+1)*8<count,all=not selected and not downmix,downmix=downmix,
    can_downmix=count>2,can_swap=#list==2,enabled=count>0,playing=app.preview:playing()==true,
    page=count>0 and ('%d–%d / %d'):format(page*8+1,math.min(count,(page+1)*8),count)or '',notice=app.channel_panel_notice or ''}
end
function M.toggle(app,channel)
  local count=app.source_channels or 0
  assert(Selection.valid(count,{channels={channel}}),'Invalid microphone channel')
  local selected=Selection.get(app.definition.settings,count);local list=selected and Selection.list(selected)or {}
  local found;for i,ch in ipairs(list)do if ch==channel then found=i;break end end
  if found then
    if #list==1 then return false,'Keep at least one microphone selected, or choose All channels.'end
    table.remove(list,found)
  else list[#list+1]=channel end
  table.sort(list);return app:set_channel_selection(list)
end
function M.dispatch(app,text)
  if text=='channels:close'then app.channel_panel_open=false;return end
  if text=='channels'then app.channel_panel_open=not app.channel_panel_open;app.channel_panel_notice=nil;return end
  local event=J.decode(text:sub(10));assert(type(event)=='table','Invalid microphone command')
  -- A queued click must not select a mic in a newly selected recording.
  if event.source~=(app.path or '')..':'..(app.source_channels or 0)then return end
  local op=event.op;local ok,reason=true
  if op=='toggle'then ok,reason=M.toggle(app,event.channel)
  elseif op=='all'then ok,reason=app:set_downmix(false)
  elseif op=='downmix'then ok,reason=app:set_downmix(true)
  elseif op=='swap'then
    local s=Selection.get(app.definition.settings,app.source_channels);local list=s and Selection.list(s)or {}
    if #list==2 then ok,reason=app:set_channel_selection({list[2],list[1]})end
  elseif op=='previous'then app.channel_panel_page=math.max(0,(app.channel_panel_page or 0)-1)
  elseif op=='next'then app.channel_panel_page=(app.channel_panel_page or 0)+1
  elseif op=='play'then app:transport()
  elseif op=='replay'then app:play()
  else error('Unknown microphone command')end
  app.channel_panel_notice=ok==false and reason or nil
end
return M
