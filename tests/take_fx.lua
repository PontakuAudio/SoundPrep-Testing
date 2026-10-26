local T=require('am.take_fx');local J=require('am.json');local U=require('am.util')
local chain,owned,count=T.offline_chain('SHOW -1\nBYPASS 1 0 0\n<CONTAINER\nBYPASS 0 0 0\n<JS child\n0\n>\n>\nBYPASS 0 1 0\n<JS original_offline\n0\n>\n')
assert(count==2 and #owned==1 and owned[1]==0)
assert(chain:find('BYPASS 1 1 0',1,true) and chain:find('<CONTAINER\nBYPASS 0 0 0',1,true),
  'Pre-offline must preserve bypass and the container children states')
local state='<ITEM\n<TAKEFX\nBYPASS 1 1 0\n<CONTAINER\nBYPASS 0 0 0\n<JS child\n0\n>\nFXID {child}\n>\nFXID {container}\n>\nTAKE\n<TAKEFX\nBYPASS 0 0 0\n<JS foreign\n.5\n>\nFXID {foreign}\n>\n>\n'
local updated=T.offline_item(state,{['{container}']=false})
assert(updated:find('BYPASS 1 0 0\n<CONTAINER',1,true) and updated:find('BYPASS 0 0 0\n<JS child',1,true))
assert(updated:find('BYPASS 0 0 0\n<JS foreign\n.5',1,true),'Changing a source affected another take')
assert(not pcall(T.offline_item,state,{['{missing}']=true}),'An unmapped FX must fail before a write')
local duplicated='<ITEM\nGUID first\n<TAKEFX\nBYPASS 0 1 0\n<JS test\n0\n>\nFXID {same}\n>\nTAKE SEL\nGUID second\n<TAKEFX\nBYPASS 0 1 0\n<JS test\n0\n>\nFXID {same}\n>\n>\n'
local scoped=T.offline_item(duplicated,{['{same}']=false},'first')
local _,online=scoped:gsub('BYPASS 0 0 0','');local _,offline=scoped:gsub('BYPASS 0 1 0','')
assert(online==1 and offline==1,'Duplicate FX GUIDs in another take must remain untouched')
local writes,reads,mutations,changes=0,0,0,0
local project='project';local current=project
local function take(id)
  return {guid=id,valid=true,tags={},chain=-1,media={path='/original.wav'},
    fx={{guid='{'..id..'-gain}',offline=false,enabled=true,param=.25},
        {guid='{'..id..'-bypass}',offline=false,enabled=false,param=.75},
        {guid='{'..id..'-original-offline}',offline=true,enabled=true,param=.5}}}
end
local a,b=take('source'),take('rendered');b.fx={}
a.tags['P_EXT:AuditionMacro']=J.encode{original='/original.wav',snapshot='/snapshot.macro.json'}
local item={valid=true,takes={a,b},active=b,all=0};local items={item};local selected={item}
local r={
  EnumProjects=function()return current end,
  ValidatePtr2=function(_,value)return value.valid end,
  CountMediaItems=function()return #items end,GetMediaItem=function(_,i)return items[i+1]end,
  CountSelectedMediaItems=function()return #selected end,GetSelectedMediaItem=function(_,i)return selected[i+1]end,
  CountTakes=function(x)return #x.takes end,GetTake=function(x,i)return x.takes[i+1]end,
  GetActiveTake=function(x)return x.active end,SetActiveTake=function(x)for _,v in ipairs(items)do for _,t in ipairs(v.takes)do if t==x then v.active=x end end end end,
  GetMediaItemInfo_Value=function(x,key)assert(key=='B_ALLTAKESPLAY');return x.all end,
  GetMediaItemTake_Source=function(x)return x.media end,GetMediaSourceParent=function()end,
  GetMediaSourceFileName=function(x)return x.path end,
  TakeFX_GetCount=function(x)return #x.fx end,TakeFX_GetChainVisible=function(x)return x.chain end,
  TakeFX_GetFloatingWindow=function(x,i)return x.fx[i+1].floating end,
  TakeFX_GetOffline=function(x,i)return x.fx[i+1].offline end,
  TakeFX_GetFXGUID=function(x,i)return x.fx[i+1].guid end,
  TakeFX_SetOffline=function()error('Automatic offline toggles must not create implicit Undo entries')end,
  GetMediaItemTake_Item=function(x)return {takes={x}}end,
  GetItemStateChunk=function(x)
    local lines={'<ITEM'}
    for _,t in ipairs(x.takes)do
      lines[#lines+1]='GUID '..t.guid
      lines[#lines+1]='<TAKEFX'
      for _,fx in ipairs(t.fx)do
        lines[#lines+1]=('BYPASS %d %d 0\n<JS test\n%.17g\n>\nFXID %s')
          :format(fx.enabled and 0 or 1,fx.offline and 1 or 0,fx.param,fx.guid)
      end
      lines[#lines+1]='>'
    end
    lines[#lines+1]='>';return true,table.concat(lines,'\n')
  end,
  SetItemStateChunk=function(x,chunk)
    local flag
    for line in chunk:gmatch('[^\n]+')do
      local offline=line:match('^BYPASS %d+ (%d+) ');if offline then flag=offline=='1'end
      local id=line:match('^FXID ({[^}]+})$')
      if id then for _,t in ipairs(x.takes)do for _,fx in ipairs(t.fx)do
        if fx.guid==id and fx.offline~=flag then fx.offline=flag;mutations=mutations+1;changes=changes+1 end
      end end end
    end
    return true
  end,
  GetProjectStateChangeCount=function()return changes end,
  GetSetMediaItemTakeInfo_String=function(x,key,value,set)
    if key=='GUID'then return true,x.guid end
    if set then x.tags[key]=value;writes=writes+1;changes=changes+1 else reads=reads+1 end
    return true,x.tags[key]or''
  end,
  Undo_BeginBlock2=function()end,Undo_EndBlock2=function()end,UpdateArrange=function()end,
}
assert(T.suspend(r,a)==2 and a.fx[1].offline and a.fx[2].offline and a.fx[3].offline)
assert(a.fx[1].param==.25 and not a.fx[2].enabled,'Offline changed sound settings or the original bypass')
local n=mutations;assert(T.suspend(r,a)==0 and mutations==n,'Repeated offline reloaded a plug-in')
a.fx[1],a.fx[3]=a.fx[3],a.fx[1]
assert(T.restore(r,a)==2 and a.fx[1].offline and not a.fx[2].offline and not a.fx[3].offline,
  'Restore must follow FX GUIDs and keep originally offline FX offline')
assert(T.restore(r,a)==0)
T.suspend(r,a)
local copy=U.copy(a);copy.guid='copied-source'
for i,fx in ipairs(copy.fx)do fx.guid='{copy-'..i..'}'end
assert(T.restore(r,copy)==2 and copy.fx[1].offline,'Copied items lost offline ownership')
local controller=T.new(r,project);controller:tick()
n=mutations;local oldReads,oldWrites=reads,writes;controller:tick()
assert(mutations==n and writes==oldWrites and reads==oldReads,'Idle frames reread recipes or mutate FX')
item.active=a;controller:tick()
assert(not a.fx[2].offline and not a.fx[3].offline and a.fx[1].offline,'Selecting the source did not restore its FX')
item.active=b;controller:tick();assert(a.fx[2].offline)
item.all=1;controller:tick();assert(not a.fx[2].offline,'Play-all-takes must keep source FX audible')
item.all=0;controller:tick();assert(a.fx[2].offline)
a.chain=0;controller:tick();assert(a.fx[2].offline,'Inspecting an inactive source chain restored its FX')
a.chain=-1;controller:tick();assert(a.fx[2].offline)
a.fx[2].floating='window';controller:tick();assert(a.fx[2].offline,'An inactive floating FX editor restored the source')
T.restore(r,a)
assert(T.offline_project(r,project)==2 and a.fx[2].offline,'An open editor prevented explicit batch Offline')
a.chain=0;T.restore(r,a);T.new(r,project):tick()
assert(a.fx[2].offline,'A fresh companion did not offline an inactive source with an open editor')
a.chain=-1
a.fx[2].floating=nil;controller:tick();assert(a.fx[2].offline)
assert(T.restore_selected(r)==2 and item.active==a and not a.fx[2].offline)
item.active=b;assert(T.restore_selected(r)==0 and item.active==a,'Explicit restore must also activate an already-online source')
local unrelated=take('unrelated');local foreign={valid=true,takes={unrelated,b},active=b,all=0}
local pending=take('pending');pending.tags['P_EXT:AuditionMacro']=a.tags['P_EXT:AuditionMacro']
items={foreign,{valid=true,takes={pending},active=pending,all=0},item}
assert(T.offline_project(r,project)==0 and not unrelated.fx[1].offline and not pending.fx[1].offline,
  'Unrelated take FX and the only playable pending take must remain untouched')
item.active=b;assert(T.offline_project(r,project)==2)
item.takes={a};item.active=a;controller:tick();assert(not a.fx[2].offline,'Removing Rendered left the only surviving source inaudible')
T.suspend(r,a);T.new(r,project):tick()
assert(not a.fx[2].offline,'A fresh companion must restore a saved source after Rendered was removed')
T.suspend(r,a);a.media.path='/replacement.wav';T.new(r,project):tick()
assert(not a.fx[2].offline,'Replacing source media while closed must not strand managed FX offline')
current='other';n=mutations;controller:tick();assert(mutations==n,'Controller changed another project')
current=project;item.valid=false;a.valid=false;controller:tick()
