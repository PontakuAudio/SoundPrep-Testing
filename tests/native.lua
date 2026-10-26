local J=require('am.json');local U=require('am.util');local C=require('am.native_contract');local N=require('am.native')
local function fixture(os)
  local platform=os=='Win64'and 'windows'or 'macos'
  local info={schema=C.schema,version='999.0.0',platform=platform,features={}}
  local apis={AM_HelperInfo=true}
  for name,f in pairs(C.features)do if not f.platform or f.platform==platform then
    info.features[name]=f.revision
    for _,api in ipairs(f.apis)do apis[api]=true end
  end end
  local r={GetOS=function()return os end,APIExists=function(name)return apis[name]or false end,
    AM_HelperInfo=function()return J.encode(info)end}
  return r,info,apis
end
for _,os in ipairs{'Win64','macOS-arm64'}do
  local r,info,apis=fixture(os)
  assert(N.inspect(r),'Compatible feature revisions must work independently of release version')
  assert(require('am.bar').available(r))
  info.features.bar=3
  local ok,err=N.inspect(r);assert(not ok and err:find('bar requires revision '..C.features.bar.revision,1,true))
  assert(not require('am.bar').available(r),'Old helper silently retained the withdrawn Search UI')
  info.features.bar=C.features.bar.revision
  info.features.preview=1;assert(not N.inspect(r),'Old helper silently accepted multichannel preview')
  info.features.preview=2;assert(not N.inspect(r),'Old downmix helper silently accepted AmbiX M/S decoding')
  info.features.preview=C.features.preview.revision
  apis.AM_Preview_CreateWithChannels=nil;assert(not N.inspect(r),'Multichannel preview capability requires its registered API')
  apis.AM_Preview_CreateWithChannels=true
  apis.AM_Preview_CreateWithDownmix=nil;assert(not N.inspect(r),'AmbiX preview capability requires its registered API')
  apis.AM_Preview_CreateWithDownmix=true
  apis.AM_Preview_SetLatencyTrack=nil;assert(not N.inspect(r),'Claimed capability without registered API accepted')
  apis.AM_Preview_SetLatencyTrack=true
  info.platform=os=='Win64'and'macos'or'windows';assert(not N.inspect(r))
  info.platform=os=='Win64'and'windows'or'macos';info.schema=999;assert(not N.inspect(r))
  info.schema=C.schema;apis.AM_HelperInfo=nil
  assert(not require('am.bar').available(r),'Legacy same-name APIs must not imply current UI support')
  local writes=0;r.RecursiveCreateDirectory=function()writes=writes+1 end
  assert(not pcall(require('am.app').new,r,'/unused','/unused') and writes==0,'Compatibility failure changed settings before rejection')
end
local r,info=fixture('macOS-arm64');info.features.quiet_render=nil
assert(N.inspect(r),'Platform-only features must not be required on the other platform')
assert(N.describe(r):find('999.0.0',1,true))

-- A newly declared control must have a shared Lua handler. Both native GUIs
-- send these commands; platform-specific handlers would defeat the contract.
local project={}
local app={project=project,definition={settings={}},bank={activate=function()end},
  search_session={command=function()end},save=function()end,
  effective=function()return {source_transform={preserve_pitch=false},normalization={enabled=false},output_gain_db=0}end}
for _,name in ipairs{'activate','ab','reverse','set_preserve_pitch','set_normalization','set_downmix'}do app[name]=function()end end
local bar=require('am.bar').new({EnumProjects=function()return project end},app)
for _,control in ipairs(C.bar.controls)do
  local command=control.command
  if control.kind=='popup'then command=command..':'..C.bar.options[command][1]end
  assert(pcall(bar.dispatch,bar,command),'Contract control has no shared handler: '..command)
end
assert(not pcall(bar.dispatch,bar,'unsupported-control'),'Unknown helper commands must be visible instead of silently ignored')
