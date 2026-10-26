-- @description Register SoundPrep actions (preserve all existing shortcuts)
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local scripts={'SoundPrep.lua','SoundPrep - Restore native preview.lua','SoundPrep - Diagnostics.lua','SoundPrep - Render selected drops.lua',
  'SoundPrep - Restore selected source FX.lua','SoundPrep - Offline inactive source FX.lua'}
local r=reaper
package.path=root..'/lib/?.lua;'..package.path
local Platform=require('am.platform')
if Platform.windows(r) and r.GetOS()~='Win64'then
  r.ShowMessageBox('This Windows helper requires the x64 edition of REAPER.','SoundPrep',0)
  return
end
local installed_native=false
if Platform.windows(r) or r.GetOS():match('OSX') or r.GetOS():match('macOS')then
  local path=root..'/build/'..Platform.helper_name(r)
  local input=io.open(path,'rb')
  if input then
    local target=r.GetResourcePath()..'/UserPlugins/'..Platform.helper_name(r)
    -- Never replace a loaded binary in place. An existing installation can be
    -- updated after REAPER exits using the build instructions.
    if not r.file_exists(target)then
      r.RecursiveCreateDirectory(r.GetResourcePath()..'/UserPlugins',0)
      local bytes=input:read('*a');local output=assert(io.open(target,'wb'))
      assert(output:write(bytes));assert(output:close());installed_native=true
    end
    input:close()
  end
end
for _,file in ipairs(scripts)do assert(r.AddRemoveReaScript(true,0,root..'/'..file,true)>0)end
local names={}
for i=0,9 do names[#names+1]='Slot '..i end
for _,name in ipairs{'Reverse','AB','Play Stop','Replay','Stop','Export','Analyse','Edit','Quit'}do names[#names+1]=name end
for _,name in ipairs(names)do
  local path=root..'/actions/SoundPrep - '..name..'.lua'
  assert(r.AddRemoveReaScript(true,32063,path,true)>0)
end
local compatible,native_error=require('am.native').inspect(r)
local notice=installed_native and 'Native helper installed. Restart REAPER after saving your work.\n\n' or
  not compatible and native_error..'\n\n' or ''
r.ShowMessageBox('Registered Main actions and '..#names..' Media Explorer actions.\n\n'..notice..
  'Launch SoundPrep.lua. In the Media Explorer Action List, assign 0–9 to Slot actions, R to Reverse, and your preferred Play / AB keys. Existing shortcuts were preserved.','SoundPrep',0)
