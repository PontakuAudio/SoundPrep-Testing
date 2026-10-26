-- @description SoundPrep - Media Explorer companion
-- @version 0.11.5
-- @author Pontaku Audio
local script=debug.getinfo(1,'S').source:sub(2)
local root=script:match('^(.*)[/\\]')
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app')
local heartbeat=tonumber(reaper.GetExtState(App.EXT,'heartbeat'))
if heartbeat and reaper.time_precise()-heartbeat<3 then
  require('am.action').send(reaper,'edit')
  return
end
local app
local ok,err=xpcall(function()app=App.new(reaper,root,root..'/data')end,debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err),'SoundPrep',0);return end
reaper.atexit(function()app:close()end)
local Bar=require('am.bar')
ok,err=xpcall(function()
  app.bar=Bar.new(reaper,app);app.bar:tick()
end,debug.traceback)
if not ok then app:close();reaper.ShowMessageBox(tostring(err),'SoundPrep',0);return end
local function loop()
  if app.closed or app.cleaned then app:close();return end
  local continue
  local success,e=xpcall(function()
    if not app:check_project()then return end
    if reaper.APIExists('AM_DropContext') and reaper.AM_DropContext()~=''then
      app:publish();continue=true;return
    end
    app:tick()
    if app.closed or app.cleaned then return end
    app.bar:tick()
    continue=not app.closed
  end,debug.traceback)
  if not success then
    app:close();reaper.ShowMessageBox(tostring(e),'SoundPrep stopped',0)
  elseif continue then reaper.defer(loop)else app:close()end
end
loop()
