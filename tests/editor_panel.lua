local Editor=require('am.editor_panel');local App=require('am.app');local Model=require('am.model');local J=require('am.json');local U=require('am.util');local Bar=require('am.bar')
local project={};local active=project;local calls={};local clock=0
local a=setmetatable({definition=Model.defaults(),project=project,selected_id='heavy',message='',data='/unused',export_dir='/tmp/export',tempo_factor=1,
  r={time_precise=function()return clock end,EnumProjects=function()return active end},loudness={},
  bank={activate=function()end,chain=function()return 'SHOW -1\n'end},preview={playing=function()return false end,latency_track=function()end},
  explorer={set_transform=function()end,focus_list=function()calls.focus=true end},refresh_processing=function()end,
  measurement=function()return nil end,gain=function()return 0,'off'end},App)
local bar=Bar.new(a.r,a)
local function event(op,key,value,id)bar:dispatch('editor@'..J.encode{op=op,key=key,value=value,id=id or a.selected_id or 'raw'})end
bar:dispatch('edit');local state=Editor.state(a);assert(state.open and state.page==-1 and state.id=='heavy')
bar:dispatch('edit');assert(Editor.state(a).focus==2)
local original=U.copy(a.definition)
event('set','name','マイク 🎤 Test');event('set','pitch',-7.5);event('set','rate',.63);event('set','preserve',true)
event('set','gain',-3);event('set','normalize',true);event('set','metric','zwicker_p95');event('set','sones',12.5)
event('set','reference_dbfs',-18);event('set','reference_spl',83);event('set','guard',true);event('set','ceiling',-2)
event('set','tail',2.5);event('set','final',true);event('set','limiter',true);event('set','export_ceiling',-1.5)
state=Editor.state(a);assert(state.dirty and state.values.name=='マイク 🎤 Test' and state.values.rate==.63 and state.values.preserve)
assert(U.equal(a.definition,original),'Native editing prematurely saved the bank')
local draft=J.encode(a:preset_draft('heavy'))
for _,bad in ipairs{{'name',''},{'name',string.rep('a',129)},{'name','x\ny'},{'pitch',25},{'rate',0},{'preserve',1},{'metric','bogus'},{'sones',0},{'gain',13},{'unknown',1},{'slot',1.5},{'directory',false}}do
  assert(not pcall(event,'set',bad[1],bad[2]));assert(J.encode(a:preset_draft('heavy'))==draft,'Invalid input poisoned the draft')
end
assert(not pcall(event,'set','gain',-12,'dark'));assert(J.encode(a:preset_draft('heavy'))==draft)
event('select',nil,'dark');assert(a.selected_id=='dark');event('select',nil,'heavy');assert(a:effective().name=='マイク 🎤 Test'and a:effective().source_transform.rate==.63)
bar:dispatch('editor:close');assert(not Editor.state(a));bar:dispatch('target:custom');assert(Editor.state(a).page==1 and a:effective().output_gain_db==-3)
-- Folder selection is cancelled without mutating the draft or starting a render.
a.r.JS_Dialog_BrowseForFolder=function()return 0,''end;event('directory_choose');assert(a.export_dir=='/tmp/export')
a.r.JS_Dialog_BrowseForFolder=function()return 1,'C:\\素材\\exports'end;event('directory_choose');assert(a.export_dir=='C:\\素材\\exports')
event('set','directory','/tmp/素材');assert(a.export_dir=='/tmp/素材')
a.r.GetUserFileNameForRead=function()return true,'/tmp/test.RfxChain'end
a.import_chain=function(_,id,path)assert(id=='heavy' and path=='/tmp/test.RfxChain');calls.import=true end
a.bank.edit=function(_,id)assert(id=='heavy');calls.fx=true end
a.save_preset=function(_,id)assert(id=='heavy');calls.save=true end
a.revert_preset=function(_,id)assert(id=='heavy');calls.revert=true end
a.new_macro=function(_,id)calls[id and 'duplicate' or 'new']=true end
a.move=function(_,id,delta)assert(id=='heavy');calls[delta<0 and 'up' or 'down']=true end
a.slot=function(_,id,value)assert(id=='heavy' and value==5);calls.slot=true end
a.export=function(_,dialog)calls[dialog and 'render_dialog' or 'render']=true end
for _,op in ipairs{'transport','play','ab','analyse','render_drops'}do a[op]=function()calls[op]=true end end
for _,op in ipairs{'save','revert','fx','import','new','duplicate','up','down','render','render_dialog','play','replay','ab','analyse','render_drops','focus'}do event(op)end
event('set','slot',5)
for _,op in ipairs{'save','revert','fx','import','new','duplicate','up','down','slot','render','render_dialog','transport','play','ab','analyse','render_drops','focus'}do assert(calls[op],op)end
assert(not pcall(event,'confirm_delete'));event('delete');assert(Editor.state(a).deleting);event('cancel_delete');assert(not Editor.state(a).deleting)
event('delete');event('select',nil,'dark');assert(not Editor.state(a).deleting);assert(not pcall(event,'confirm_delete'))
event('select',nil,'heavy');event('delete');a.delete=function(_,id)assert(id=='heavy');calls.delete=true end;event('confirm_delete');assert(calls.delete)
-- Project mismatch blocks editing but closing still works.
active={};local before=J.encode(a:preset_draft('heavy'));event('set','gain',-9);assert(before==J.encode(a:preset_draft('heavy')))
bar:dispatch('editor:close');assert(not Editor.state(a));active=project
-- Raw only saves normalization/guard. Preserve Pitch stays a temporary transform.
a.ab=App.ab;event('select',nil,'raw');Editor.open(a);event('set','normalize',true);event('set','preserve',true)
assert(a:effective().source_transform.preserve_pitch and a:preset_draft('raw').normalization.enabled)
assert(not pcall(event,'set','name','Renamed raw') and not pcall(event,'set','gain',-3))
event('set','reverse',true);assert(a:effective().source_transform.reverse and not a:preset_draft('raw').source_transform.reverse)
assert(a.definition.raw.normalization.enabled==false)
-- Snapshot used by both native control tests; keep it typed exactly as the controller publishes.
local fixture=J.decode(assert(U.read('tests/native-editor-state.json')))
assert(fixture.id=='heavy' and fixture.values.rate==.72)
