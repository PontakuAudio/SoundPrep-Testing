local root_names={'',' - Install actions',' - Diagnostics',' - Restore native preview',' - Render selected drops',
  ' - Restore selected source FX',' - Offline inactive source FX'}
local actions={
  {'Reverse','reverse'},{'AB','ab'},{'Play Stop','play'},{'Replay','replay'},{'Stop','stop'},
  {'Export','export'},{'Analyse','analyse'},{'Edit','edit'},{'Quit','quit'},
}
for i=0,9 do actions[#actions+1]={'Slot '..i,'slot:'..i}end

-- Legacy file paths are part of REAPER's action identity. Each still exists and
-- forwards once to the same-directory canonical action, including on Windows.
local function check_alias(directory,suffix)
  local old=directory..'Audition Macro'..suffix..'.lua'
  local canonical=directory..'SoundPrep'..suffix..'.lua'
  assert(loadfile(canonical),'Missing canonical action: '..canonical)
  local forwarded
  local environment=setmetatable({dofile=function(path)
    assert(not forwarded,'Legacy action dispatched twice');forwarded=path;return 'forwarded'
  end},{__index=_G})
  assert(assert(loadfile(old,'t',environment))()=='forwarded')
  assert(forwarded==canonical,'Legacy action changed its target directory: '..old)
end
for _,suffix in ipairs(root_names)do check_alias('./',suffix)end
for _,action in ipairs(actions)do check_alias('./actions/',' - '..action[1])end

local old_reaper,old_path=reaper,package.path
local modules={}
for _,name in ipairs{'am.action','am.app','am.platform','am.native','am.setup'}do modules[name]=package.loaded[name]end
local ok,err=xpcall(function()
  local sent={}
  reaper={}
  package.loaded['am.action']={send=function(r,command)
    assert(r==reaper);sent[#sent+1]=command
  end}
  for _,action in ipairs(actions)do
    for _,prefix in ipairs{'SoundPrep','Audition Macro'}do
      local before=#sent
      dofile('./actions/'..prefix..' - '..action[1]..'.lua')
      assert(#sent==before+1 and sent[#sent]==action[2],'Action command changed: '..prefix..' - '..action[1])
    end
  end

  -- Both names share the original heartbeat and request Edit on an existing
  -- session. Renaming the launcher must never create a second preview bank.
  package.loaded['am.app']={EXT='AuditionMacro.v1',new=function()error('Duplicate application started')end}
  reaper={GetExtState=function(section,key)
    assert(section=='AuditionMacro.v1' and key=='heartbeat');return '100'
  end,time_precise=function()return 101 end}
  for _,name in ipairs{'./SoundPrep.lua','./Audition Macro.lua'}do
    local before=#sent;dofile(name)
    assert(#sent==before+1 and sent[#sent]=='edit','Launcher did not reuse the active application')
  end

  -- The installer only registers canonical actions; pre-existing legacy IDs
  -- and their shortcuts remain untouched across repeated installs.
  local registered={['0:./Audition Macro.lua']=41,['32063:./actions/Audition Macro - Play Stop.lua']=42}
  local shortcuts={[41]='Ctrl+Alt+A',[42]='Space'}
  local calls,new_id=0,100
  package.loaded['am.platform']={windows=function()return false end}
  package.loaded['am.native']={inspect=function()return true end}
  reaper={GetOS=function()return 'Linux' end,APIExists=function()return false end,
    AddRemoveReaScript=function(add,section,path,commit)
      assert(add==true and commit==true,'Installer removed an existing action')
      assert(section==0 or section==32063,'Incorrect action section')
      assert(not path:find('Audition Macro',1,true) and path:find('SoundPrep',1,true),'Installer registered a legacy alias')
      assert(loadfile(path),'Installer registered a missing action')
      local key=section..':'..path
      if not registered[key]then new_id=new_id+1;registered[key]=new_id end
      calls=calls+1;return registered[key]
    end,
    ShowMessageBox=function(message,title)
      assert(title=='SoundPrep' and message:find('Launch SoundPrep.lua',1,true))
    end}
  dofile('./SoundPrep - Install actions.lua')
  assert(calls==25 and new_id==125,'Expected 6 Main and 19 Media Explorer registrations')
  dofile('./Audition Macro - Install actions.lua')
  assert(calls==50 and new_id==125,'Reinstall changed action identities')
  assert(registered['0:./Audition Macro.lua']==41 and registered['32063:./actions/Audition Macro - Play Stop.lua']==42)
  assert(shortcuts[41]=='Ctrl+Alt+A' and shortcuts[42]=='Space','Legacy shortcuts were changed')
end,debug.traceback)
reaper,package.path=old_reaper,old_path
for _,name in ipairs{'am.action','am.app','am.platform','am.native','am.setup'}do package.loaded[name]=modules[name]end
if not ok then error(err,0)end
