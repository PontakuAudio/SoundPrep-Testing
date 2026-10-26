local App=require('am.app');local Bar=require('am.bar');local U=require('am.util')
local old_read=U.read
-- Starting with an existing bank must not load, create or migrate dictionaries.
U.read=function(path)error('Unexpected file read: '..path)end
local ok,err=pcall(App.initialize,{RecursiveCreateDirectory=function()end,
  file_exists=function(path)assert(path=='/data/bank.json');return true end},'/root','/data')
U.read=old_read;assert(ok,err)

-- Legacy queued shortcuts and a late event from an old native bar are harmless.
local project={}
local queue='search:open\nsearch:expand\nsearch:restore'
local app=setmetatable({project=project,message='',r={
  GetExtState=function()return queue end,
  DeleteExtState=function()queue=''end,
}},App)
app:commands(false)
assert(queue=='' and app.message:find('not included',1,true))
local bar=Bar.new({EnumProjects=function()return project end},app)
for _,command in ipairs{'search:open','search@{"op":"apply","query":"changed"}'}do
  app.message='';bar:dispatch(command)
  assert(app.message:find('not included',1,true))
end
assert(app.dictionary==nil and app.search_session==nil)
