-- @description SoundPrep - Optional keyboard and maintenance actions
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local scripts={'SoundPrep.lua','SoundPrep - Restore native preview.lua','SoundPrep - Diagnostics.lua','SoundPrep - Render selected drops.lua',
  'SoundPrep - Restore selected source FX.lua','SoundPrep - Offline inactive source FX.lua'}
local r=reaper
package.path=root..'/lib/?.lua;'..package.path
local Setup=require('am.setup')
local ok,installed_native=pcall(Setup.install_native_if_missing,r,root)
if not ok then r.ShowMessageBox(tostring(installed_native),'SoundPrep',0);return end
for _,file in ipairs(scripts)do assert(r.AddRemoveReaScript(true,0,root..'/'..file,true)>0)end
local names={}
for i=0,9 do names[#names+1]='Slot '..i end
for _,name in ipairs{'Reverse','AB','Play Stop','Replay','Stop','Export','Analyse','Edit','Quit'}do names[#names+1]=name end
for _,name in ipairs(names)do
  local path=root..'/actions/SoundPrep - '..name..'.lua'
  assert(r.AddRemoveReaScript(true,32063,path,true)>0)
end
local compatible,native_error=require('am.native').inspect(r)
local notice=installed_native and Setup.restart_notice..'\n\n' or
  not compatible and native_error..'\n\n' or ''
r.ShowMessageBox('Launch SoundPrep.lua for normal use.\n\n'..notice..
  'Optional actions registered: 5 Main maintenance actions and '..#names..' Media Explorer shortcuts.\n\n'..
  'Assign keys in the Media Explorer Action List if needed. These actions do not start SoundPrep. Existing shortcuts were preserved.','SoundPrep',0)
