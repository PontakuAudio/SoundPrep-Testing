local U=require('am.util');local J=require('am.json');local L=require('am.loudness');local Model=require('am.model')
local D=require('am.drop_analysis');local T=require('am.drop_transaction');local R=require('am.render_item')
local saved={read=U.read,new=L.new,finish=T.finish,stamp=R.stamp}
local project={};local ext,files,items,clock,applied,starts,worker,fail_finish,source_changed,transport,console
local function identity(path)return {path=path,size=100,mtime=source_changed and 2 or 1}end
local function chunk(item)
  return '<ITEM\nPOSITION '..item.position..'\nSEL '..item.selected..'\nDATA '..J.encode({mute=item.mute,name=item.name,
    tag=item.tag,path=item.path,volume=item.volume}):gsub('\n','')..'\n>\n'
end
local r={EnumProjects=function()return project end,time_precise=function()return clock end,
  GetExtState=function(_,key)return ext[key]or ''end,SetExtState=function(_,key,value)ext[key]=value end,
  DeleteExtState=function(_,key)ext[key]=nil end,
  CountMediaItems=function()return #items end,GetMediaItem=function(_,i)return items[i+1]end,
  CountTakes=function()return 1 end,GetActiveTake=function(item)return item end,
  GetSetMediaItemInfo_String=function(item,key,value,set)
    if key=='GUID'then return true,item.id end
    if set then item.tag=value end;return true,item.tag or ''
  end,
  GetSetMediaItemTakeInfo_String=function(item,key,value,set)
    assert(key=='P_NAME');if set then item.name=value end;return true,item.name
  end,
  GetMediaItemInfo_Value=function(item,key)assert(key=='B_MUTE');return item.mute end,
  SetMediaItemInfo_Value=function(item,key,value)assert(key=='B_MUTE');item.mute=value end,
  GetItemStateChunk=function(item)return true,chunk(item)end,
  SetItemStateChunk=function(item,text)
    local value=J.decode(text:match('DATA ([^\n]+)'));for key,v in pairs(value)do item[key]=v end;return true
  end,
  UpdateItemInProject=function()end,JS_File_Stat=function()return 0,100,0,source_changed and 2 or 1 end,
  ValidatePtr=function()return true end,GetPlayStateEx=function()return transport end,
  Undo_BeginBlock2=function()end,Undo_EndBlock2=function()end,
  ShowConsoleMsg=function(text)console=console..text end,
}
local function measurement(path)
  return {identity=identity(path),analyzer_key='analyzer',profile=L.PROFILE,status='ready',channels=2,duration=1,
    max_momentary_lufs=path=='/a.wav' and -24 or -20,true_peak_dbtp=-18,job_id='session:1'}
end
local function setup(count)
  ext={};files={};items={};clock=10;applied=0;starts=0;worker=nil;fail_finish=false;source_changed=false;transport=0;console=''
  local bank=Model.defaults();local macro=Model.effective(bank,nil);macro.normalization.enabled=true;macro.normalization.target_lufs=-18
  local p={transaction=1,session='session',project=tostring(project),data='/data',analyzer_key='analyzer',settings=bank.settings,
    entries=J.array{},auto_render=true,defer_items=true,analysis_pending=true,
    analysis_job={job_id='session:1',identity=identity('/a.wav'),result='/result',started=clock}}
  local ids={}
  for i=1,count or 1 do
    local path=i==1 and '/a.wav' or '/b.wav'
    p.entries[i]={snapshot={path=path,identity=identity(path),macro=U.copy(macro),source_gain_db=0,item_render={revision=2}},length=1,analysis_pending=true}
    items[i]={id='item-'..i,path=path,position=i,selected=1,mute=0,volume=1,name=path};ids[i]=items[i].id
  end
  local app={project=project,session='session',root='.',loudness={active=U.copy(p.analysis_job)},message=''}
  local d=D.new(r,app);D.enqueue(r,project,p,ids)
  return d,p,app
