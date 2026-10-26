local I=require('am.insert');local P=require('am.drop_pending');local C=require('am.chunk')
local L=require('am.loudness');local D=require('am.render_item')
local base='<ITEM\nPOSITION 0\nSEL 1\nLENGTH 2\n<TAKEFX\n<JS effect\n1 2 3\n>\n>\n>\n'
assert(I.render_guard(base)==I.render_guard(base:gsub('POSITION 0','POSITION 42'):gsub('SEL 1','SEL 0')))
assert(I.render_guard(base)~=I.render_guard(base:gsub('LENGTH 2','LENGTH 1')))
assert(I.render_guard(base)~=I.render_guard(base:gsub('1 2 3','1 9 3')))
local saved={C.read_item,C.write_item,I.prepare,I.add_rendered,I.build_missing_peaks,L.identity,D.stamp}
local ok,err=xpcall(function()
  local items={{guid='moved',chunk=base:gsub('POSITION 0','POSITION 42')},{guid='trimmed',chunk=base:gsub('LENGTH 2','LENGTH 1')}}
  local added,blocks,restored=0,0,0
  local identity={path='/source.wav',size=100,mtime=1}
  local r={CountMediaItems=function()return #items end,GetMediaItem=function(_,i)return items[i+1]end,
    GetSetMediaItemInfo_String=function(item)return true,item.guid end,CountTakes=function()return 1 end,
    Undo_BeginBlock2=function()blocks=blocks+1 end,Undo_EndBlock2=function()end,
    SetExtState=function()end,DeleteExtState=function()end}
  C.read_item=function(_,item)return item.chunk end
  C.write_item=function(_,item,chunk)assert(item==items[1]);restored=restored+1;item.chunk=chunk end
  I.prepare=function()return {}end;D.stamp=function()end
  I.add_rendered=function(_,_,item)assert(item.guid=='moved');added=added+1 end
  I.build_missing_peaks=function()end;L.identity=function()return identity end
  local batch={directory='fixture',entries={}}
  for _,guid in ipairs{'moved','trimmed','undone'}do batch.entries[#batch.entries+1]={item=guid,guard=I.render_guard(base),snapshot={path='/source.wav',identity=identity},length=2,handles=true}end
  local app={project='project'};local p=P.new(r,app);p:complete(batch)
  assert(added==1 and blocks==1 and app.message:find('2 edited/removed',1,true))
  I.prepare=function()error('fixture render failure')end;p:complete(batch)
  assert(restored==1 and app.message:find('Source + FX retained',1,true),'Failure must restore playable Source + FX')
  items={};p:complete(batch);assert(added==1 and blocks==2,'Absent items must not create an undo point')
end,debug.traceback)
C.read_item,C.write_item,I.prepare,I.add_rendered,I.build_missing_peaks,L.identity,D.stamp=table.unpack(saved)
assert(ok,err)
