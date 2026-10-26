local Settings=require('am.settings_panel');local Model=require('am.model');local J=require('am.json');local U=require('am.util');local Bar=require('am.bar')
local time,saves,activations=0,0,0;local project={};local loop,playingLoop,rendered,chosen
local a={definition=Model.defaults(),project=project,data='/tmp/test',message='',selected_id='heavy',
  r={time_precise=function()return time end},bank={activate=function()activations=activations+1 end},
  preview={playing=function()return true end,set=function(_,key,value)assert(key=='B_LOOP');playingLoop=value end},
  explorer={toggle=function(_,id,value)assert(id==1068);loop=value end},
  effective=function()return {output_gain_db=3}end,save_settings=function(self)saves=saves+1;self.saved=J.decode(J.encode(self.definition.settings))end,
  render_drops=function()rendered=true end}
local bar=Bar.new({EnumProjects=function()return project end},a)
local function set(key,value,commit)bar:dispatch('settings@'..J.encode{op='set',key=key,value=value,commit=commit})end
bar:dispatch('settings');assert(Settings.state(a).open and Settings.state(a).focus==1)
bar:dispatch('settings');assert(Settings.state(a).open and Settings.state(a).focus==2,'Repeated open must focus, not dismiss')
local original=U.copy(a.definition.macros)
set('loop',true);assert(loop and playingLoop==1 and a.saved.loop)
set('monitor_gain_db',-15,false);assert(activations==1 and a.definition.settings.monitor_gain_db==-15 and saves==1)
time=.1;set('monitor_gain_db',-14,false);Settings.tick(a);assert(saves==1)
time=.4;Settings.tick(a);assert(saves==2 and a.saved.monitor_gain_db==-14)
set('preview_fade_ms',12.5);set('fade_ms',6.2);set('autoplay',false)
assert(a.saved.preview_fade_ms==12.5 and a.saved.fade_ms==6.2 and not a.saved.autoplay)
set('keep_fx_running',true);assert(activations==3 and a.saved.keep_fx_running)
assert(U.equal(a.definition.macros,original),'App settings changed a preset')
for _,pair in ipairs{{'monitor_gain_db',1},{'monitor_gain_db',-61},{'fade_ms',51},{'fade_ms','4'},{'autoplay',1},{'unknown',false}}do
  local before=J.encode(a.definition);assert(not pcall(set,pair[1],pair[2]));assert(before==J.encode(a.definition))
end
local save=a.save_settings;a.save_settings=function()error('disk full')end
assert(not pcall(set,'loop',false));assert(a.definition.settings.loop and loop and playingLoop==1 and a.settings_notice:find('disk full'))
a.save_settings=save
set('monitor_gain_db',-20,false);bar:dispatch('settings:close');assert(not Settings.state(a).open and a.saved.monitor_gain_db==-20)
bar:dispatch('settings');project={};local before=saves
set('autoplay',true);assert(saves==before and not a.definition.settings.autoplay,'Paused project accepted a change')
bar:dispatch('settings:close');assert(not Settings.state(a).open,'Paused panel cannot close')
project=a.project;bar:dispatch('settings@'..J.encode{op='render_drops'});assert(rendered)
assert(not Settings.state(a).cache_available)
a.choose_cache_directory=function()chosen=true end;a.set_cache_directory=function(_,path)assert(path=='');chosen='default' end
assert(Settings.state(a).cache_available)
bar:dispatch('settings@'..J.encode{op='cache_choose'});assert(chosen==true)
bar:dispatch('settings@'..J.encode{op='cache_default'});assert(chosen=='default')
set('fade_ms',10,false);local detached=false;bar.r.AM_BarDetach=function()detached=true end
bar:close();assert(detached and a.saved.fade_ms==10,'Detach lost pending slider changes')
