-- One capability check for startup, the embedded bar, installer and diagnostics.
local J=require('am.json');local P=require('am.platform');local C=require('am.native_contract')
local M={}
function M.inspect(r)
  local platform=P.windows(r)and 'windows'or 'macos'
  local problems={};local info
  if not r.APIExists('AM_HelperInfo')then
    problems[#problems+1]='Helper cannot report its supported features (AM_HelperInfo missing)'
  else
    local ok,value=pcall(function()return J.decode(r.AM_HelperInfo())end)
    if not ok or type(value)~='table' or value.schema~=C.schema or type(value.features)~='table' or
      type(value.version)~='string' or value.platform~=platform then
      problems[#problems+1]='Invalid or incompatible helper contract'
    else info=value end
  end
  if info then
    local names={};for name in pairs(C.features)do names[#names+1]=name end;table.sort(names)
    for _,name in ipairs(names)do
      local feature=C.features[name]
      if not feature.platform or feature.platform==platform then
        local revision=info.features[name]
        if type(revision)~='number' or revision~=revision or revision==math.huge or revision<feature.revision then
          problems[#problems+1]=('Feature %s requires revision %d'):format(name,feature.revision)
        end
        for _,api in ipairs(feature.apis)do if not r.APIExists(api)then problems[#problems+1]='Missing '..api end end
      end
    end
  end
  if #problems==0 then return info end
  local installer=platform=='windows'and 'tools/install_native.ps1'or 'tools/install_native.sh'
  return nil,table.concat(problems,'; ')..'. Save your work, close REAPER, update '..P.helper_name(r)..
    ' using '..installer..', then restart REAPER.',info
end
function M.require(r)
  local info,err=M.inspect(r);assert(info,err);return info
end
function M.describe(r)
  local info,err,detected=M.inspect(r);detected=info or detected
  local lines={'Lua package: '..C.version,'Expected native contract schema: '..C.schema}
  if detected then
    lines[#lines+1]='Loaded helper: '..detected.version..' / '..detected.platform
    lines[#lines+1]='Loaded features: '..J.encode(detected.features)
  end
  lines[#lines+1]=info and 'Native compatibility: OK' or 'Native compatibility: '..err
  return table.concat(lines,'\n')
end
return M
