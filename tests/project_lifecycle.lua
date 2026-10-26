local App=require('am.app');local Bank=require('am.bank');local Drop=require('am.drop')
local Model=require('am.model');local U=require('am.util')
local function fixture()
  local project={valid=true};local input={valid=true};local raw={valid=true}
  local writes,files,warnings,ext={},{},{},{}
  local stats={stops=0,restores=0,detaches=0,deleted=0,reads=0}
  local r={ValidatePtr=function(p,kind)assert(kind=='ReaProject*');return p.valid end,
    ValidatePtr2=function(p,t,kind)
      assert(p.valid,'ValidatePtr2 was called with a closed project')
      assert(kind=='MediaTrack*');return t and t.valid
    end,
    EnumProjects=function()return project end,GetExtState=function(s,k)return ext[s..k] or ''end,
    DeleteExtState=function(s,k)ext[s..k]=nil end,
    ShowConsoleMsg=function(text)warnings[#warnings+1]=text end,
    AM_DropDetach=function()stats.detaches=stats.detaches+1 end,
    GetSetMediaTrackInfo_String=function(t)assert(t.valid);return true,'session'end,
    CountTrackMediaItems=function(t)assert(t.valid);return 0 end,
    DeleteTrack=function(t)assert(t.valid);t.valid=false;stats.deleted=stats.deleted+1 end,
    SetMediaTrackInfo_Value=function(t,k,v)assert(t.valid);t[k]=v end,
    GetTrackStateChunk=function(t)
      assert(t.valid,'Read a removed FX track');stats.reads=stats.reads+1
      return true,'<TRACK\n<FXCHAIN\nSHOW -1\n<JS edited\n1\n>\n>\n>\n'
    end}
  local definition=Model.defaults()
  local bank=setmetatable({r=r,project=project,root='/test',session='session',
    definition=definition,input=input,raw=raw,tracks={input,raw},macros={}},Bank)
  for _,m in ipairs(definition.macros)do
    local t={valid=true};bank.macros[m.id]=t;bank.tracks[#bank.tracks+1]=t
    files['/test/'..m.fx_chain]='original '..m.id
  end
  local app=setmetatable({r=r,project=project,session='session',data='/test',definition=definition,bank=bank,
    preview={stop=function()stats.stops=stats.stops+1 end},
    explorer={restore=function()stats.restores=stats.restores+1 end},
    loudness={close=function()end}},App)
  app.drop=setmetatable({r=r,app=app,peaks={close=function()end}},Drop)
  ext[App.EXT..'session']='session';ext[App.EXT..'heartbeat']='1';ext[Drop.EXT..'state']='old recipe'
  return app,project,stats,writes,files,warnings,ext
end

local read,write=U.read,U.write
local ok,err=xpcall(function()
  local app,project,stats,writes,files,warnings,ext=fixture()
  U.read=function(path)return files[path]end
  U.write=function(path,text)writes[path]=text;return true end
  -- The last project may keep its pointer when Close Project empties it.
  for _,t in ipairs(app.bank.tracks)do t.valid=false end
  app.preset_drafts={heavy=U.copy(app.definition.macros[1])}
  app.r.GetExtState=function(s,k)if s==Drop.EXT and k=='busy'then return '1'end;return ext[s..k] or ''end
  app:tick()
  assert(app.closed and app.cleaned and stats.stops==1 and stats.restores==1 and stats.detaches==1)
  assert(stats.reads==0 and next(writes)==nil and #warnings==0,'Project close saved missing FX or emitted false preservation warnings')
  assert(not ext[App.EXT..'session'] and not ext[App.EXT..'heartbeat'] and not ext[Drop.EXT..'state'])
  app:tick();app.drop:tick();app:close()
  assert(stats.stops==1 and stats.restores==1 and stats.detaches==1,'Cleanup repeated after exit')

  app,project,stats,writes,files,warnings=fixture()
  U.read=function(path)return files[path]end;U.write=function(path,text)writes[path]=text;return true end
  project.valid=false
  app.drop:tick() -- Editor/bar call this directly, outside App:tick.
  assert(app.cleaned and stats.reads==0 and next(writes)==nil and #warnings==0)

  app,project,stats,writes,files,warnings=fixture()
  U.read=function(path)return files[path]end;U.write=function(path,text)writes[path]=text;return true end
  app.selected_id='heavy';app.bank.macros.heavy.valid=false
  app.drop:tick()
  assert(app.cleaned and not writes['/test/chains/heavy.RfxChain'] and #warnings==0)
  assert(stats.reads==#app.definition.macros-1,'Surviving FX were not saved during shutdown')

  app,project,stats,writes,files,warnings=fixture()
  U.read=function(path)return files[path]end;U.write=function(path,text)writes[path]=text;return true end
  app.r.EnumProjects=function()return {}end
  app.publish=function()end;app.loudness.poll=function()end
  app:tick();app.drop:tick()
  assert(not app.closed and not app.cleaned and app.message:match('Paused') and stats.stops==1)
  assert(stats.detaches==1 and stats.reads==0,'Switching tabs closed/saved the attached project')
  app.r.EnumProjects=function()return project end
  assert(app:check_project(),'Returning to the attached tab did not resume')
  -- Genuine save failures still preserve the surviving track for recovery.
  local failed=app.bank.macros.heavy
  U.write=function(path,text)if path=='/test/chains/heavy.RfxChain'then return nil,'disk failure'end;writes[path]=text;return true end
  app:close()
  assert(failed.valid and app.bank.preserve[failed] and failed.D_VOL==0 and failed.B_SHOWINTCP==1)
  assert(#warnings==1 and warnings[1]:match('FX save failed; track preserved'))
end,debug.traceback)
U.read,U.write=read,write
assert(ok,err)

-- Exercise the real launcher: project checks precede even the modal drag gate,
-- and closing during tick must not draw an editor or reattach the native bar.
local old_reaper,create= _G.reaper,App.new
for _,modal in ipairs{false,true}do
  local callback;local checks=0
  local fake={check_project=function(self)
    checks=checks+1
    if checks>1 then self.closed=true;self.cleaned=true;return false end
    return true
  end,publish=function()end,tick=function(self)self.closed=true;self.cleaned=true end,
    close=function(self)self.closed=true;self.cleaned=true end}
  App.new=function()return fake end
  _G.reaper={GetOS=function()return 'Linux'end,GetExtState=function()return ''end,atexit=function()end,
    APIExists=function()return true end,AM_DropContext=function()return modal and 'drag' or ''end,
    defer=function(fn)callback=fn end,ShowMessageBox=function(text)error('Unexpected error dialog: '..text)end}
  local Bar=require('am.bar');local new=Bar.new
  Bar.new=function()return {tick=function()assert(not fake.cleaned,'Bar ran after project close')end}end
  local launched,e=xpcall(function()
    dofile('./Audition Macro.lua')
    if modal then assert(callback);callback()end
  end,debug.traceback)
  Bar.new=new;App.new=create;_G.reaper=old_reaper
  assert(launched,e);assert(fake.cleaned)
end
