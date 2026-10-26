local M={}
function M.windows(r)return r and r.GetOS and r.GetOS():match('^Win')~=nil or not r and package.config:sub(1,1)=='\\'end
function M.worker_name(r)return 'reaper_audition_macro_worker'..(M.windows(r) and '.dll' or '.dylib')end
function M.helper_name(r)return 'reaper_audition_macro'..(M.windows(r) and '.dll' or '.dylib')end
function M.command(r,args)
  local U=require('am.util');local out={}
  for i,value in ipairs(args)do
    if M.windows(r)then out[i]=U.quote_arg(value,true)
    else
      assert(not value:find('[%z\r\n$`]'),'Worker executable/install paths may not contain shell expansion characters')
      out[i]='"'..value:gsub('\\','\\\\'):gsub('"','\\"')..'"'
    end
  end
  return table.concat(out,' ')
end
function M.candidates(r,name)
  if not M.windows(r)then return {'/opt/homebrew/bin/'..name,'/usr/local/bin/'..name,'/usr/bin/'..name}end
  local paths={}
  for entry in (os.getenv('PATH') or ''):gmatch('[^;]+')do
    local directory=entry:gsub('^"',''):gsub('"$','')
    -- Windows Store's app-execution alias is not an installed Python runtime.
    if not directory:lower():find('windowsapps',1,true)then paths[#paths+1]=directory..'/'..(name=='python3' and 'python' or name)..'.exe'end
  end
  if name=='python3' then
    local base=os.getenv('LOCALAPPDATA')
    if base then for version=15,10,-1 do paths[#paths+1]=base..'/Programs/Python/Python3'..version..'/python.exe'end end
  elseif name=='ffmpeg'then
    paths[#paths+1]='C:/ffmpeg/bin/ffmpeg.exe'
    local program=os.getenv('ProgramFiles');if program then paths[#paths+1]=program..'/ffmpeg/bin/ffmpeg.exe'end
  end
  return paths
end
return M
