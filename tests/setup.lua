local Setup=require('am.setup')
local open,rename,remove,reaper_before=io.open,os.rename,os.remove,reaper
local app_before=package.loaded['am.app']
local ok,err=xpcall(function()
  local files,loaded,platform,fail_write,fail_close,fail_move
  local r={GetOS=function()return platform end,APIExists=function()return loaded end,
    GetResourcePath=function()return '/profile'end,
    file_exists=function(path)return files[path]~=nil end,
    RecursiveCreateDirectory=function(path)assert(path=='/profile/UserPlugins')end}
  io.open=function(path,mode)
    if mode=='rb'then
      if not files[path]then return nil,'missing file'end
      return {read=function()return files[path]end,close=function()return true end}
    end
    assert(mode=='wb' and path:match('%.soundprep%-new$'),'Setup wrote directly to a loadable helper')
    return {write=function(_,bytes)
      files[path]=fail_write and 'partial' or bytes
      if fail_write then return nil,'disk full'end
      return true
    end,close=function()if fail_close then return nil,'close failed'end;return true end}
  end
  os.rename=function(from,to)
    assert(files[to]==nil,'Setup overwrote an existing helper')
    if fail_move then return nil,'rename failed'end
    files[to]=files[from];files[from]=nil;return true
  end
  os.remove=function(path)files[path]=nil;return true end
  for _,os_name in ipairs{'OSX64','macOS-arm64','Win64'}do
    platform=os_name
    local name='reaper_audition_macro'..(platform=='Win64' and '.dll' or '.dylib')
    local source='/package/build/'..name;local target='/profile/UserPlugins/'..name
    loaded=false;files={[source]='bundled helper'}
    assert(Setup.install_native_if_missing(r,'/package'))
    assert(files[target]=='bundled helper' and not files[target..'.soundprep-new'])
    files[source]='new version'
    assert(not Setup.install_native_if_missing(r,'/package') and files[target]=='bundled helper')
    files[target]=nil;loaded=true
    assert(not Setup.install_native_if_missing(r,'/package') and not files[target],'Loaded helper was replaced')
    loaded=false
    for _,failure in ipairs{'write','close','rename'}do
      fail_write=failure=='write';fail_close=failure=='close';fail_move=failure=='rename'
      local copied=pcall(Setup.install_native_if_missing,r,'/package')
      assert(not copied and not files[target] and not files[target..'.soundprep-new'],'Failed install left a partial helper')
    end
    fail_write=false;fail_close=false;fail_move=false
    files={}
    local copied,message=pcall(Setup.install_native_if_missing,r,'/package')
    assert(not copied and message:find('complete SoundPrep release ZIP',1,true))
  end
  platform='Win32';files={}
  local supported,message=pcall(Setup.install_native_if_missing,r,'/package')
  assert(not supported and message:find('x64',1,true))

  -- First ZIP launch installs just the helper and stops before touching project
  -- data, constructing the application, or registering optional actions.
  platform='macOS-arm64';loaded=false
  files={['./build/reaper_audition_macro.dylib']='bundled helper'}
  local notice
  r.GetExtState=function()return ''end
  r.ShowMessageBox=function(text,title)assert(title=='SoundPrep');notice=text end
  r.AddRemoveReaScript=function()error('Launcher registered an optional action')end
  r.atexit=function()error('First-run setup started an application lifecycle')end
  package.loaded['am.app']={EXT='AuditionMacro.v1',new=function()error('First-run setup changed the project')end}
  reaper=r
  dofile('./SoundPrep.lua')
  assert(notice==Setup.restart_notice and files['/profile/UserPlugins/reaper_audition_macro.dylib'])
end,debug.traceback)
io.open,os.rename,os.remove,reaper=open,rename,remove,reaper_before
package.loaded['am.app']=app_before
assert(ok,err)
