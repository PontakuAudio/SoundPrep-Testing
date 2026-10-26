-- Owned REAPER integration: fresh renders, prepared copies, cached reuse,
-- real take peaks, selection scope, and Undo/Redo. Leaves a saved test tab for QA.
local r=reaper;assert(r.file_exists(r.GetResourcePath()..'/.audition-macro-test'))
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
for name in pairs(package.loaded)do if name:match('^am%.')then package.loaded[name]=nil end end
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local I=require('am.insert');local E=require('am.export');local L=require('am.loudness');local M=require('am.model')
local dir=r.GetResourcePath()..'/peak-test-'..U.hash(r.genGuid());r.RecursiveCreateDirectory(dir,0)
local f=assert(io.open(r.GetResourcePath()..'/insert-peaks.txt','w'));f:setvbuf('no')
local function log(...)for _,v in ipairs({...})do f:write(tostring(v),'\t')end;f:write('\n')end
local project,other,plans,items,deadline,done,undoOpen,redone
local function finish(ok,err)
 if done then return end;done=true
 if undoOpen then r.Undo_EndBlock2(project,'Peak test interrupted',-1);undoOpen=false end
 log(ok and 'PASS' or 'FAIL',err or '');f:close()
end
local function peaks(item)
 local take=r.GetActiveTake(item);local buffer=r.new_array(256);buffer.clear()
 local n=r.GetMediaItemTake_Peaks(take,100,r.GetMediaItemInfo_Value(item,'D_POSITION'),2,32,0,buffer)&0xfffff
 local max=0;for i=1,n*2 do max=math.max(max,math.abs(buffer[i]))end
 return n,max
end
local ok,err=xpcall(function()
 r.Main_OnCommand(41929,0);project=r.EnumProjects(-1)
 r.SetMediaTrackInfo_Value(r.GetMasterTrack(project),'D_VOL',0)
 r.InsertTrackAtIndex(0,false);local track=r.GetTrack(project,0);r.SetOnlyTrackSelected(track)
 local file='/tmp/audition-macro-dev/test.wav';local macro=M.macro('peaks','Peak regression');macro.export.tail_seconds=0
 local snap=E.snapshot(r,file,macro,'',0,L.identity(r,file),nil,{fade_ms=0})
 local fresh=I.prepare(r,snap,1,true,dir..'/fresh')
 local cached=I.prepare(r,snap,1,true,dir..'/fresh');assert(cached.target==fresh.target)
 snap.macro.source_transform.reverse=true;snap.macro.source_transform.rate=.5;snap.range={.2,.7}
 local staged=I.prepare(r,snap,1,false,dir..'/stage')
 local render=E.render;E.render=function()error('Prepared copy must not render again')end
 local copiedOK,copied=pcall(I.prepare,r,snap,1,false,dir..'/copy',dir..'/stage');E.render=render
 assert(copiedOK,copied);assert(copied.target~=staged.target and U.read(copied.target)==U.read(staged.target))
 plans={fresh,cached,copied}
 -- Unrelated media with no peaks must remain outside the batch.
 assert(U.copy_file(file,dir..'/unrelated.wav'))
 other=r.AddMediaItemToTrack(track);local take=r.AddTakeToMediaItem(other)
 assert(r.SetMediaItemTake_Source(take,r.PCM_Source_CreateFromFile(dir..'/unrelated.wav')))
 r.SetMediaItemInfo_Value(other,'D_LENGTH',1);r.SetMediaItemInfo_Value(other,'D_POSITION',6)
 assert(peaks(other)==0,'Unrelated fixture already has peaks')
 r.Undo_OnStateChangeEx2(project,'Set up unrelated peak fixture',-1,-1)
 r.Undo_BeginBlock2(project);undoOpen=true;items={}
 for i,plan in ipairs(plans)do
  local item=r.AddMediaItemToTrack(track);local take=r.AddTakeToMediaItem(item)
  assert(r.SetMediaItemTake_Source(take,r.PCM_Source_CreateFromFile(file)))
  r.SetMediaItemInfo_Value(item,'D_POSITION',(i-1)*2);r.SetMediaItemInfo_Value(item,'D_LENGTH',1)
  I.replace(r,project,item,plan);items[#items+1]=item
 end
 assert(peaks(items[1])==0 and peaks(items[3])==0,'Fresh rendered sources should expose the missing-peaks regression')
 r.SelectAllMediaItems(project,false);r.SetMediaItemSelected(other,true)
 local start=r.time_precise();I.build_missing_peaks(r,project,items);log('batch action ms',(r.time_precise()-start)*1000)
 assert(r.CountSelectedMediaItems(project)==1 and r.GetSelectedMediaItem(project,0)==other,'Selection changed')
 r.Undo_EndBlock2(project,'Insert Audition Macro peak regression',-1);undoOpen=false
 deadline=r.time_precise()+10
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
 local ok,err=xpcall(function()
  for _,item in ipairs(items)do
   local n,max=peaks(item)
   if n==0 or max<=.01 then assert(r.time_precise()<deadline,'Rendered take peaks were not built');return end
  end
  if not redone then
   assert(peaks(other)==0,'Peak action included unrelated media')
   log('fresh render, cached source, prepared copy/reverse/crop: nonzero take peaks; unrelated source unchanged')
   assert(r.Undo_DoUndo2(project)==1 and r.CountMediaItems(project)==1,'Undo split the insertion')
   assert(r.Undo_DoRedo2(project)==1 and r.CountMediaItems(project)==4,'Redo lost dropped items')
   items={}
   for i=0,r.CountMediaItems(project)-1 do
    local item=r.GetMediaItem(project,i)
    if r.CountTakes(item)==2 then items[#items+1]=item end
   end
   assert(#items==3,'Redo lost alternate takes');redone=true;deadline=r.time_precise()+10;return
  end
  r.Main_SaveProjectEx(project,dir..'/waveforms.rpp',8);r.UpdateArrange()
  log('single Undo/Redo preserved both takes and rendered peaks',dir..'/waveforms.rpp')
  finish(true)
 end,debug.traceback)
 if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
r.defer(tick)