end
local function tick(d)clock=clock+.1;d:tick()end
local ok,err=xpcall(function()
  U.read=function(path)return files[path]end;R.stamp=function(_,s)s.item_render={revision=2}end
  L.new=function()
    worker={error=nil,close=function(self)self.closed=true end,poll=function()end,
      request=function(self,id,_,spec)
        if not self.requested then starts=starts+1;self.requested=U.copy(id);self.spec=U.copy(spec)end
        return self.result
      end}
    return worker
  end
  T.finish=function(_,_,p,ids)
    assert(#ids==#p.entries and not p.analysis_pending)
    for i,item in ipairs(items)do
      local s=p.entries[i].snapshot;assert(not p.entries[i].analysis_pending)
      item.volume=U.gain(s.source_gain_db);item.mute=p.analysis_mutes[item.id]
      if fail_finish then error('render failed')end
    end
    applied=applied+1;ext.message='Normalized';ext.auto_render=p.auto_render
  end
  local d,p,a=setup();tick(d)
  assert(#d.jobs==1 and applied==0 and starts==0 and items[1].mute==1 and items[1].name:find('analysing'))
  -- A pending drop keeps its target even after live selection/preset changes.
  p.entries[1].snapshot.macro.normalization.target_lufs=-50
  files['/result']=J.encode(measurement('/a.wav'));items[1].position=50;items[1].selected=0;transport=1
  tick(d)
  assert(#d.jobs==0 and applied==1 and items[1].mute==0 and items[1].name=='/a.wav')
  assert(items[1].position==50 and items[1].selected==0 and math.abs(items[1].volume-U.gain(6))<1e-12)
  assert(ext.auto_render==false and console=='','Late completion stopped playback or reported a cancellation')
  tick(d);assert(applied==1,'Drop completion ran twice')

  -- Companion polling may delete the result before this queue reads it.
  d,p,a=setup();a.loudness.active=nil
  files['/data/cache/'..L.key(identity('/a.wav'),'analyzer')..'.json']=J.encode(measurement('/a.wav'))
  tick(d);assert(applied==1 and starts==0 and items[1].mute==0)

  -- Cancellation/cleanup of the selection's job must not strand the drop.
  for _,active in ipairs{false,{job_id='session:1',cancelled=true},{job_id='another'}}do
    d,p,a=setup();a.loudness.active=active or nil;tick(d)
    assert(starts==1 and worker.requested.path=='/a.wav' and applied==0)
    worker.result=measurement('/a.wav');tick(d);assert(applied==1 and worker.closed)
  end
  -- All entries wait together, including previously unmeasured list members.
  d,p,a=setup(2);files['/result']=J.encode(measurement('/a.wav'));tick(d)
  assert(starts==1 and worker.requested.path=='/b.wav' and applied==0 and items[1].mute==1 and items[2].mute==1)
  worker.result=measurement('/b.wav');tick(d)
  assert(applied==1 and math.abs(items[1].volume-U.gain(6))<1e-12 and math.abs(items[2].volume-U.gain(2))<1e-12)

  for _,change in ipairs{
    function()items={}end, -- Undo/removal cannot recreate items.
    function()items[1].volume=.25 end, -- An edit must not be overwritten.
    function()source_changed=true end,
    function()files['/result']=J.encode{job_id='session:1',status='error',error='analysis failed'}end,
    function()clock=1000 end,
  }do
    d,p,a=setup();change();tick(d)
    assert(applied==0 and #d.jobs==0 and a.message:find('Drop analysis stopped:',1,true))
    if items[1]then assert(items[1].mute==1 and items[1].volume<=1)end
  end
  d,p,a=setup();a.loudness.active=nil;tick(d);worker.error='Could not start native analysis';tick(d)
  assert(applied==0 and #d.jobs==0 and worker.closed)
  d,p,a=setup();files['/result']=J.encode(measurement('/a.wav'));fail_finish=true;tick(d)
  assert(applied==0 and items[1].mute==1 and items[1].volume==1 and items[1].name:find('incomplete'))
  d,p,a=setup();a.loudness.active=nil;tick(d);d:close()
  assert(worker.closed and #d.jobs==0 and items[1].mute==1 and items[1].name:find('incomplete'))
end,debug.traceback)
U.read,L.new,T.finish,R.stamp=saved.read,saved.new,saved.finish,saved.stamp
assert(ok,err)
