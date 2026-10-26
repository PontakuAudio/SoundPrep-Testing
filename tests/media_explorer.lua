local E=require('am.media_explorer');local U=require('am.util')
local toggles={[42026]=0,[42134]=0,[42091]=0}
local rows={'/library/a/same.wav','/library/b/same.wav'}
local index,search,directory=0,'same','/library'
local reads,fail=0,false
local r={GetToggleCommandStateEx=function(_,id)return toggles[id] or 0 end,
  JS_ListView_ListAllSelItems=function()return 1,tostring(index)end,
  JS_ListView_GetFocusedItem=function()return index end,
  JS_ListView_GetItemText=function(_,i,col)
    if col==3 then return 'wav'end
    reads=reads+1
    if fail and toggles[42026]==1 then error('row read failed')end
    local name=toggles[42026]==1 and rows[i+1] or 'same.wav'
    return toggles[42091]==1 and name or name:gsub('%.wav$','')
  end,
  file_exists=function(path)return path==rows[1]or path==rows[2]or path=='/library/same.wav'end}
local ex=setmetatable({r=r,control=function()return {}end,
  text=function(_,id)return id==1002 and directory or search end,
  command=function(_,id)
    toggles[id]=1-toggles[id]
    if toggles[id]==1 and (id==42026 or id==42134)then toggles[id==42026 and 42134 or 42026]=0 end
  end},E)
for _,display in ipairs{{0,0,0},{0,1,1},{1,0,0},{1,0,1}}do
  toggles={[42026]=display[1],[42134]=display[2],[42091]=display[3]}
  local before=U.copy(toggles);ex.selected=nil;index=0
  assert(ex:selection()==rows[1]and U.equal(toggles,before))
  local n=reads;assert(ex:selection()==rows[1]and reads==n+1,'Unchanged selection repeated the canonical read')
  index=1;assert(ex:selection()==rows[2]and U.equal(toggles,before),'Same-name rows reused a stale path')
end
toggles={[42026]=0,[42134]=1,[42091]=0};ex.selected=nil;fail=true
local before=U.copy(toggles)
assert(not pcall(ex.selection,ex)and U.equal(toggles,before),'Failed resolution leaked display settings')
fail=false;search='';index=0;directory='/library/a';ex.selected=nil
assert(ex:selection()==rows[1]and U.equal(toggles,before),'Hidden extension failed in an ordinary folder')
-- No accidental resolution relative to REAPER's working directory.
toggles[42091]=1;r.file_exists=function(path)return path=='same.wav'or path==rows[1]end
ex.selected=nil;assert(ex:selection()==rows[1])

-- New sessions do not force display preferences on attach or undo user edits
-- on close. Recovery of pre-fix snapshots still restores their forced settings.
local commands={};local attached=E.new({
  GetToggleCommandStateEx=function(_,id)return toggles[id]or 0 end,
  JS_WindowMessage_Send=function()return 300 end,
  JS_Window_GetFocus=function()end})
attached.window=function()return {}end;attached.control=function()return {}end
attached.text=function()return '-6'end;attached.transform=function()return {}end
attached.command=function(_,id)commands[#commands+1]=id end
attached.volume=function()end;attached.quiesce=function()end;attached.attach_transport=function()end
attached.fader=function()end;attached.set_transform=function()end
attached:attach()
for _,id in ipairs(commands)do assert(id~=42026 and id~=42134 and id~=42091)end
local saved=U.copy(attached.saved);toggles[42026]=1;toggles[42134]=0;commands={}
attached:restore()
for _,id in ipairs(commands)do assert(id~=42026 and id~=42134 and id~=42091,'Close overwrote a user display edit')end
saved.preserve_display=nil;attached.saved=saved;commands={};attached:restore()
assert(#commands>0,'Legacy recovery no longer restores display settings')
